// ClaudeStack: a floating, draggable stack that shows every Claude Code session.
// It reads ~/.claude/stack/sessions/*.json, written by stack-hook.sh.
import AppKit
import Combine
import SwiftUI

// MARK: - Data

let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/stack/sessions")

struct Session: Decodable {
    let session_id: String
    let cwd: String?
    let project: String?
    let branch: String?
    let status: String?
    let reason: String?
    let prompt: String?
    let pid: Int32?
    let tty: String?
    let term: String?
    let started_at: Double?
    let updated_at: Double?
    let status_since: Double?
    let transcript_path: String?
}

enum Display: Int {
    case needs = 0, running, stuck, done, ready, idle

    var label: String {
        switch self {
        case .needs: return "Needs you"
        case .running: return "Running"
        case .stuck: return "Maybe stuck"
        case .done: return "Done"
        case .ready: return "Ready"
        case .idle: return "Idle"
        }
    }
    var color: Color {
        switch self {
        case .needs: return Color(hex: 0xFF9A00)
        case .running: return Color(hex: 0x5B9BE6)
        case .stuck: return Color(hex: 0xF4A500)
        case .done: return Color(hex: 0x06C27A)
        case .ready: return Color(hex: 0x5FA889)
        case .idle: return Color(hex: 0x8A9BAE)
        }
    }
    var icon: String {
        switch self {
        case .needs: return "hand.raised.fill"
        case .running: return "hourglass"
        case .stuck: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .ready: return "circle"
        case .idle: return "moon.zzz.fill"
        }
    }
}

let stuckAfter: Double = 600   // running with no event for 10 min
let idleAfter: Double = 600    // done for 10 min

struct Row: Identifiable {
    let s: Session
    var background = false   // runs under the Claude daemon, not in a tab
    let display: Display
    let since: Double
    let stopped: Bool
    var id: String { s.session_id }

    init(_ s: Session, now: Double, interruptedAt: Double? = nil) {
        self.s = s
        // Esc sends no hook event, so the transcript is the only sign of it.
        if let t = interruptedAt, t >= (s.updated_at ?? .infinity),
           s.status == "needs_input" || s.status == "running" {
            stopped = true
            since = t
            display = now - t > idleAfter ? .idle : .done
            return
        }
        stopped = false
        let since = s.status_since ?? s.updated_at ?? now
        self.since = since
        switch s.status ?? "running" {
        case "needs_input": display = .needs
        case "waiting":
            if s.reason == "Ready" { display = .ready }
            else { display = now - since > idleAfter ? .idle : .done }
        default:
            display = now - (s.updated_at ?? now) > stuckAfter ? .stuck : .running
        }
    }

    var title: String { s.project ?? "Claude" }
    var detail: String {
        if stopped && display == .done { return "Stopped" }
        if display == .needs, let r = s.reason, !r.isEmpty { return r }
        return display.label
    }
}

func ago(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Settings

final class Prefs: ObservableObject {
    let d = UserDefaults.standard
    @Published var soundOnNeeds: Bool { didSet { d.set(soundOnNeeds, forKey: "soundOnNeeds") } }
    @Published var bannerOnNeeds: Bool { didSet { d.set(bannerOnNeeds, forKey: "bannerOnNeeds") } }
    @Published var soundOnDone: Bool { didSet { d.set(soundOnDone, forKey: "soundOnDone") } }
    @Published var compact: Bool { didSet { d.set(compact, forKey: "compact") } }

    init() {
        d.register(defaults: ["soundOnNeeds": true, "bannerOnNeeds": true, "soundOnDone": false, "compact": false])
        soundOnNeeds = d.bool(forKey: "soundOnNeeds")
        bannerOnNeeds = d.bool(forKey: "bannerOnNeeds")
        soundOnDone = d.bool(forKey: "soundOnDone")
        compact = d.bool(forKey: "compact")
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var rows: [Row] = []
    @Published var now = Date().timeIntervalSince1970
    let prefs: Prefs
    var onChange: (() -> Void)?
    private var last: [String: Display] = [:]
    private var firstLoad = true
    private var timer: Timer?

    init(prefs: Prefs) {
        self.prefs = prefs
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
    }

    func reload() {
        let now = Date().timeIntervalSince1970
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [Row] = []
        var fileOf: [String: URL] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else { continue }
            // The tab was closed or Claude was killed without a SessionEnd event.
            if let pid = s.pid, kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: f); continue
            }
            if s.pid == nil, now - (s.updated_at ?? 0) > 3 * 3600 {
                try? fm.removeItem(at: f); continue
            }
            var interruptedAt: Double? = nil
            if let tp = s.transcript_path {
                let tail = transcriptTail(tp)
                // The chat moved on to a new session id (/bg, agent view). This one is over.
                if tail.continued { try? fm.removeItem(at: f); continue }
                if s.status == "needs_input" || s.status == "running" { interruptedAt = tail.interruptedAt }
            }
            // A spare the daemon made in advance. Nobody has used it yet.
            let bg = s.pid.map(isBackground) ?? false
            if bg, s.status == "waiting", s.reason == "Ready", s.prompt == nil { continue }
            var row = Row(s, now: now, interruptedAt: interruptedAt)
            row.background = bg
            out.append(row)
            fileOf[s.session_id] = f
        }
        // One Claude process runs one session at a time (/clear, /resume). Keep the newest.
        var newest: [Int32: Double] = [:]
        for r in out { if let p = r.s.pid { newest[p] = max(newest[p] ?? 0, r.s.started_at ?? 0) } }
        out.removeAll { r in
            guard let p = r.s.pid, (r.s.started_at ?? 0) < (newest[p] ?? 0) else { return false }
            if let f = fileOf[r.id] { try? fm.removeItem(at: f) }
            return true
        }
        out.sort { a, b in
            a.display.rawValue != b.display.rawValue
                ? a.display.rawValue < b.display.rawValue
                : (a.s.started_at ?? 0) < (b.s.started_at ?? 0)
        }
        alertOnChanges(out)
        let changed = out.map { "\($0.id)\($0.display)" } != rows.map { "\($0.id)\($0.display)" }
        rows = out
        self.now = now
        if changed { onChange?() }
    }

    // pid -> runs under a "--bg-pty-host" parent. Asked once per process.
    private var bgCache: [Int32: Bool] = [:]
    private func isBackground(_ pid: Int32) -> Bool {
        if let b = bgCache[pid] { return b }
        let ppid = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"], wait: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = !ppid.isEmpty && run("/bin/ps", ["-o", "args=", "-p", ppid], wait: true).contains("--bg-pty-host")
        bgCache[pid] = b
        return b
    }

    // path -> (file time, what the end of the transcript says)
    private var tailCache: [String: (Date, (interruptedAt: Double?, continued: Bool))] = [:]
    private let isoFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Reads the end of the transcript.
    // interruptedAt: time of the Esc when the last user line is "[Request interrupted by user...]".
    // continued: a "continued-in" line comes after the last message, so the chat lives on elsewhere.
    private func transcriptTail(_ path: String) -> (interruptedAt: Double?, continued: Bool) {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return (nil, false) }
        if let c = tailCache[path], c.0 == mtime { return c.1 }
        var result: Double? = nil
        var continued = false
        var seenMessage = false
        if let h = FileHandle(forReadingAtPath: path) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 65536 ? size - 65536 : 0)
            let data = (try? h.readToEnd()) ?? Data()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
            for line in lines {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = o["type"] as? String
                if type == "continued-in" && !seenMessage { continued = true }
                if type == "user" || type == "assistant" { seenMessage = true }
                guard type == "user", o["isMeta"] as? Bool != true,
                      let msg = o["message"] as? [String: Any] else { continue }
                // The first real user line from the end decides it.
                if let items = msg["content"] as? [[String: Any]],
                   items.contains(where: { ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }),
                   let ts = o["timestamp"] as? String, let d = isoFormat.date(from: ts) {
                    result = d.timeIntervalSince1970
                }
                break
            }
        }
        tailCache[path] = (mtime, (result, continued))
        return (result, continued)
    }

    private func alertOnChanges(_ rows: [Row]) {
        var next: [String: Display] = [:]
        for r in rows {
            next[r.id] = r.display
            let before = last[r.id]
            guard !firstLoad, before != r.display else { continue }
            if r.display == .needs {
                if prefs.soundOnNeeds { NSSound(named: "Glass")?.play() }
                if prefs.bannerOnNeeds { banner(title: "Claude needs you", body: "\(r.title): \(r.detail)") }
            } else if r.display == .done && before == .running && prefs.soundOnDone {
                NSSound(named: "Pop")?.play()
            }
        }
        last = next
        firstLoad = false
    }

    private func banner(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }
}

@discardableResult
func run(_ path: String, _ args: [String], wait: Bool = false) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    guard wait else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - Jump to the tab

final class Focuser {
    private var cache: [String: String] = [:]   // session id -> Ghostty terminal id
    private let q = DispatchQueue(label: "focus")

    func focus(_ s: Session) {
        q.async { self.doFocus(s) }
    }

    private func doFocus(_ s: Session) {
        let term = (s.term ?? "").lowercased()
        guard term == "ghostty" || term.isEmpty else {
            let apps = ["vscode": "Visual Studio Code", "apple_terminal": "Terminal", "iterm.app": "iTerm", "warpterminal": "Warp"]
            if let name = apps[term] { run("/usr/bin/osascript", ["-e", "tell application \"\(name)\" to activate"]) }
            return
        }
        if let tid = cache[s.session_id] {
            let ok = run("/usr/bin/osascript", ["-e", """
                tell application "Ghostty"
                  try
                    focus (first terminal whose id is "\(tid)")
                    activate
                    return "ok"
                  end try
                end tell
                """], wait: true)
            if ok == "ok" { return }
            cache[s.session_id] = nil
        }
        guard let tty = s.tty, !tty.isEmpty else {
            run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\" to activate"]); return
        }
        // Give the tab a hidden temporary title, find the terminal with it, then put the old title back.
        let token = "CSTK-\(UUID().uuidString.prefix(8))"
        let script = """
            on run argv
              set ttyPath to item 1 of argv
              set token to item 2 of argv
              tell application "Ghostty"
                set ids to id of every terminal
                set names to name of every terminal
              end tell
              do shell script "printf '\\\\033]2;%s\\\\007' " & quoted form of token & " > " & quoted form of ttyPath
              repeat 20 times
                delay 0.05
                tell application "Ghostty"
                  set found to (every terminal whose name contains token)
                  if (count of found) > 0 then
                    set t to item 1 of found
                    set tid to id of t
                    focus t
                    activate
                    set oldName to ""
                    repeat with i from 1 to count of ids
                      if item i of ids is tid then set oldName to item i of names
                    end repeat
                    return tid & linefeed & oldName
                  end if
                end tell
              end repeat
              tell application "Ghostty" to activate
              return ""
            end run
            """
        let out = run("/usr/bin/osascript", ["-e", script, "/dev/\(tty)", token], wait: true)
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let tid = parts.first, !tid.isEmpty else { return }
        cache[s.session_id] = tid
        let oldName = parts.count > 1 ? parts[1] : ""
        if let h = FileHandle(forWritingAtPath: "/dev/\(tty)") {
            h.write("\u{1b}]2;\(oldName)\u{07}".data(using: .utf8)!)
            try? h.close()
        }
    }
}

// MARK: - Views

let bg = Color(hex: 0x0F1923)
let surface = Color(hex: 0x1C2B3A)
let borderC = Color(hex: 0x2E3F50)
let textC = Color(hex: 0xF0F4F8)
let muted = Color(hex: 0x8A9BAE)

/// 0...1 wave for blinking and pulsing.
func wave(_ t: Double, hz: Double) -> Double { 0.5 + 0.5 * cos(t * 2 * .pi * hz) }

struct RowView: View {
    let row: Row
    let now: Double
    let t: Double
    let onTap: () -> Void
    @State private var hover = false

    var subtitle: String {
        if let p = row.s.prompt, !p.isEmpty { return p }
        return row.display == .ready ? "Waiting for your first message" : (row.s.cwd ?? "")
    }

    var body: some View {
        let c = row.display.color
        let needs = row.display == .needs
        let blink = needs ? wave(t, hz: 1.6) : 1
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(c.opacity(needs ? 0.25 + 0.35 * blink : 0.18)).frame(width: 26, height: 26)
                Image(systemName: row.display.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(c)
                    .opacity(row.display == .running ? 0.45 + 0.55 * wave(t, hz: 0.6) : 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundColor(textC).lineLimit(1).layoutPriority(1)
                    if row.background {
                        Text("BG").font(.system(size: 9, weight: .bold)).foregroundColor(muted)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(muted, lineWidth: 1))
                    }
                    if let b = row.s.branch, !b.isEmpty {
                        Text(b).font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11)).foregroundColor(muted).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.detail).font(.system(size: 11, weight: .bold)).foregroundColor(c)
                Text(ago(now - row.since)).font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(needs ? c.opacity(0.10 + 0.16 * blink) : (hover ? surface.opacity(1) : surface.opacity(0.6)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(needs ? c.opacity(0.4 + 0.6 * blink) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .help("Click to open this tab")
    }
}

struct StackView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs
    let focuser: Focuser
    let onDrag: (DragGesture.Value?) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            content(t: tl.date.timeIntervalSinceReferenceDate)
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onDrag($0) }
            .onEnded { _ in onDrag(nil) })
        .contextMenu { menu }
    }

    func content(t: Double) -> some View {
        let needCount = store.rows.filter { $0.display == .needs }.count
        let strokeColor: Color = needCount > 0
            ? Display.needs.color.opacity(0.35 + 0.65 * wave(t, hz: 1.6))
            : borderC
        let lineWidth: CGFloat = needCount > 0 ? 2 : 1
        return VStack(alignment: .leading, spacing: 6) {
            header(needCount: needCount, t: t)
            if !prefs.compact { rowList(t: t) }
        }
        .padding(8)
        .frame(width: prefs.compact ? nil : 320, alignment: .leading)
        .fixedSize(horizontal: prefs.compact, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12).fill(bg.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(strokeColor, lineWidth: lineWidth))
    }

    func rowList(t: Double) -> some View {
        ForEach(store.rows) { r in
            RowView(row: r, now: store.now, t: t) { focuser.focus(r.s) }
        }
    }

    func header(needCount: Int, t: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(Color(hex: 0xFF9A00))
            Text("Claude").font(.system(size: 12, weight: .bold)).foregroundColor(textC)
            if prefs.compact {
                ForEach([Display.needs, .running, .stuck, .done, .ready, .idle], id: \.rawValue) { d in
                    let n = store.rows.filter { $0.display == d }.count
                    if n > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: d.icon).font(.system(size: 10, weight: .bold)).foregroundColor(d.color)
                                .opacity(d == .needs ? 0.3 + 0.7 * wave(t, hz: 1.6) : 1)
                            Text("\(n)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(d.color)
                        }
                    }
                }
            } else {
                Spacer()
                if needCount > 0 {
                    Text("\(needCount) need\(needCount == 1 ? "s" : "") you")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Display.needs.color)
                } else {
                    Text("\(store.rows.count) session\(store.rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundColor(muted)
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { prefs.compact.toggle() }
        .help("Drag to move. Double-click to shrink or grow.")
    }

    @ViewBuilder var menu: some View {
        Toggle("Sound when a tab needs you", isOn: $prefs.soundOnNeeds)
        Toggle("Mac banner when a tab needs you", isOn: $prefs.bannerOnNeeds)
        Toggle("Sound when a task is done", isOn: $prefs.soundOnDone)
        Divider()
        Toggle("Compact (pill)", isOn: $prefs.compact)
        Button("Reset position", action: onResetPosition)
        Divider()
        Button("Quit Claude Stack") { NSApp.terminate(nil) }
    }
}

// MARK: - Window

final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { false }   // never takes the keyboard
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: StackPanel!
    var hosting: NSHostingView<StackView>!
    let prefs = Prefs()
    lazy var store = Store(prefs: prefs)
    let focuser = Focuser()
    var dragStartOrigin: NSPoint?
    var dragStartMouse: NSPoint?

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

        let view = StackView(store: store, prefs: prefs, focuser: focuser,
                             onDrag: { [weak self] v in self?.drag(v) },
                             onResetPosition: { [weak self] in self?.resetPosition() })
        hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        store.onChange = { [weak self] in DispatchQueue.main.async { self?.layout() } }
        prefsObserver = prefs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
        layout()
    }
    var prefsObserver: Any?

    /// Size the panel to its content. The top-left corner stays where the user put it.
    func layout() {
        guard !store.rows.isEmpty else { panel.orderOut(nil); return }
        let size = hosting.fittingSize
        let topLeft = savedTopLeft() ?? defaultTopLeft()
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        frame = clampToScreen(frame)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
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
        // Test mode: draw the stack once into a PNG and exit. Usage: ClaudeStack --snapshot out.png [compact]
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--snapshot" {
            MainActor.assumeIsolated { snapshot(to: args[2], compact: args.count > 3) }
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
    let prefs = Prefs()
    prefs.compact = compact
    let store = Store(prefs: prefs)
    let view = StackView(store: store, prefs: prefs, focuser: Focuser(), onDrag: { _ in }, onResetPosition: {})
        .padding(20).background(Color(hex: 0x3A3F47))
    let r = ImageRenderer(content: view)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    prefs.compact = false
}
