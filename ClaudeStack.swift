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
    let last_tool: String?
    let last_detail: String?
    let pending_tool: String?
    let pending_detail: String?
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
    var hex: String {
        switch self {
        case .needs: return "#FF9A00"
        case .running: return "#5B9BE6"
        case .stuck: return "#F4A500"
        case .done: return "#06C27A"
        case .ready: return "#5FA889"
        case .idle: return "#8A9BAE"
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
    var agents = 0           // subagent files that changed in the last 90 s
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
    let d: UserDefaults
    @Published var soundOnNeeds: Bool { didSet { d.set(soundOnNeeds, forKey: "soundOnNeeds") } }
    @Published var bannerOnNeeds: Bool { didSet { d.set(bannerOnNeeds, forKey: "bannerOnNeeds") } }
    @Published var soundOnDone: Bool { didSet { d.set(soundOnDone, forKey: "soundOnDone") } }
    @Published var compact: Bool { didSet { d.set(compact, forKey: "compact") } }
    @Published var reader: Bool { didSet { d.set(reader, forKey: "reader") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }

    /// Test modes pass their own store, so they never change the real settings.
    init(_ d: UserDefaults = .standard) {
        self.d = d
        d.register(defaults: ["soundOnNeeds": true, "bannerOnNeeds": true, "soundOnDone": false, "compact": false,
                              "reader": false, "fontSize": 15.0])
        soundOnNeeds = d.bool(forKey: "soundOnNeeds")
        bannerOnNeeds = d.bool(forKey: "bannerOnNeeds")
        soundOnDone = d.bool(forKey: "soundOnDone")
        compact = d.bool(forKey: "compact")
        reader = d.bool(forKey: "reader")
        fontSize = d.double(forKey: "fontSize")
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var rows: [Row] = []
    @Published var now = Date().timeIntervalSince1970
    let prefs: Prefs
    var onChange: (() -> Void)?
    var onRows: (([Row]) -> Void)?
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
            if let tp = s.transcript_path { row.agents = activeAgentCount(transcript: tp, now: now) }
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
        onRows?(out)
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
    func focus(_ s: Session) {
        let t = Terminals.shared
        t.q.async {
            let term = (s.term ?? "").lowercased()
            guard term == "ghostty" || term.isEmpty else {
                let apps = ["vscode": "Visual Studio Code", "apple_terminal": "Terminal", "iterm.app": "iTerm", "warpterminal": "Warp"]
                if let name = apps[term] { run("/usr/bin/osascript", ["-e", "tell application \"\(name)\" to activate"]) }
                return
            }
            if let tid = t.terminalId(for: s, focus: true) {
                run("/usr/bin/osascript", ["-e", """
                    tell application "Ghostty"
                      focus terminal id "\(tid)"
                      activate
                    end tell
                    """], wait: true)
            } else {
                run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\" to activate"])
            }
        }
    }
}

