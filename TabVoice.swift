// Voice through Claude Code itself, so it is exactly the voice you get in Ghostty.
// Holding space in the box sends a stream of spaces to the tab (like a held key), Claude Code
// listens and writes the words into its input line, then the app moves those words into the box.
import AppKit
import Foundation

/// One line per step in ~/.claude/stack/voice.log, so a failed try can be read afterwards.
func voiceLog(_ msg: String) {
    let url = stackDir.appendingPathComponent("voice.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

final class TabVoice {
    private var startedAt: Date?
    /// True from the hold until the release. The tab lookup is slow, so it checks this before sending.
    private var wanted = false
    /// (state, text, error). States: listening, writing, done.
    var onUpdate: ((String, String, String?) -> Void)?
    /// The helper that sends the "held space". A separate process, so nothing else can slow it down.
    private var streamer: Process?
    /// True while a voice try is sending spaces. Main thread only.
    var busy: Bool { streamer != nil }
    private var tid: String?
    private var baseline = ""
    private var session: Session?
    /// Goes up on every new try and on cancel. An older try that sees a newer number stops quietly,
    /// so it never blocks the next try or reports into it.
    private var gen = 0
    private let lock = NSLock()
    private func current(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == g }
    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; gen += 1; return gen }

    /// Starts listening in the session's tab. Runs the lookups off the main thread.
    func start(_ s: Session) {
        guard streamer == nil else { return }
        let g = bump()
        wanted = true
        session = s
        voiceLog("start session=\(s.session_id.prefix(8)) tty=\(s.tty ?? "-") term=\(s.term ?? "-")")
        let t = Terminals.shared
        t.q.async {
            guard self.current(g) else { return voiceLog("start replaced by a newer try") }
            guard let tid = t.terminalId(for: s) else {
                voiceLog("no terminal found")
                return self.report("done", "", "Could not find this tab in Ghostty, so voice cannot start.")
            }
            // What the input line shows before you speak (a placeholder, or a draft you typed).
            // Read before showing the tab: while the tab switches, the grey suggestion is briefly
            // gone, and coming back it would look like your words.
            let base = readInputLine(tid) ?? ""
            // Claude Code's voice gives no words in a hidden tab, so show this tab first.
            let shown = t.showTab(tid)
            if shown { Thread.sleep(forTimeInterval: 0.3) }
            voiceLog("terminal=\(tid.prefix(8)) shown=\(shown) baseline=\(base.prefix(40))")
            DispatchQueue.main.async {
                // You let go while the tab was being found: do not start sending spaces.
                guard self.wanted, self.current(g) else { return voiceLog("released before start, nothing sent") }
                self.tid = tid
                self.baseline = base
                // Ghostty's "text" action types like the keyboard. Claude Code keeps listening only
                // while spaces keep coming with no gap, so a steady space every 10 ms, from its own
                // process. Stopped on release; ends by itself after 60 seconds as a safety cap.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", """
                    tell application "Ghostty"
                      repeat 6000 times
                        perform action "text: " on terminal id "\(tid)"
                        delay 0.01
                      end repeat
                    end tell
                    """]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch {
                    voiceLog("could not start the space stream: \(error)")
                    return self.report("done", "", "Could not start voice: \(error.localizedDescription)")
                }
                self.streamer = p
                self.startedAt = Date()
                self.report("listening", "", nil)
                self.followWords(tid: tid, base: base, gen: g)
            }
        }
    }

    /// While you hold space, read the tab's input line every 0.3 s and show the words in the box
    /// as Claude Code writes them. Stops on release, because `stop` and `cancel` move the number on.
    private func followWords(tid: String, base: String, gen g: Int) {
        let q = Terminals.shared.q
        DispatchQueue.global().async {
            var shown = ""
            while self.current(g) {
                Thread.sleep(forTimeInterval: 0.3)
                guard self.current(g), let raw = q.sync(execute: { readInputLine(tid) }) else { continue }
                // Claude Code draws a moving mark after the words while it listens. That mark is
                // its animation, not your words, and looks broken in the box, so it is cut here.
                let now = withoutVoiceMark(raw)
                if raw != now { voiceLog("live mark cut: \(raw.suffix(raw.count - now.count).unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))") }
                // A status hint in the input line is not your words.
                guard self.current(g), now != base, now != shown, !now.lowercased().contains("listening") else { continue }
                shown = now
                self.report("listening", now, nil)
            }
        }
    }

    /// The app is quitting: stop sending at once, take nothing.
    /// Also used when you switch chats: a reading loop still running stops, and leaves any words
    /// in the old tab rather than putting them into the new chat.
    func cancel() {
        _ = bump()
        wanted = false
        streamer?.terminate()
        streamer = nil
    }

    /// You let go of space: stop the key stream, wait for Claude Code to write the words, take them.
    func stop() {
        wanted = false
        // Let go before voice had started (the tab lookup takes a moment): say so, never hang.
        guard let streamer else {
            voiceLog("stop before start")
            return report("done", "", "Voice had not started yet. Hold space until \"Listening\" shows, then speak.")
        }
        streamer.terminate()
        self.streamer = nil
        let held = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        voiceLog("stop after \(String(format: "%.1f", held)) s, stream exit=\(streamer.isRunning ? "running" : "\(streamer.terminationStatus)")")
        guard let tid else { return }
        report("writing", "", nil)
        let base = baseline
        let g = bump()
        let q = Terminals.shared.q
        // The waiting happens here, not on the Ghostty queue: each read takes the queue only for a
        // moment, so a try in another chat can start straight away.
        DispatchQueue.global().async {
            var last: String?
            var same = 0
            var text = ""
            // Claude Code needs a moment to turn the recording into text, and adds the last words
            // late. Take the line once it has stayed the same for three reads (about a second).
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.35)
                guard self.current(g) else { return voiceLog("read stopped: a newer try or a chat switch") }
                guard let now = q.sync(execute: { readInputLine(tid) }) else { continue }
                same = (now == last) ? same + 1 : 0
                last = now
                if same >= 2, now != base { text = now; break }
            }
            voiceLog("read text=\(text.prefix(60)) last=\((last ?? "nil").prefix(40))")
            if text.isEmpty {
                // Keep Claude Code's status lines, so the reason can be read in voice.log afterwards.
                let tail = q.sync { readScreen(tid) }?.components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("─") }.suffix(3)
                voiceLog("no words; screen bottom: \((tail ?? []).joined(separator: " | ").prefix(300))")
                guard self.current(g) else { return }
                return self.report("done", "", "No words came through. Hold space a little longer, and speak after \"listening\" shows.")
            }
            guard self.current(g) else { return voiceLog("read stopped before moving the words") }
            // Move the words: clear the tab's input line, then hand them to the box.
            q.sync { clearInputLine(tid, count: text.count) }
            self.report("done", withoutVoiceMark(text), nil)
        }
    }

    private func report(_ state: String, _ text: String, _ err: String?) {
        DispatchQueue.main.async { self.onUpdate?(state, text, err) }
    }
}

/// The words without the animation mark Claude Code puts after them while listening: trailing
/// symbols (bars, dots, braille spinners), a trailing "…", and spaces.
func withoutVoiceMark(_ text: String) -> String {
    var t = Substring(text)
    while let c = t.last, let u = c.unicodeScalars.first,
          c.isWhitespace || c == "…" || u.properties.generalCategory == .otherSymbol
            || u.properties.generalCategory == .privateUse || u.properties.generalCategory == .format {
        t = t.dropLast()
    }
    return String(t)
}

/// Deletes `count` characters before the cursor in the tab's input line.
/// Not Ctrl+U: in Claude Code that clears only the current screen row of a long input.
/// The cursor is at the end after voice, so Backspace (DEL, 0x7f) removes exactly the words.
func clearInputLine(_ tid: String, count: Int) {
    var left = count + 3
    while left > 0 {
        let n = min(left, 200)
        let dels = String(repeating: "\\\\x7f", count: n)
        run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\" to perform action \"text:\(dels)\" on terminal id \"\(tid)\""], wait: true)
        left -= n
    }
}

/// Reads the text in Claude Code's input line in a Ghostty tab.
func readInputLine(_ tid: String) -> String? {
    readScreen(tid).flatMap(inputLine(fromScreen:))
}

/// The visible screen of a Ghostty tab, as text.
/// Ghostty hands over the screen only through the clipboard, so this borrows it for a moment
/// and puts back exactly what was there.
/// With `colours`, the file keeps the terminal's colour codes (Ghostty's "vt" format).
func readScreen(_ tid: String, colours: Bool = false) -> String? {
    let pb = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    let before = pb.changeCount
    run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\" to perform action \"write_screen_file:copy\(colours ? ",vt" : "")\" on terminal id \"\(tid)\""], wait: true)
    var path: String?
    for _ in 0..<50 {
        if pb.changeCount != before { path = pb.string(forType: .string); break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    // Put your clipboard back, whatever happened.
    if pb.changeCount != before {
        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in pairs { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
    ClipWatch.ours()
    guard let path, let screen = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(atPath: path)
    return screen
}

/// Claude Code draws its input between two rules, starting with "❯" and a no-break space.
/// Returns the text in it.
func inputLine(fromScreen screen: String) -> String? {
    let lines = screen.components(separatedBy: "\n")
    guard let start = lines.lastIndex(where: { $0.hasPrefix("❯") }) else { return nil }
    var parts: [String] = []
    for (i, line) in lines[start...].enumerated() {
        if i > 0 && line.hasPrefix("─") { break }
        var l = line
        if i == 0 { l = String(l.dropFirst()) }
        // .whitespaces includes the no-break space (U+00A0) Claude Code puts after the "❯".
        let t = l.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { parts.append(t) }
    }
    return parts.joined(separator: " ")
}
