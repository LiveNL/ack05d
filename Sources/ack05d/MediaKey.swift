import Foundation
import CoreGraphics
import AppKit

/// Posts the special system-defined media keys (volume, brightness, mute, play …).
/// Unlike `osascript set volume`, these drive macOS's own on-screen HUD — the volume
/// bar and brightness overlay appear exactly as with the keyboard's own media keys.
enum MediaKey: String {
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute = "mute"
    case brightnessUp = "brightness_up"
    case brightnessDown = "brightness_down"
    case playPause = "play_pause"
    case next = "next"
    case previous = "previous"

    // NX_KEYTYPE_* codes from IOKit's ev_keymap.h.
    private var code: Int32 {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    func post() {
        send(keyDown: true)
        send(keyDown: false)
    }

    private func send(keyDown: Bool) {
        // data1 = (keyCode << 16) | keyState, where keyState is 0xA00 (down) / 0xB00 (up).
        let state: Int = keyDown ? 0xa00 : 0xb00
        let data1 = (Int(code) << 16) | state
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,               // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
