// The floating panel, its size and place, and the command-line test modes.
import AppKit
import Combine
import SwiftUI
import WebKit

final class StackPanel: NSPanel {
    /// Only the reader may take the keyboard, and only when you click inside it.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: StackPanel!
    var hosting: NSHostingView<StackView>!
    let prefs = Prefs()
    lazy var store = Store(prefs: prefs)
    lazy var reader = ReaderModel(prefs: prefs)
    let focuser = Focuser()
    var web: ReaderWebView!
    var dragStartOrigin: NSPoint?
    var dragStartMouse: NSPoint?
    var resizeStart: (frame: NSRect, mouse: NSPoint)?
    var observers: [Any] = []
    var lastReader: Bool?

    let minSize = NSSize(width: 640, height: 400)

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = StackPanel(contentRect: NSRect(x: 0, y: 0, width: 336, height: 80),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        web = makeWebView(model: reader)
        reader.onWantKey = { [weak self] want in self?.setKey(want) }
        reader.onFocusTab = { [weak self] s in self?.focuser.focus(s) }

        let view = StackView(store: store, prefs: prefs, reader: reader, web: web, focuser: focuser,
                             onDrag: { [weak self] v in self?.drag(v) },
                             onResize: { [weak self] e, active in self?.resize(e, active) },
                             onResetPosition: { [weak self] in self?.resetPosition() })
        hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        store.onChange = { [weak self] in DispatchQueue.main.async { self?.layout() } }
        store.onRows = { [weak self] rows in self?.reader.update(rows: rows) }
        observers.append(prefs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        })
        reader.update(rows: store.rows)
        layout()
    }

    var readerMode: Bool { prefs.reader && !prefs.compact }

    /// Small stack: size to content. Reader: the saved size. The top-left corner stays where the user put it.
    func layout() {
        guard !store.rows.isEmpty else { panel.orderOut(nil); return }
        let topLeft = savedTopLeft() ?? defaultTopLeft()
        var frame: NSRect
        if readerMode {
            let size = savedReaderSize()
            frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        } else {
            let size = hosting.fittingSize
            frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        }
        frame = clampToScreen(frame)
        if lastReader != readerMode {
            lastReader = readerMode
            panel.allowKey = readerMode
            if !readerMode, panel.isKeyWindow { setKey(false) }
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func setKey(_ want: Bool) {
        if want {
            guard panel.allowKey else { return }
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
            // Give the keyboard back to the app you were in (usually Ghostty).
            if let app = NSWorkspace.shared.frontmostApplication, app != .current {
                app.activate()
            }
        }
    }

    func drag(_ v: DragGesture.Value?) {
        let mouse = NSEvent.mouseLocation
        guard v != nil else {
            dragStartOrigin = nil
            let f = panel.frame
            UserDefaults.standard.set([f.minX, f.maxY], forKey: "topLeft")
            return
        }
        if dragStartOrigin == nil { dragStartOrigin = panel.frame.origin; dragStartMouse = mouse }
        guard let o = dragStartOrigin, let m = dragStartMouse else { return }
        panel.setFrameOrigin(NSPoint(x: o.x + mouse.x - m.x, y: o.y + mouse.y - m.y))
    }

    func resize(_ edge: Edge, _ active: Bool) {
        let mouse = NSEvent.mouseLocation
        guard active else {
            resizeStart = nil
            let f = panel.frame
            UserDefaults.standard.set([f.minX, f.maxY], forKey: "topLeft")
            UserDefaults.standard.set([f.width, f.height], forKey: "readerSize")
            return
        }
        if resizeStart == nil { resizeStart = (panel.frame, mouse) }
        guard let st = resizeStart else { return }
        let dx = mouse.x - st.mouse.x, dy = mouse.y - st.mouse.y
        let screen = (NSScreen.screens.first { $0.frame.contains(st.mouse) } ?? NSScreen.main)?.visibleFrame
        var f = st.frame
        if edge == .right || edge == .bottomRight { f.size.width = st.frame.width + dx }
        if edge == .left || edge == .bottomLeft {
            f.size.width = st.frame.width - dx
        }
        if edge == .bottom || edge == .bottomLeft || edge == .bottomRight { f.size.height = st.frame.height - dy }
        f.size.width = max(minSize.width, min(f.size.width, screen?.width ?? 4000))
        f.size.height = max(minSize.height, min(f.size.height, screen?.height ?? 4000))
        // The top edge stays put. The left edge moves only when you drag it.
        f.origin.y = st.frame.maxY - f.height
        f.origin.x = (edge == .left || edge == .bottomLeft) ? st.frame.maxX - f.width : st.frame.minX
        panel.setFrame(f, display: true)
    }

    func savedReaderSize() -> NSSize {
        let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var s = NSSize(width: min(980, v.width - 40), height: min(700, v.height - 40))
        if let a = UserDefaults.standard.array(forKey: "readerSize") as? [Double], a.count == 2 {
            s = NSSize(width: a[0], height: a[1])
        }
        return NSSize(width: max(minSize.width, min(s.width, v.width)), height: max(minSize.height, min(s.height, v.height)))
    }

    func savedTopLeft() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: "topLeft") as? [Double], a.count == 2 else { return nil }
        return NSPoint(x: a[0], y: a[1])
    }

    func defaultTopLeft() -> NSPoint {
        let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: v.maxX - 336 - 16, y: v.maxY - 16)
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "topLeft")
        UserDefaults.standard.removeObject(forKey: "readerSize")
        layout()
    }

    /// Keep the panel on a screen (a monitor may have been unplugged).
    func clampToScreen(_ f: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return f }
        var r = f
        r.size.width = min(r.width, v.width)
        r.size.height = min(r.height, v.height)
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        return r
    }
}

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        // Test mode: draw the stack once into a PNG and exit. Usage: ClaudeStack --snapshot out.png [compact]
        if args.count >= 3, args[1] == "--snapshot" {
            MainActor.assumeIsolated { snapshot(to: args[2], compact: args.count > 3) }
            return
        }
        // Test mode: print the reader items of a transcript as JSON. Usage: ClaudeStack --parse file.jsonl
        if args.count >= 3, args[1] == "--parse" {
            let r = TranscriptReader(path: args[2])
            r.readNew()
            var out: [String: Any] = ["items": r.items.map { $0.json }]
            if let a = r.openAsk { out["ask"] = ["tool": a.name, "input": a.input] }
            let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            FileHandle.standardOutput.write(data)
            return
        }
        // Test mode: print the agents of a transcript as JSON. Usage: ClaudeStack --agents file.jsonl
        if args.count >= 3, args[1] == "--agents" {
            let r = TranscriptReader(path: args[2])
            r.readNew()
            let list = AgentScanner(transcript: args[2]).list(main: r.agents, now: Date().timeIntervalSince1970)
            let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            FileHandle.standardOutput.write(data)
            return
        }
        // Test mode: does the chat stay where the user scrolled while updates arrive?
        // Usage: ClaudeStack --scroll-test file.jsonl tests/scroll-test.js
        if args.count >= 4, args[1] == "--scroll-test" {
            MainActor.assumeIsolated { scrollTest(transcript: args[2], script: args[3]) }
            return
        }
        // Test mode: draw the web reader for a transcript into a PNG.
        // Usage: ClaudeStack --reader-snapshot file.jsonl out.png [state.json]
        if args.count >= 4, args[1] == "--reader-snapshot" {
            MainActor.assumeIsolated { readerSnapshot(transcript: args[2], out: args[3], state: args.count > 4 ? args[4] : nil) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
func snapshot(to path: String, compact: Bool) {
    let prefs = Prefs(UserDefaults(suiteName: "local.sundaran.claudestack.snapshot")!)
    prefs.reader = false
    prefs.compact = compact
    let store = Store(prefs: prefs)
    let model = ReaderModel(prefs: prefs)
    let view = StackView(store: store, prefs: prefs, reader: model, web: ReaderWebView(), focuser: Focuser(),
                         onDrag: { _ in }, onResize: { _, _ in }, onResetPosition: {})
        .padding(20).background(Color(hex: 0x3A3F47))
    let r = ImageRenderer(content: view)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Loads reader.html off screen, feeds it a transcript, and saves a picture.
@MainActor
func readerSnapshot(transcript: String, out: String, state: String?) {
    let r = TranscriptReader(path: transcript)
    r.readNew()
    let items = r.items.map { $0.json }
    let agents = AgentScanner(transcript: transcript).list(main: r.agents, now: Date().timeIntervalSince1970)
    var st: [String: Any] = ["sid": "test", "project": "test-project", "branch": "main", "display": "Done",
                             "color": "#06C27A", "running": false, "tool": "", "detail": "", "canSend": true,
                             "block": "", "fontSize": 15]
    if let state, let d = FileManager.default.contents(atPath: state),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        st.merge(o) { _, b in b }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let size = NSSize(width: 860, height: 1300)
    let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    let cfg = WKWebViewConfiguration()
    let w = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
    win.contentView = w
    win.orderFrontRegardless()
    let dir = webDir()
    w.loadFileURL(dir.appendingPathComponent("reader.html"), allowingReadAccessTo: dir)
    func json(_ o: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "null"
    }
    var finished = false
    func waitLoad(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if w.isLoading && n < 50 { return waitLoad(n + 1) }
            let js = "CS.reset({sid:'test'}); CS.setItems(\(json(["sid": "test", "items": items, "hasMore": false]))); CS.setState(\(json(st))); CS.setAgents(\(json(["sid": "test", "agents": agents]))); document.title"
            w.evaluateJavaScript(js) { _, err in
                if let err { FileHandle.standardError.write("JS error: \(err)\n".data(using: .utf8)!) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    w.takeSnapshot(with: nil) { img, _ in
                        if let img, let tiff = img.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: out))
                        }
                        finished = true
                    }
                }
            }
        }
    }
    waitLoad(0)
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

/// Loads reader.html off screen with a transcript, runs a test script, prints window.__result.
@MainActor
func scrollTest(transcript: String, script: String) {
    let r = TranscriptReader(path: transcript)
    r.readNew()
    let items = r.items.map { $0.json }
    let st: [String: Any] = ["sid": "test", "project": "test-project", "branch": "main", "display": "Running",
                             "color": "#5B9BE6", "running": true, "tool": "Bash", "detail": "", "canSend": true,
                             "block": "", "fontSize": 15]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let size = NSSize(width: 700, height: 500)
    let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    let w = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
    win.contentView = w
    win.orderFrontRegardless()
    let dir = webDir()
    w.loadFileURL(dir.appendingPathComponent("reader.html"), allowingReadAccessTo: dir)
    func json(_ o: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "null"
    }
    let test = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
    var done = false
    func poll(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            w.evaluateJavaScript("window.__result || ''") { v, _ in
                if let s = v as? String, !s.isEmpty { print(s); done = true } else if n > 60 { print("timeout"); done = true } else { poll(n + 1) }
            }
        }
    }
    func start(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if w.isLoading && n < 50 { return start(n + 1) }
            let setup = "window.__items = \(json(items)); window.__state = \(json(st)); CS.reset({sid:'test'}); CS.setItems({sid:'test', hasMore:false, items: window.__items}); CS.setState(window.__state);"
            w.evaluateJavaScript(setup + test) { _, err in
                if let err { print("JS error: \(err)"); done = true } else { poll(0) }
            }
        }
    }
    start(0)
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
