import Foundation
import CoreBluetooth

/// Owns the BLE link to the ACK05 and puts it into vendor/bitmask mode.
///
/// The vendor stream lives on a proprietary GATT service (FFE0), NOT the HID profile:
///   - 0001  write            command channel
///   - 0002  notify           acks; must be subscribed or 0003 never streams
///   - 0003  notify           0xf0 state frames + 0xf2 battery + 0xf8 reconnect
///
/// Two enable recipes, tried in order, because units differ by SoC revision:
///   simple: subscribe 0002 then 0003, and after the first heartbeat write the 10-byte
///           enable packet WITHOUT response. Confirmed on the Telink ("ACK05-B") unit.
///   full:   if no state frame arrives within a grace period, replay the official
///           driver's 7-packet sequence (with response, 500 µs gaps) as a fallback.
///
/// The device uses a random BLE address that rotates on power-up, so it is found by
/// service UUID / name, never a remembered address, and vendor mode is re-asserted on
/// every 0xf8 reconnect event.
final class Transport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "FFE0")
    static let chWrite = CBUUID(string: "0001")
    static let chEnable = CBUUID(string: "0002")
    static let chNotify = CBUUID(string: "0003")
    static let hidService = CBUUID(string: "1812")

    static let enablePacket = Data([0x02, 0xb0, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    static let fullSequence: [[UInt8]] = [
        [0x02, 0xb0, 0x04], [0x80, 0x06, 0xf1], [0x02, 0xb8, 0x04],
        [0x80, 0x06, 0x64], [0x80, 0x06, 0x04], [0x80, 0x06, 0x03], [0x80, 0x06, 0x05],
    ]

    /// Called on the main run loop for every decoded frame payload.
    var onFrame: ((Data) -> Void)?
    /// Called with human-readable status transitions for logging.
    var onStatus: ((String) -> Void)?
    /// Called once per connection when the remote is confirmed live, with the latest
    /// battery percentage if known.
    var onReady: ((Int?) -> Void)?
    /// Called when the link drops.
    var onLost: (() -> Void)?
    /// Called when a connection attempt is progressing (startup scan or link up,
    /// handshaking), for a "connecting…" indicator that a later onReady replaces.
    var onConnecting: (() -> Void)?

    /// Latest battery percentage from the device's heartbeat, or nil if not seen yet.
    var currentBattery: Int? { lastBattery }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pending = Set<CBUUID>()
    private var enabledOnce = false
    private var enableAcked = false
    private var sawStateFrame = false
    private var announcedReady = false
    private var lastBattery: Int?
    private var retrieveTimer: Timer?
    /// Watchdog on a connect() to a scanned or retrieved peripheral. CoreBluetooth never
    /// times out a pending connect, and connect() stops both the scan and the poll, so a
    /// remote that rotates its address before the link lands (it does on power-up and
    /// periodically) leaves the daemon waiting on a peripheral that never comes back:
    /// no scan, no poll, nothing in the log, keys falling through in factory mode. The
    /// watchdog drops the stale attempt and goes back to scan + poll.
    private var connectTimer: Timer?
    private static let connectTimeout: TimeInterval = 15
    /// Consecutive failures to reach a handshake: CBError 6 (timeout) disconnects, or
    /// connect attempts the watchdog dropped. A remote in soft-off accepts links and
    /// drops them, and a remote macOS reports as connected can still refuse our link;
    /// after a few of either we back off instead of churning every few seconds.
    private var consecutiveFailures = 0
    private static let backoffAfter = 3
    private static let backoffSeconds: TimeInterval = 60

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            let why: String
            switch c.state {
            case .unauthorized: why = "Bluetooth access denied — allow it under System Settings > Privacy & Security > Bluetooth"
            case .poweredOff: why = "Bluetooth is turned off"
            case .unsupported: why = "Bluetooth LE not supported on this Mac"
            case .resetting: why = "Bluetooth is resetting, waiting"
            default: why = "Bluetooth not ready yet (state \(c.state.rawValue))"
            }
            onStatus?(why)
            return
        }
        connectKnownOrScan()
    }

    /// The remote as macOS currently has it connected, if any. Looked up by our vendor
    /// service first; if that yields nothing (after a power-cycle the remote has a new
    /// address and macOS hasn't cached FFE0 for it yet — it only speaks HID to it), fall
    /// back to the HID-over-GATT service every bonded remote exposes, matched by name.
    /// Without this fallback the daemon can sit in "scanning" forever while the remote
    /// is already connected in factory keystroke mode.
    private func systemConnectedRemote() -> CBPeripheral? {
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            return p
        }
        return central.retrieveConnectedPeripherals(withServices: [Self.hidService])
            .first { ($0.name ?? "").localizedCaseInsensitiveContains("shortcut remote") }
    }

    private func connectKnownOrScan() {
        // Always clear any previous poll timer first, or a second disconnect leaks one.
        retrieveTimer?.invalidate()
        retrieveTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        if let p = systemConnectedRemote() {
            connect(p)
        } else {
            onStatus?("scanning")
            central.scanForPeripherals(withServices: [Self.service], options: nil)
            // A connected device stops advertising, so scanning alone misses the case
            // where macOS re-bonds the remote before we see it. Poll the system's
            // connected set until either path lands a peripheral.
            retrieveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let p = self.systemConnectedRemote() {
                    self.onStatus?("found system-connected peripheral")
                    self.connect(p)
                }
            }
        }
    }

    private func connect(_ p: CBPeripheral) {
        retrieveTimer?.invalidate()
        retrieveTimer = nil
        // Drop any pending reconnect to a stale peripheral (power-cycle gives a new one).
        if let old = peripheral, old.identifier != p.identifier {
            central.cancelPeripheralConnection(old)
        }
        peripheral = p
        p.delegate = self
        central.stopScan()
        onStatus?("connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
        armConnectWatchdog(p)
    }

    private func armConnectWatchdog(_ p: CBPeripheral) {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self, p === self.peripheral, p.state != .connected else { return }
            self.central.cancelPeripheralConnection(p)
            self.peripheral = nil
            self.consecutiveFailures += 1
            if self.consecutiveFailures >= Self.backoffAfter {
                self.onStatus?("no link after \(Int(Self.connectTimeout))s, \(self.consecutiveFailures) failures in a row; retrying in \(Int(Self.backoffSeconds))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.backoffSeconds) { [weak self] in
                    guard let self, self.peripheral?.state != .connected else { return }
                    self.connectKnownOrScan()
                }
                return
            }
            self.onStatus?("no link after \(Int(Self.connectTimeout))s, dropping the attempt and rescanning")
            self.connectKnownOrScan()
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        // Whichever path landed the link (pending connect, scan, or poll), stop the
        // others now — otherwise the poll timer's next tick calls connect() again and
        // restarts the handshake on an already-connected peripheral.
        retrieveTimer?.invalidate()
        retrieveTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        c.stopScan()
        guard p === peripheral || peripheral == nil else {
            c.cancelPeripheralConnection(p)
            return
        }
        peripheral = p
        onStatus?("connected")
        resetState()
        // Don't announce "connecting…" yet: a remote in soft-off accepts the link and
        // then times out without ever answering service discovery. The overlay fires
        // once characteristics are subscribed, which a dead link never reaches.
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        // A stale attempt the watchdog already dropped reports back here or in
        // didDisconnect; the fallback it needs is already running.
        guard p === peripheral else { return }
        // Without this, a failed connect() (after stopScan + timer cancel) leaves the
        // daemon stuck with neither a scan nor a poll running. Fall back to both.
        onStatus?("connect failed, retrying")
        connectKnownOrScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        guard p === peripheral else { return }
        // Surface CoreBluetooth's reason: e.g. CBError 6 = connection timeout (radio /
        // range), 7 = peripheral disconnected (device closed the link itself).
        let why = (error as NSError?).map { " (\($0.domain) \($0.code): \($0.localizedDescription))" } ?? " (no error: clean close)"
        onStatus?("disconnected\(why), reconnecting")
        onLost?()
        if let e = error as NSError?, e.domain == CBErrorDomain, e.code == CBError.connectionTimeout.rawValue {
            consecutiveFailures += 1
        } else {
            consecutiveFailures = 0
        }
        if consecutiveFailures >= Self.backoffAfter {
            onStatus?("\(consecutiveFailures) failures in a row — remote likely asleep; retrying in \(Int(Self.backoffSeconds))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.backoffSeconds) { [weak self] in
                guard let self, self.peripheral?.state != .connected else { return }
                self.central.connect(p, options: nil)
                self.connectKnownOrScan()
            }
            return
        }
        // Sleep/wake: the same peripheral returns at the same address, so a pending
        // connect (CoreBluetooth has no timeout) fires the moment it's back — faster
        // and more reliable than scanning. Power-cycle rotates the address, so the
        // scan + poll below remain the fallback; connect() cancels this stale pending.
        central.connect(p, options: nil)
        connectKnownOrScan()
    }

    private func resetState() {
        pending = []
        enabledOnce = false
        enableAcked = false
        sawStateFrame = false
        announcedReady = false
        lastBattery = nil
        writeChar = nil
    }

    // Announce ready once vendor mode is confirmed — either the enable ack arrived or a
    // real state frame did — carrying the battery level if a heartbeat has been seen.
    private func maybeAnnounceReady() {
        guard !announcedReady, enableAcked || sawStateFrame else { return }
        announcedReady = true
        // The enable ack usually beats the first battery heartbeat by a moment; give the
        // heartbeat a short grace period so the ready overlay can include the level.
        if lastBattery != nil {
            onReady?(lastBattery)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.onReady?(self.lastBattery)
            }
        }
    }

    // MARK: Peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == Self.service {
            p.discoverCharacteristics([Self.chWrite, Self.chEnable, Self.chNotify], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard s.uuid == Self.service else { return }
        let chars = s.characteristics ?? []
        writeChar = chars.first { $0.uuid == Self.chWrite }
        for uuid in [Self.chEnable, Self.chNotify] {
            if let ch = chars.first(where: { $0.uuid == uuid }) {
                pending.insert(uuid)
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic,
                    error: Error?) {
        pending.remove(ch.uuid)
        guard pending.isEmpty else { return }
        onStatus?("subscribed, waiting for heartbeat to enable vendor mode")
        consecutiveFailures = 0
        onConnecting?()
        // If the simple recipe yields no state frame, fall back to the full sequence.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            // The enable ack alone confirms vendor mode; state frames only arrive on a
            // key press, so don't replay the full sequence when the ack already landed.
            guard let self, !self.enableAcked, !self.sawStateFrame else { return }
            self.onStatus?("no frames yet, sending full 7-packet sequence")
            self.sendFullSequence()
        }
    }

    private func enableSimple() {
        guard !enabledOnce, let wc = writeChar else { return }
        enabledOnce = true
        peripheral?.writeValue(Self.enablePacket, for: wc, type: .withoutResponse)
    }

    private func sendFullSequence() {
        guard let wc = writeChar, let p = peripheral else { return }
        for bytes in Self.fullSequence {
            var b = bytes
            while b.count < 10 { b.append(0) }
            p.writeValue(Data(b), for: wc, type: .withResponse)
            usleep(500)
        }
    }

    private func reassert() {
        enabledOnce = false
        enableSimple()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        // First heartbeat proves the link is live; that is when the simple enable lands.
        if !enabledOnce, v.count > 1, v[1] == 0xf2 {
            enableSimple()
        }
        // 02 b0 01 = enable ack (vendor mode confirmed, no key press needed).
        if v.count > 2, v[1] == 0xb0, v[2] == 0x01 { enableAcked = true; maybeAnnounceReady() }
        // 02 f2 .. = battery heartbeat; remember the level for the ready message.
        if v.count > 3, v[1] == 0xf2 { lastBattery = Int(v[3]); maybeAnnounceReady() }
        if v.count > 1, v[1] == 0xf0 {
            sawStateFrame = true
            maybeAnnounceReady()
        }
        if v.count > 1, v[1] == 0xf8 { reassert() }
        onFrame?(v)
    }
}
