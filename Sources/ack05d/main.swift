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

func log(_ s: String) {
    FileHandle.standardError.write(Data("ack05d: \(s)\n".utf8))
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
var runner: ActionRunner?

if identifyMode {
    log("identify mode — press buttons; nothing is executed")
} else {
    do {
        let config = try Config.load(from: configURL())
        runner = ActionRunner(config: config)
        log("loaded config from \(configURL().path)")
    } catch {
        log("could not load config (\(error)). Running in identify mode instead.")
    }
}

// mediaKey actions need Accessibility. A launchd agent can't surface the grant
// dialog, so the user adds the app bundle manually (see README / install.sh output).
log("accessibility trusted: \(AXIsProcessTrusted())")

let transport = Transport()
transport.onStatus = { log($0) }
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
            log("battery \(percent)%\(charging ? " (charging)" : "")")
        case .reconnect:
            log("device reconnect")
        }
    }
}

transport.start()
RunLoop.main.run()
