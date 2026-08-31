import Foundation

/// Buttons as bit positions in the vendor bitmask frame. Physical placement differs
/// per unit revision and per user orientation; run `ack05d --identify` once and map
/// the names to actions in the config.
enum Button: String, CaseIterable {
    case b1 = "BTN_1", b2 = "BTN_2", b3 = "BTN_3", b4 = "BTN_4"
    case b5 = "BTN_5", b6 = "BTN_6", b7 = "BTN_7", b8 = "BTN_8"
    case b9 = "BTN_9", b10 = "BTN_10"
    case dial = "DIAL"
}

enum WheelDirection: String {
    case cw = "WHEEL_CW"
    case ccw = "WHEEL_CCW"
}

enum DeviceEvent {
    case press(Button)
    case release(Button)
    case wheel(WheelDirection)
    case battery(percent: Int, charging: Bool)
    case reconnect
}

/// Decodes vendor-mode frames: `02 f0 <byte2> <byte3> 00 00 00 <byte7> 00 00`.
/// Frames carry full state; press/release is derived by diffing consecutive frames.
/// Wheel bits are stateless pulses. Verified on the Telink ("ACK05-B") revision over
/// BLE (10-byte frames) and documented identically for USB (12 bytes) by the Linux
/// kernel HID-BPF driver.
struct FrameDecoder {
    private var previous: Set<Button> = []

    private static let byte2: [(UInt8, Button)] = [
        (0x01, .b1), (0x02, .b2), (0x04, .b3), (0x08, .b4),
        (0x10, .b5), (0x20, .b6), (0x40, .b7), (0x80, .b8),
    ]
    private static let byte3: [(UInt8, Button)] = [
        (0x01, .b9), (0x02, .b10), (0x04, .dial),
    ]

    mutating func decode(_ data: Data) -> [DeviceEvent] {
        guard data.count >= 4, data[0] == 0x02 else { return [] }
        switch data[1] {
        case 0xf0:
            var events: [DeviceEvent] = []
            var current: Set<Button> = []
            for (bit, button) in Self.byte2 where data[2] & bit != 0 { current.insert(button) }
            for (bit, button) in Self.byte3 where data[3] & bit != 0 { current.insert(button) }
            for button in current.subtracting(previous) { events.append(.press(button)) }
            for button in previous.subtracting(current) { events.append(.release(button)) }
            previous = current
            if data.count > 7 {
                if data[7] & 0x01 != 0 { events.append(.wheel(.cw)) }
                if data[7] & 0x02 != 0 { events.append(.wheel(.ccw)) }
            }
            return events
        case 0xf2:
            guard data.count > 4 else { return [] }
            return [.battery(percent: Int(data[3]), charging: data[4] != 0)]
        case 0xf8:
            return [.reconnect]
        default:
            return []
        }
    }
}
