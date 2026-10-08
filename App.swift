// The floating small stack, the reader window, and the command-line test modes.
import AppKit
import Combine
import SwiftUI
import WebKit

final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { false }   // the small stack never takes the keyboard
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: StackPanel!
    var hosting: NSHostingView<StackView>!
    var readerWindow: NSWindow?
    let prefs = Prefs()
    lazy var store = Store(prefs: prefs)
    lazy var reader = ReaderModel(prefs: prefs)
    let coach = DayCoach()
    var coachTimer: Timer?
    let focuser = Focuser()
    var web: ReaderWebView!
    var pinButton: NSButton?
    var pinMenuItem: NSMenuItem?
    var dragStartOrigin: NSPoint?
    var dragStartMouse: NSPoint?
    var observers: [Any] = []

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
        reader.onFocusTab = { [weak self] s in self?.focuser.focus(s) }

        let view = StackView(store: store, prefs: prefs, reader: reader, coach: coach, focuser: focuser,
                             onDrag: { [weak self] v in self?.drag(v) },
                             onResetPosition: { [weak self] in self?.resetPosition() },
                             onOpenReader: { [weak self] id in self?.openReader(id) })
        hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        store.onChange = { [weak self] in DispatchQueue.main.async { self?.layout() } }
        store.onRows = { [weak self] rows in self?.reader.update(rows: rows) }
        observers.append(prefs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        })
        // The small stack hides while you use the reader, and comes back when you switch apps.
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.layout() })
        }
        // The day coach counts work time every 5 seconds. Busy: any session running or waiting for you.
        coach.tick(busy: false)
        coachTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.coach.tick(busy: self.store.rows.contains { $0.display == .running || $0.display == .needs })
        }
        observers.append(coach.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        })
        // The reader never opens by itself: the app starts on every Claude event.
        prefs.reader = false
        reader.update(rows: store.rows)
        layout()
    }

    /// The reader is in front: the app is active and its window is on screen (not in the Dock).
    var readerInFront: Bool {
        guard let w = readerWindow, w.isVisible, !w.isMiniaturized else { return false }
        // A reader kept on top is always in front, so the small stack stays hidden while it is open.
        return prefs.keepOnTop || NSApp.isActive
    }

    /// The small stack sizes to its content. The top-left corner stays where the user put it.
    func layout() {
        guard !store.rows.isEmpty, !readerInFront else { panel.orderOut(nil); return }
        let topLeft = savedTopLeft() ?? defaultTopLeft()
        let size = hosting.fittingSize
        let frame = clampToScreen(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Reader window

    func openReader(_ sessionId: String?) {
        if let sessionId { reader.select(sessionId) }
        if prefs.compact { prefs.compact = false }
        let w = readerWindow ?? makeReaderWindow()
        readerWindow = w
        prefs.reader = true
        // A normal app while the reader is open: Dock icon, Cmd+Tab, menu bar.
        NSApp.setActivationPolicy(.regular)
        if NSApp.mainMenu == nil { NSApp.mainMenu = makeMenu() }
        if w.isMiniaturized { w.deminiaturize(nil) }
        // The switch to a normal app takes effect on the next turn of the run loop, and macOS
        // may refuse the first request to come forward. Ask then, and once more if needed.
        DispatchQueue.main.async { self.bringForward(w, tries: 3) }
    }

    private func bringForward(_ w: NSWindow, tries: Int) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        layout()
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !NSApp.isActive { self.bringForward(w, tries: tries - 1) }
        }
    }

    private func makeReaderWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude Stack"
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(red: 0x0F / 255, green: 0x19 / 255, blue: 0x23 / 255, alpha: 1)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 680, height: 440)
        w.contentView = NSHostingView(rootView: ReaderView(store: store, reader: reader, coach: coach, prefs: prefs, web: web,
                                                           onKeepOnTop: { [weak self] in self?.toggleKeepOnTop(nil) }))
        w.delegate = self
        // Size and place are remembered by AppKit under this name.
        if !w.setFrameUsingName("ClaudeStackReader") { w.center() }
        w.setFrameAutosaveName("ClaudeStackReader")

        // The pin at the top right of the title bar: keep on top, or a normal window.
        let pin = NSButton(title: "", target: self, action: #selector(toggleKeepOnTop(_:)))
        pin.bezelStyle = .accessoryBarAction
        pin.isBordered = false
        pin.frame = NSRect(x: 0, y: 0, width: 34, height: 22)
        pinButton = pin
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .trailing
        acc.view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        pin.frame.origin = NSPoint(x: 0, y: 0)
        acc.view.addSubview(pin)
        w.addTitlebarAccessoryViewController(acc)
        applyKeepOnTop(w)
        return w
    }

    @objc func toggleKeepOnTop(_ sender: Any?) {
        prefs.keepOnTop.toggle()
        guard let w = readerWindow else { return }
        // A floating window cannot stay in macOS full screen; leave it first, then float.
        if prefs.keepOnTop, w.styleMask.contains(.fullScreen) {
            pendingFloat = true
            w.toggleFullScreen(nil)
            return
        }
        applyKeepOnTop(w)
    }
    var pendingFloat = false

    func windowDidExitFullScreen(_ n: Notification) {
        guard pendingFloat, let w = readerWindow else { return }
        pendingFloat = false
        applyKeepOnTop(w)
    }

    /// ON: floats above every app, on every desktop. OFF: a normal window with macOS full screen.
    func applyKeepOnTop(_ w: NSWindow) {
        let on = prefs.keepOnTop
        w.level = on ? .floating : .normal
        w.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary, .managed]
        if let pin = pinButton {
            pin.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin", accessibilityDescription: "Keep on top")
            pin.contentTintColor = on ? NSColor(red: 1, green: 0x9A / 255, blue: 0, alpha: 1) : .secondaryLabelColor
            pin.toolTip = on ? "Kept on top of all apps. Click for a normal window." : "Normal window. Click to keep it on top of all apps."
        }
        pinMenuItem?.state = on ? .on : .off
        layout()
    }

    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === readerWindow else { return }
        prefs.reader = false
        // Back to a background helper: no Dock icon, no menu bar.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            self.layout()
        }
    }

    func windowDidMiniaturize(_ n: Notification) { layout() }
    func windowDidDeminiaturize(_ n: Notification) { layout() }

    func applicationWillTerminate(_ n: Notification) {
        reader.voice.cancel()
    }

    /// Clicking the Dock icon brings the reader back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openReader(nil)
        return false
    }

    /// App menu and Window menu only. There is no Edit menu on purpose: the page handles
    /// Cmd+C, Cmd+V and the rest itself, and a menu would paste a second time.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Hide Claude Stack", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Claude Stack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let full = win.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        let pin = win.addItem(withTitle: "Keep on Top", action: #selector(toggleKeepOnTop(_:)), keyEquivalent: "t")
        pin.keyEquivalentModifierMask = [.command, .shift]
        pin.target = self
        pin.state = prefs.keepOnTop ? .on : .off
        pinMenuItem = pin
        win.addItem(.separator())
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win
        return main
    }

    // MARK: - Small stack position

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
        layout()
    }

    /// Keep the panel on a screen (a monitor may have been unplugged).
    func clampToScreen(_ f: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return f }
        var r = f
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
            let list = AgentScanner(transcript: args[2]).list(main: r.agents, finished: r.finishedTasks, now: Date().timeIntervalSince1970)
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
        // Test mode: draw the day strip and every reminder card into a PNG. Usage: ClaudeStack --coach-snapshot out.png
        if args.count >= 3, args[1] == "--coach-snapshot" {
            MainActor.assumeIsolated { coachSnapshot(to: args[2]) }
            return
        }
        // Test mode: print the screen of a session's Ghostty tab. Usage: ClaudeStack --screen <session id>
        // Test mode: press keys in a session's Ghostty tab. Usage: ClaudeStack --keys <session id> down space enter
        if args.count >= 3, args[1] == "--screen" || args[1] == "--keys" {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stack/sessions/\(args[2]).json")
            guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Session.self, from: data) else {
                print("no session \(args[2])"); return
            }
            if args[1] == "--screen" {
                print(Terminals.shared.q.sync { Terminals.shared.terminalId(for: s) }.flatMap(readScreen) ?? "(none)")
            } else {
                let sem = DispatchSemaphore(value: 0)
                Terminals.shared.keys(args.dropFirst(3).map(ghosttyKeyName), to: s) { err in print(err.map { "\($0)" } ?? "ok"); sem.signal() }
                sem.wait()
            }
            return
        }
        // Test mode: draw the Settings tab into a PNG. Usage: ClaudeStack --settings-snapshot out.png
        if args.count >= 3, args[1] == "--settings-snapshot" {
            MainActor.assumeIsolated { settingsSnapshot(to: args[2]) }
            return
        }
        // Test mode: a simulated workday, printing each reminder as it appears. Usage: ClaudeStack --coach-sim
        if args.count >= 2, args[1] == "--coach-sim" { coachSim(); return }
        // Test mode: print the input line of a Ghostty terminal. Usage: ClaudeStack --read-input <terminal id>
        if args.count >= 3, args[1] == "--read-input" { print(readInputLine(args[2]) ?? "(none)"); return }
        // Test mode: is Claude Code listening in this tab right now? Usage: ClaudeStack --listening <terminal id>
        if args.count >= 3, args[1] == "--listening" { print((readScreen(args[2]) ?? "").contains("listening") ? "listening" : "-"); return }
        // Test mode: clear the input line the way voice does. Usage: ClaudeStack --clear-input <terminal id>
        if args.count >= 3, args[1] == "--clear-input" {
            clearInputLine(args[2], count: readInputLine(args[2])?.count ?? 0)
            print(readInputLine(args[2]) ?? "(none)")
            return
        }
        // Test mode: hold voice in a tab for N seconds, then print what came back.
        // Usage: ClaudeStack --tab-voice <terminal id> <tty> <seconds>
        if args.count >= 5, args[1] == "--tab-voice" {
            let s = Session(session_id: "test", cwd: nil, project: nil, branch: nil, status: nil, reason: nil, prompt: nil,
                            pid: nil, tty: args[3], term: "ghostty", started_at: nil, updated_at: nil, status_since: nil,
                            transcript_path: nil, last_tool: nil, last_detail: nil, pending_tool: nil, pending_detail: nil)
            let v = TabVoice()
            var finished = false
            v.onUpdate = { state, text, err in
                print("\(state): \(text)\(err.map { " (\($0))" } ?? "")")
                if state == "done" { finished = true }
            }
            v.start(s)
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(args[4]) ?? 4)) { v.stop() }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
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
    let view = StackView(store: store, prefs: prefs, reader: model, coach: DayCoach(), focuser: Focuser(),
                         onDrag: { _ in }, onResetPosition: {})
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
    let agents = AgentScanner(transcript: transcript).list(main: r.agents, finished: r.finishedTasks, now: Date().timeIntervalSince1970)
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
        String(data: (try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "null"
    }
    var finished = false
    func waitLoad(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if w.isLoading && n < 50 { return waitLoad(n + 1) }
            let js = "CS.reset({sid:'test'}); CS.setItems(\(json(["sid": "test", "items": items, "hasMore": false]))); CS.setState(\(json(st))); CS.setAgents(\(json(["sid": "test", "agents": agents]))); CS.mode(\(json(st["mode"] ?? "chats"))); var av = document.getElementById('agentsview'); av.scrollTop = av.scrollHeight; \(st["js"] as? String ?? ""); document.title"
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

@MainActor
func coachSnapshot(to path: String) {
    func coach(_ r: Reminder?, phase: String = "working") -> DayCoach {
        let c = DayCoach()
        c.soundOn = false
        c.phase = phase
        c.dayFraction = phase == "windDown" ? 0.95 : 0.55
        c.waterFraction = 0.7
        c.restFraction = 0.4
        c.minutesLeft = phase == "windDown" ? 25 : 250
        c.summary = DaySummary(prompts: 42, tasksDone: 17, agents: 6, water: 5, breaks: 3, workSecs: 6.5 * 3600)
        c.reminder = r
        return c
    }
    let cases: [(Reminder, String)] = [(.water, "working"), (.rest, "working"), (.lunch, "working"),
                                       (.windDown(minutesLeft: 25), "windDown"), (.dayDone, "done"), (.overtime(minutes: 30), "done")]
    let view = HStack(alignment: .top, spacing: 16) {
        ForEach(0..<2) { col in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(cases.enumerated()).filter { $0.offset % 2 == col }, id: \.offset) { item in
                    let c = coach(item.element.0, phase: item.element.1)
                    VStack(spacing: 6) { DayStrip(coach: c); ReminderCard(coach: c) }
                }
            }
            .frame(width: 300)
        }
    }
    .padding(16).background(bg)
    let r = ImageRenderer(content: view)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Uses a real window, not ImageRenderer, because the time and minute boxes are AppKit controls
/// that ImageRenderer draws as blank boxes.
@MainActor
func settingsSnapshot(to path: String) {
    let store = UserDefaults(suiteName: "local.sundaran.claudestack.snapshot")!
    let coach = DayCoach(store: store, useLog: false)
    let host = NSHostingView(rootView: SettingsView(coach: coach, prefs: Prefs(store)).frame(width: 640, height: 900))
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = host
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// Wednesday 2026-10-07, default hours. Busy all day except a 6-minute pause at 11:40 and lunch.
/// Each reminder is answered one minute after it appears, as a person would.
func coachSim() {
    let store = UserDefaults(suiteName: "local.sundaran.claudestack.sim")!
    store.removePersistentDomain(forName: "local.sundaran.claudestack.sim")
    let c = DayCoach(store: store, useLog: false)
    c.soundOn = false
    c.config = DayConfig()
    let cal = Calendar.current
    var t = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 30))!
    let stop = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 19, minute: 5))!
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    var shownAt: Date?
    var last: String?
    while t < stop {
        let m = cal.component(.hour, from: t) * 60 + cal.component(.minute, from: t)
        // At the desk all day, except a 6-minute pause at 11:40 and lunch away from the Mac.
        let away = (m >= 11 * 60 + 40 && m < 11 * 60 + 46) || (m >= 13 * 60 && m < 13 * 60 + 45)
        let awaySince = m >= 13 * 60 ? 13 * 60 : 11 * 60 + 40
        c.tick(busy: !away, idle: away ? Double(m - awaySince) * 60 + 1 : 2, now: t)
        // Print the kind only: "25 minutes left" counting down is the same card.
        let name = c.reminder.map { String("\($0)".prefix { $0 != "(" }) }
        if name != last, let name { print("\(f.string(from: t)) \(name)"); shownAt = t }
        last = name
        if let s = shownAt, c.reminder != nil, t.timeIntervalSince(s) >= 60 { c.done(); shownAt = nil; last = nil }
        t = t.addingTimeInterval(5)
    }
    print("summary work=\(hm(c.summary.workSecs)) water=\(c.summary.water) breaks=\(c.summary.breaks) phase=\(c.phase)")
    // Saturday: no reminders at all.
    let sat = DayCoach(store: store, useLog: false)
    sat.config = DayConfig()
    sat.soundOn = false
    var s = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 30))!
    var any = false
    for _ in 0..<(4 * 720) { sat.tick(busy: true, idle: 2, now: s); if sat.reminder != nil { any = true }; s = s.addingTimeInterval(5) }
    print("saturday phase=\(sat.phase) reminders=\(any)")
}
