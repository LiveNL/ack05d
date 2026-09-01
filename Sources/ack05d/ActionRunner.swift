import Foundation

/// Executes configured actions and owns the wheel-mode cursor. All shell work is
/// detached and non-blocking so a slow command never stalls the BLE run loop.
final class ActionRunner {
    private let config: Config
    private var wheelIndex = 0

    /// Supplies the current battery level for the `battery` action (set by main from
    /// the transport). Returns nil until a heartbeat has been seen.
    var batteryProvider: (() -> Int?)?

    init(config: Config) {
        self.config = config
    }

    var currentWheelMode: Config.WheelMode? {
        config.wheelModes.isEmpty ? nil : config.wheelModes[wheelIndex]
    }

    func handlePress(_ button: Button) {
        guard let action = config.buttons[button.rawValue] else { return }
        run(action, defaultLabel: button.rawValue)
    }

    func handleWheel(_ direction: WheelDirection) {
        guard let mode = currentWheelMode else { return }
        run(direction == .cw ? mode.cw : mode.ccw, defaultLabel: mode.name)
    }

    /// Show a standalone overlay message (connection status, etc.).
    func announce(_ label: String, _ seconds: Double = 0.8) {
        overlay(label, seconds)
    }

    private func run(_ action: Config.Action, defaultLabel: String) {
        switch action.type {
        case .none:
            break
        case .shell:
            if let cmd = action.command { shell(cmd) }
            if action.silent != true { overlay(action.label ?? defaultLabel) }
        case .mediaKey:
            // The media key raises macOS's own HUD, so ack05d stays silent by default
            // here — only overlay if the config gave an explicit label.
            if let name = action.key, let mk = MediaKey(rawValue: name) { mk.post() }
            if let label = action.label { overlay(label) }
        case .keystroke:
            if let spec = action.keystroke, let ks = KeyStroke(spec) { ks.post() }
            if let label = action.label { overlay(label) }
        case .battery:
            let name = action.label ?? "battery"
            if let pct = batteryProvider?() { overlay("\(name)  ·  \(pct)%", 1.5) }
            else { overlay("\(name): unknown", 1.5) }
        case .wheelModeCycle:
            guard !config.wheelModes.isEmpty else { return }
            wheelIndex = (wheelIndex + 1) % config.wheelModes.count
            overlay(action.label ?? "wheel: \(config.wheelModes[wheelIndex].name)")
        }
    }

    private func overlay(_ label: String, _ seconds: Double = 0.8) {
        guard let cmd = config.overlayCommand else { return }
        shell("\(cmd) \(shellQuote(label)) \(seconds)")
    }

    private func shell(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        do { try p.run() } catch { FileHandle.standardError.write(Data("ack05d: run failed: \(error)\n".utf8)) }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
