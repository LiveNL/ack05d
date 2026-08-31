import Foundation

/// Executes configured actions and owns the wheel-mode cursor. All shell work is
/// detached and non-blocking so a slow command never stalls the BLE run loop.
final class ActionRunner {
    private let config: Config
    private var wheelIndex = 0

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

    private func run(_ action: Config.Action, defaultLabel: String) {
        switch action.type {
        case .none:
            break
        case .shell:
            if let cmd = action.command { shell(cmd) }
            overlay(action.label ?? defaultLabel)
        case .mediaKey:
            // The media key raises macOS's own HUD, so ack05d stays silent by default
            // here — only overlay if the config gave an explicit label.
            if let name = action.key, let mk = MediaKey(rawValue: name) { mk.post() }
            if let label = action.label { overlay(label) }
        case .wheelModeCycle:
            guard !config.wheelModes.isEmpty else { return }
            wheelIndex = (wheelIndex + 1) % config.wheelModes.count
            overlay(action.label ?? "wheel: \(config.wheelModes[wheelIndex].name)")
        }
    }

    private func overlay(_ label: String) {
        guard let cmd = config.overlayCommand else { return }
        shell("\(cmd) \(shellQuote(label)) 0.8")
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
