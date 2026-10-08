// Talks to Ghostty: find the terminal of a session, paste text into it, press keys in it.
// The worst bug here is text going to the wrong tab, so every send checks the target first.
import Foundation

final class Terminals {
    static let shared = Terminals()
    /// session id -> Ghostty terminal id. Found by a token on the session's own tty, so it is exact.
    private var cache: [String: String] = [:]
    let q = DispatchQueue(label: "ghostty")

    /// Runs on `q`. Returns the terminal id, or nil when it cannot be proved.
    func terminalId(for s: Session, focus: Bool = false) -> String? {
        if let tid = cache[s.session_id], exists(tid) { return tid }
        cache[s.session_id] = nil
        guard let tty = s.tty, !tty.isEmpty else { return nil }
        let tid = findByToken(tty: tty, focus: focus)
        if let tid { cache[s.session_id] = tid }
        return tid
    }

    private func exists(_ tid: String) -> Bool {
        run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\" to return exists terminal id \"\(tid)\""], wait: true) == "true"
    }

    /// Give the tab a hidden temporary title, find the terminal with it, then put the old title back.
    private func findByToken(tty: String, focus: Bool) -> String? {
        let token = "CSTK-\(UUID().uuidString.prefix(8))"
        let focusLines = focus ? "focus t\n                    activate" : ""
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
                  if (count of found) = 1 then
                    set t to item 1 of found
                    set tid to id of t
                    \(focusLines)
                    set oldName to ""
                    repeat with i from 1 to count of ids
                      if item i of ids is tid then set oldName to item i of names
                    end repeat
                    return tid & linefeed & oldName
                  end if
                end tell
              end repeat
              return ""
            end run
            """
        let out = run("/usr/bin/osascript", ["-e", script, "/dev/\(tty)", token], wait: true)
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let tid = parts.first, !tid.isEmpty else { return nil }
        let oldName = parts.count > 1 ? parts[1] : ""
        if let h = FileHandle(forWritingAtPath: "/dev/\(tty)") {
            h.write("\u{1b}]2;\(oldName)\u{07}".data(using: .utf8)!)
            try? h.close()
        }
        return tid
    }

    // MARK: - Sending

    enum SendError: Error, CustomStringConvertible {
        case notGhostty, gone, notFound, failed(String)
        var description: String {
            switch self {
            case .notGhostty: return "This session is not in a Ghostty tab, so the box cannot type into it."
            case .gone: return "This Claude has stopped. Nothing was sent."
            case .notFound: return "Could not find this tab in Ghostty. Nothing was sent."
            case .failed(let m): return "Ghostty did not accept it: \(m)"
            }
        }
    }

    /// Checks that the session is a live Ghostty tab and returns its terminal id. Runs on `q`.
    private func target(_ s: Session) -> Result<String, SendError> {
        let term = (s.term ?? "").lowercased()
        guard term == "ghostty" || term.isEmpty else { return .failure(.notGhostty) }
        guard let pid = s.pid, kill(pid, 0) == 0 || errno != ESRCH else { return .failure(.gone) }
        guard let tid = terminalId(for: s) else { return .failure(.notFound) }
        return .success(tid)
    }

    /// Pastes `text` into the session's tab, then presses Enter.
    func send(_ text: String, to s: Session, done: @escaping (SendError?) -> Void) {
        q.async {
            switch self.target(s) {
            case .failure(let e): done(e)
            case .success(let tid):
                let script = """
                    on run argv
                      tell application "Ghostty"
                        input text (item 1 of argv) to terminal id (item 2 of argv)
                        delay 0.15
                        send key "enter" to terminal id (item 2 of argv)
                      end tell
                      return "ok"
                    end run
                    """
                let out = run("/usr/bin/osascript", ["-e", script, text, tid], wait: true)
                done(out == "ok" ? nil : .failed(out.isEmpty ? "no answer" : out))
            }
        }
    }

    /// Presses keys in order, for example ["down", "down", "enter"]. Runs on `q`.
    /// With `expect`, the keys go only when the tab's screen shows that text, so answers
    /// never land in a question that is already gone.
    func keys(_ names: [String], to s: Session, expect: String? = nil, done: @escaping (SendError?) -> Void) {
        q.async {
            switch self.target(s) {
            case .failure(let e): done(e)
            case .success(let tid):
                if let expect, !expect.isEmpty {
                    let flat = { (t: String) in t.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                    guard let screen = readScreen(tid), flat(screen).contains(flat(expect)) else {
                        return done(.failed("The question is not on the tab any more. Nothing was sent."))
                    }
                }
                let lines = names.map { "send key \"\($0)\" to terminal id \"\(tid)\"\n    delay 0.08" }.joined(separator: "\n    ")
                let out = run("/usr/bin/osascript", ["-e", "tell application \"Ghostty\"\n    \(lines)\nend tell\nreturn \"ok\""], wait: true)
                done(out == "ok" ? nil : .failed(out.isEmpty ? "no answer" : out))
            }
        }
    }
}
