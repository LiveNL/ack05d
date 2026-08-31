import Foundation
import CoreGraphics

/// Synthesises a key chord (e.g. "cmd+=", "shift+cmd+4") as CGEvents. Needs the daemon
/// to be Accessibility-trusted, same as MediaKey. Used for app-level actions that have
/// no media key — zoom in/out being the obvious wheel use.
struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// Parse "cmd+shift+=" style strings. Modifiers: cmd/command, opt/alt/option,
    /// ctrl/control, shift. The final token is the key. Returns nil on an unknown key.
    init?(_ spec: String) {
        var flags: CGEventFlags = []
        var keyToken: String?
        for raw in spec.split(separator: "+") {
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "cmd", "command": flags.insert(.maskCommand)
            case "opt", "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: keyToken = t
            }
        }
        guard let token = keyToken, let code = Self.keyCodes[token] else { return nil }
        self.keyCode = code
        self.flags = flags
    }

    func post() {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // ANSI virtual key codes (Carbon kVK_*). Enough for common chords; extend as needed.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "equal": 24,
        "9": 25, "7": 26, "-": 27, "minus": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "+": 24, "plus": 24,  // = key; combine with shift for a literal plus
    ]
}
