import AppKit

// hud — a single, reusable heads-up overlay.
//
//   hud "text" [seconds]     show/refresh the overlay
//
// The first call starts a tiny background server that owns ONE panel; every later call
// hands its text to that server over a CFMessagePort. So two quick calls update the same
// panel instead of stacking two overlapping windows, and the panel keeps a fixed width
// (text is centered, long text ellipsized) so it never jumps around.

let PORT_NAME = "io.github.livenl.hud" as CFString
let FIXED_WIDTH: CGFloat = 300
let HEIGHT: CGFloat = 64

func encode(_ text: String, _ seconds: Double) -> Data {
    "\(seconds)\n\(text)".data(using: .utf8) ?? Data()
}
func decode(_ data: Data) -> (String, Double) {
    let s = String(data: data, encoding: .utf8) ?? ""
    let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let seconds = Double(parts.first ?? "0.9") ?? 0.9
    let text = parts.count > 1 ? String(parts[1]) : ""
    return (text, seconds)
}

// MARK: - Server (owns the single panel)

final class HUDServer {
    private let panel: NSPanel
    private let label: NSTextField
    private var fade: DispatchWorkItem?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: FIXED_WIDTH, height: HEIGHT),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: FIXED_WIDTH, height: HEIGHT))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        // Give the label its own line height and centre it vertically in the slab;
        // a full-height NSTextField renders its single line at the top otherwise.
        let lineH = ceil(label.font!.ascender - label.font!.descender + label.font!.leading) + 4
        label.frame = NSRect(x: 20, y: (HEIGHT - lineH) / 2, width: FIXED_WIDTH - 40, height: lineH)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        label.cell?.usesSingleLineMode = true
        blur.addSubview(label)
        panel.contentView = blur
    }

    func show(_ text: String, _ seconds: Double) {
        label.stringValue = text
        // place on the screen currently under the pointer, so it follows across displays
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - FIXED_WIDTH / 2,
                              y: v.minY + v.height * 0.18,
                              width: FIXED_WIDTH, height: HEIGHT), display: true)
        if panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        } else {
            panel.orderFrontRegardless()
        }
        // reset the auto-hide timer so a fresh message keeps it visible
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

func runServer(initial: (String, Double)?) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let server = HUDServer()

    let callback: CFMessagePortCallBack = { _, _, data, _ in
        if let data = data as Data? {
            let (text, seconds) = decode(data)
            DispatchQueue.main.async { serverRef?.show(text, seconds) }
        }
        return nil
    }
    serverRef = server
    guard let local = CFMessagePortCreateLocal(nil, PORT_NAME, callback, nil, nil) else {
        // another server already owns the name; just forward and exit
        if let initial = initial { _ = sendToServer(initial.0, initial.1) }
        return
    }
    let src = CFMessagePortCreateRunLoopSource(nil, local, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    if let initial = initial { server.show(initial.0, initial.1) }
    app.run()
}

// A global the C callback can reach.
var serverRef: HUDServer?

// MARK: - Client

func sendToServer(_ text: String, _ seconds: Double) -> Bool {
    guard let remote = CFMessagePortCreateRemote(nil, PORT_NAME) else { return false }
    let data = encode(text, seconds) as CFData
    let result = CFMessagePortSendRequest(remote, 0, data, 1.0, 1.0, nil, nil)
    return result == kCFMessagePortSuccess
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--server") {
    runServer(initial: nil)
} else {
    let text = args.count > 1 ? args[1] : "hud"
    let seconds = args.count > 2 ? (Double(args[2]) ?? 0.9) : 0.9
    if sendToServer(text, seconds) {
        // delivered to the running server; done
    } else {
        // no server yet: launch one (detached) that shows this message, then persists
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--server"]
        try? p.run()
        // give it a beat to bind the port, then forward
        usleep(350_000)
        _ = sendToServer(text, seconds)
    }
}
