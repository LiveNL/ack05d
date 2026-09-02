import Foundation
import ApplicationServices

// ack05d — userspace driver for the XPPen ACK05 shortcut remote over Bluetooth LE.
//
//   ack05d              run the driver using the config file
//   ack05d --identify   print every button/wheel event by name; no actions run
//   ack05d --config P   use config file at path P
//
// See README.md for the protocol and config format.

let args = CommandLine.arguments
let identifyMode = args.contains("--identify")
let debug = args.contains("--debug") || ProcessInfo.processInfo.environment["ACK05D_DEBUG"] != nil

func configURL() -> URL {
    if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
        return URL(fileURLWithPath: args[i + 1])
    }
    return Config.defaultURL
}

let logStamp: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()
func log(_ s: String) {
    FileHandle.standardError.write(Data("\(logStamp.string(from: Date())) ack05d: \(s)\n".utf8))
}

/// In identify mode, surface the pressed button's name on screen too, so it can be
/// mapped to a physical key without watching stderr. Best-effort; silent if absent.
let identifyOverlay = ProcessInfo.processInfo.environment["ACK05D_IDENTIFY_OVERLAY"]
func showIdentify(_ label: String) {
    guard let cmd = identifyOverlay else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "\(cmd) '\(label)' 1.2"]
    try? p.run()
}

var decoder = FrameDecoder()
var lastLoggedBattery: Int?
var runner: ActionRunner?

var connectingLabel = "ACK05 connecting…"
var connectedLabel = "ACK05 ready"
var disconnectedLabel = ""
var quietReconnectSeconds: Double = 180
/// Last moment the remote was in contact (ready or dropped). A reconnect within
/// quietReconnectSeconds of this is range-flapping, not a fresh session: no overlays.
var lastContact: Date?
func quietReconnect() -> Bool {
    guard let t = lastContact else { return false }
    return Date().timeIntervalSince(t) < quietReconnectSeconds
}

// Set once transport exists; re-applied to each fresh runner on config reload.
var batteryProvider: (() -> Int?)?

func loadConfig() {
    do {
        let config = try Config.load(from: configURL())
        let r = ActionRunner(config: config)
        r.batteryProvider = batteryProvider
        runner = r
        connectingLabel = config.connectingLabel ?? "ACK05 connecting…"
        connectedLabel = config.connectedLabel ?? "ACK05 ready"
        disconnectedLabel = config.disconnectedLabel ?? ""
        quietReconnectSeconds = config.quietReconnectSeconds ?? 180
        log("loaded config from \(configURL().path)")
    } catch {
        if runner == nil {
            log("could not load config (\(error)). Running in identify mode instead.")
        } else {
            log("config reload failed (\(error)); keeping the previous config")
        }
    }
}

// Watch the config's mtime and hot-reload on change, so edits apply without a restart.
func startConfigWatcher() {
    func mtime() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: configURL().path)[.modificationDate] as? Date
    }
    var last = mtime()
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
        let now = mtime()
        if let now, now != last {
            last = now
            log("config changed, reloading")
            loadConfig()
        }
    }
}

if identifyMode {
    log("identify mode — press buttons; nothing is executed")
} else {
    loadConfig()
    startConfigWatcher()
}

// mediaKey and keystroke actions need Accessibility. A launchd agent can't surface the grant
// dialog, so the user adds the app bundle manually (see README / install.sh output).
log("accessibility trusted: \(AXIsProcessTrusted())")

let transport = Transport()
// Wire the battery source now that the transport exists, onto the current runner and
// any future one built on config reload.
batteryProvider = { transport.currentBattery }
runner?.batteryProvider = batteryProvider
transport.onStatus = { log($0) }
transport.onConnecting = {
    // Long duration so it stays up during the handshake; onReady replaces it.
    guard !identifyMode, !connectingLabel.isEmpty, !quietReconnect() else { return }
    runner?.announce(connectingLabel, 12)
}
transport.onReady = { battery in
    let quiet = quietReconnect()
    log("remote ready\(battery.map { " (\($0)%)" } ?? "")\(quiet ? " (quiet reconnect, no overlay)" : "")")
    lastContact = Date()
    guard !identifyMode, !connectedLabel.isEmpty, !quiet else { return }
    let suffix = battery.map { "  ·  \($0)%" } ?? ""
    runner?.announce(connectedLabel + suffix, 1.5)
}
transport.onLost = {
    let quiet = quietReconnect()
    lastContact = Date()
    if !identifyMode, !disconnectedLabel.isEmpty, !quiet { runner?.announce(disconnectedLabel) }
}
transport.onFrame = { data in
    for event in decoder.decode(data) {
        switch event {
        case .press(let button):
            if identifyMode || runner == nil { log("PRESS \(button.rawValue)"); showIdentify(button.rawValue) }
            else { runner?.handlePress(button) }
        case .release:
            break
        case .wheel(let direction):
            if identifyMode || runner == nil { log(direction.rawValue); showIdentify(direction.rawValue) }
            else {
                if debug { log("wheel \(direction.rawValue) mode=\(runner?.currentWheelMode?.name ?? "-")") }
                runner?.handleWheel(direction)
            }
        case .battery(let percent, let charging):
            // Heartbeats arrive every ~15s; only log when the level actually changes
            // (or under --debug) so the log doesn't grow by hundreds of KB a day.
            if debug || percent != lastLoggedBattery {
                lastLoggedBattery = percent
                log("battery \(percent)%\(charging ? " (charging)" : "")")
            }
        case .reconnect:
            log("device reconnect")
        }
    }
}

transport.start()
RunLoop.main.run()
