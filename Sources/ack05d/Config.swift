import Foundation

/// User configuration, loaded from `$XDG_CONFIG_HOME/ack05d/config.json` (or
/// `~/.config/ack05d/config.json`). Kept entirely separate from the binary so the
/// generic driver can be published while personal mappings live in the user's dotfiles.
struct Config: Decodable {
    /// Optional shell command run for every event, receiving a label as $1. Used for an
    /// on-screen overlay; omit to stay silent. Example: "/Users/me/.local/bin/hud".
    var overlayCommand: String?

    /// Overlay shown when the remote becomes ready after (re)connecting. Set to "" to
    /// suppress. Defaults to "ACK05 ready".
    var connectedLabel: String?
    /// Overlay shown when the link drops. Set to "" to suppress. Defaults to "" (silent).
    var disconnectedLabel: String?

    /// button name (see Button.rawValue) -> action
    var buttons: [String: Action]

    /// Ordered wheel modes cycled by any action of type "wheelModeCycle".
    var wheelModes: [WheelMode]

    struct WheelMode: Decodable {
        var name: String
        var cw: Action
        var ccw: Action
    }

    /// A single action. `type` selects the variant; other fields apply per type.
    struct Action: Decodable {
        var type: ActionType
        /// shell: the command line. Runs via `/bin/sh -c`.
        var command: String?
        /// mediaKey: which system media key to post (see MediaKey.rawValue).
        var key: String?
        /// keystroke: a key chord to synthesize, e.g. "cmd+=" or "shift+cmd+4".
        var keystroke: String?
        /// overlay label shown when overlayCommand is set (defaults to the button name).
        var label: String?
        /// suppress the daemon's own overlay for this action — e.g. when the invoked
        /// command draws its own, smarter overlay (a toggle showing on/off state).
        var silent: Bool?

        enum ActionType: String, Decodable {
            case shell           // run `command`
            case mediaKey        // post a system media key (volume/brightness/…) with native HUD
            case keystroke       // synthesize a key chord, e.g. "cmd+=" for zoom in
            case wheelModeCycle  // advance to the next wheelModes entry
            case none            // do nothing (explicitly unbound)
        }
    }

    static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ack05d/config.json")
    }
}
