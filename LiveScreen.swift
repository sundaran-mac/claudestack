// Live answer: while Claude is writing, the words are on the tab's screen long before they reach
// the transcript (Claude Code saves a message only when it is done). So the reader reads the
// screen a couple of times a second and shows the newest answer as a plain "writing" bubble.
import AppKit
import Foundation

/// Keeps the screen reads away from your own copies. `readScreen` borrows the clipboard, so a
/// Cmd+C that lands during a read could be lost. Any change we did not make counts as yours,
/// and the live reads wait until the clipboard has been quiet for a while.
enum ClipWatch {
    private static let lock = NSLock()
    private static var known = NSPasteboard.general.changeCount
    private static var userAt = Date.distantPast

    /// True when nobody but us has touched the clipboard for `seconds`.
    static func quiet(for seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let c = NSPasteboard.general.changeCount
        if c != known { known = c; userAt = Date() }
        return Date().timeIntervalSince(userAt) >= seconds
    }

    /// Called after a screen read put the clipboard back: that change was ours.
    static func ours() {
        lock.lock(); defer { lock.unlock() }
        known = NSPasteboard.general.changeCount
    }
}

/// The answer Claude is writing right now, from a Claude Code screen. Nil when the newest thing
/// on the screen is not answer text: a tool step, your own new prompt, or nothing at all.
/// The screen may carry colour codes (Ghostty's "vt" format). They tell an answer from a tool step:
/// Claude Code draws an answer's "⏺" white (or in the plain text colour) and a tool step's "⏺" grey,
/// green or red, blinking while it runs. Without colour codes only the shape of the block decides.
func liveAnswer(fromScreen screen: String) -> String? {
    let raw = screen.components(separatedBy: "\n")
    var lines = raw.map(stripColours)
    /// Line numbers whose "⏺" is coloured as a tool step.
    var toolMarks = Set(raw.indices.filter { isToolMark(raw[$0]) })
    // A running tool's "⏺" blinks: half the time the line starts with two grey spaces instead.
    // Put the mark back, so the step is still seen as a step and not read as answer text.
    for i in raw.indices where !lines[i].hasPrefix("⏺") && isBlinkedOffMark(raw[i]) {
        lines[i] = "⏺" + lines[i].dropFirst()
        toolMarks.insert(i)
    }
    // Cut the input box and everything under it: the rule line just above the last "❯" line.
    if let input = lines.lastIndex(where: { $0.hasPrefix("❯") }), input > 0, lines[input - 1].hasPrefix("─") {
        lines = Array(lines[..<(input - 1)])
    }
    // The newest Claude block starts with "⏺" at the very start of a line. A long answer may
    // have pushed that line off the top: then the whole screen is the block, and the checks below
    // still refuse it when it holds a prompt or a tool step.
    let marked = lines.lastIndex(where: { $0.hasPrefix("⏺") })
    if let m = marked, toolMarks.contains(m) { return nil }
    var block = Array(lines[(marked ?? 0)...])
    while marked == nil, let f = block.first, f.trimmingCharacters(in: .whitespaces).isEmpty { block.removeFirst() }
    guard !block.isEmpty else { return nil }
    // The spinner ("✻ Thinking… (9s)") and its tip lines sit under the block while Claude works.
    let spinner = Set("✻✢✳✶✽✺*·∗")
    if let s = block.indices.dropFirst().first(where: { i in
        let l = block[i]
        guard let c = l.first, spinner.contains(c), l.dropFirst().first == " " else { return false }
        return l.contains("…") || l.contains("...")
    }) {
        block = Array(block[..<s])
    }
    // A new prompt of yours under the block: Claude has not started the answer to it yet.
    if block.contains(where: { $0.hasPrefix("❯") || $0.hasPrefix(">") }) { return nil }
    // A tool step: "⏺ Bash(...)" in older versions, or a line followed by "  ⎿" output.
    let head = (marked != nil ? String(block[0].dropFirst()) : block[0]).trimmingCharacters(in: .whitespaces)
    if block.contains(where: { $0.hasPrefix("  ⎿") }) { return nil }
    if head.range(of: #"^[A-Za-z_][\w:.-]*\("#, options: .regularExpression) != nil { return nil }
    var out = [head]
    for l in block.dropFirst() {
        // Answer lines are indented by two spaces under the "⏺".
        out.append(l.hasPrefix("  ") ? String(l.dropFirst(2)) : l)
    }
    while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
    let text = out.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        .joined(separator: "\n")
    return text.isEmpty ? nil : text
}

/// Removes terminal colour and style codes, so only the text is left.
func stripColours(_ line: String) -> String {
    guard line.contains("\u{1b}") else { return line }
    return line.replacingOccurrences(of: #"\x{1b}\[[0-9;:?]*[A-Za-z]|\x{1b}\][^\x{07}\x{1b}]*(\x{07}|\x{1b}\\)"#, with: "", options: .regularExpression)
}

/// True when the line starts with a "⏺" drawn in a tool step's colour: any set colour that is not
/// white or black (black is the plain text colour of a light theme).
func isToolMark(_ line: String) -> Bool {
    guard line.contains("⏺"), let r = line.range(of: #"^(\x{1b}\[[0-9;]*m)*⏺"#, options: .regularExpression) else { return false }
    let codes = String(line[r])
    guard let c = codes.range(of: #"38;2;(\d+);(\d+);(\d+)m(?=(\x{1b}\[[0-9;]*m)*⏺)"#, options: .regularExpression) else { return false }
    let rgb = codes[c].dropFirst(5).dropLast(1).split(separator: ";").prefix(3).compactMap { Int($0) }
    return rgb != [255, 255, 255] && rgb != [0, 0, 0]
}

/// True when the line starts with two spaces drawn in a tool step's colour: a "⏺" blinked off.
/// Answer lines start with plain, uncoloured spaces.
func isBlinkedOffMark(_ line: String) -> Bool {
    guard let r = line.range(of: #"^(\x{1b}\[[0-9;]*m)*\x{1b}\[38;2;(\d+);(\d+);(\d+)m  \S"#, options: .regularExpression)
            ?? line.range(of: #"^(\x{1b}\[[0-9;]*m)*\x{1b}\[38;2;(\d+);(\d+);(\d+)m  \x{1b}"#, options: .regularExpression) else { return false }
    return isToolMark(line[r].replacingOccurrences(of: "m  ", with: "m⏺ "))
}
