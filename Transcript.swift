// Reads a Claude Code transcript (.jsonl) into chat items for the reader.
// Only the new bytes are read on each call, because a transcript can be many MB.
import Foundation

/// One bubble in the reader. `blocks` holds text and tool steps in order.
final class ChatItem {
    let id: String
    let role: String          // user, assistant, command, output, note
    var blocks: [[String: Any]] = []
    var version = 0
    let time: String?

    init(id: String, role: String, time: String?) {
        self.id = id; self.role = role; self.time = time
    }

    var json: [String: Any] {
        ["id": id, "role": role, "blocks": blocks, "v": version, "time": time ?? ""]
    }
}

/// One Agent tool call seen in the main chat, and what the chat says about how it ended.
struct AgentRun {
    var desc: String
    var type: String
    var status: String      // running, done, failed, stopped
    var background = false
}

final class TranscriptReader {
    let path: String
    /// Agent chats are all "sidechain" lines, so their reader keeps them.
    let keepSidechain: Bool
    /// tool_use id of each Agent call -> its run.
    private(set) var agents: [String: AgentRun] = [:]
    /// Agent id (the agent-<id>.jsonl name) -> how it ended. Later notices and hand-backs name only this id.
    private(set) var finishedTasks: [String: String] = [:]
    private(set) var items: [ChatItem] = []
    private var offset: UInt64 = 0
    private var leftover = Data()
    /// tool_use id -> (item index, block index), so a tool_result finds its step.
    private var toolAt: [String: (Int, Int)] = [:]
    /// The newest AskUserQuestion or ExitPlanMode that has no result yet.
    private(set) var openAsk: (id: String, name: String, input: [String: Any])?

    init(path: String, keepSidechain: Bool = false) { self.path = path; self.keepSidechain = keepSidechain }

    /// Reads what was added since the last call. Returns true when something changed.
    @discardableResult
    func readNew() -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { reset() }            // the file was replaced
        if size == offset { return false }
        try? h.seek(toOffset: offset)
        var data = leftover
        data.append((try? h.readToEnd()) ?? Data())
        offset = size
        // Keep a half-written last line for the next call.
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        leftover = Data(lines.removeLast())
        var changed = false
        for line in lines where !line.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if add(o) { changed = true }
        }
        return changed
    }

    private func reset() {
        items = []; offset = 0; leftover = Data(); toolAt = [:]; openAsk = nil; agents = [:]; finishedTasks = [:]
    }

    // MARK: - One line

    private func add(_ o: [String: Any]) -> Bool {
        if o["isSidechain"] as? Bool == true && !keepSidechain { return false }
        let type = o["type"] as? String ?? ""
        let uuid = o["uuid"] as? String ?? UUID().uuidString
        let time = o["timestamp"] as? String
        // A notice that arrives while Claude is busy is queued first. Both lines carry it;
        // the queue line only updates the status, the attachment line also shows the note.
        if type == "queue-operation", o["operation"] as? String == "enqueue", let c = o["content"] as? String {
            if c.contains("<task-notification>") { markFinished(c) }
            if let from = handBackFrom(c) { finishedTasks[from] = finishedTasks[from] ?? "done" }
            return false
        }
        if type == "attachment", let att = o["attachment"] as? [String: Any],
           att["type"] as? String == "queued_command",
           let c = att["prompt"] as? String, c.contains("<task-notification>") {
            return notification(c, uuid, time)
        }
        if type == "system" {
            // Newer Claude Code saves slash commands and their output as system lines.
            if o["subtype"] as? String == "local_command", let c = o["content"] as? String {
                return addUserText(c, uuid, time)
            }
            if o["subtype"] as? String == "compact_boundary" {
                return note(uuid, time, "Chat was compacted here. Older messages are summarised.")
            }
            return false
        }
        if o["isCompactSummary"] as? Bool == true { return false }
        // "A background task finished" arrives as a user line, sometimes marked meta.
        if type == "user", let n = notificationText(o), n.contains("<task-notification>") {
            return notification(n, uuid, time)
        }
        // An agent handing back its report: it is done. When the line is only that hand-back, show a
        // short note instead of the whole report. When your own words share the line, keep them.
        if type == "user", let n = notificationText(o), let from = handBackFrom(n) {
            finishedTasks[from] = finishedTasks[from] ?? "done"
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("Another Claude session sent a message") || t.hasPrefix("<agent-message") {
                return note(uuid, time, "An agent handed back its report.")
            }
        }
        if o["isMeta"] as? Bool == true { return false }
        guard let msg = o["message"] as? [String: Any] else { return false }
        if type == "assistant" { return addAssistant(msg, uuid, time) }
        if type == "user" { return addUser(msg, uuid, time) }
        return false
    }

    private func note(_ id: String, _ time: String?, _ text: String) -> Bool {
        let it = ChatItem(id: id, role: "note", time: time)
        it.blocks = [["type": "text", "text": text]]
        items.append(it)
        return true
    }

    private func simple(_ id: String, _ role: String, _ time: String?, _ text: String) -> Bool {
        let it = ChatItem(id: id, role: role, time: time)
        it.blocks = [["type": "text", "text": text]]
        items.append(it)
        return true
    }

    private func addUser(_ msg: [String: Any], _ id: String, _ time: String?) -> Bool {
        if let s = msg["content"] as? String { return addUserText(s, id, time) }
        guard let parts = msg["content"] as? [[String: Any]] else { return false }
        var changed = false
        var texts: [String] = []
        for p in parts {
            switch p["type"] as? String {
            case "tool_result":
                if attachResult(p) { changed = true }
            case "text":
                let t = p["text"] as? String ?? ""
                if t.hasPrefix("[Request interrupted by user") {
                    if note(id + "-stop", time, "You stopped Claude here.") { changed = true }
                } else if !t.hasPrefix("<system-reminder>") {
                    texts.append(t)
                }
            case "image":
                texts.append("_[image]_")
            default: break
            }
        }
        if !texts.isEmpty, addUserText(texts.joined(separator: "\n\n"), id, time) { changed = true }
        return changed
    }

    private func addUserText(_ s: String, _ id: String, _ time: String?) -> Bool {
        if let name = between(s, "<command-name>", "</command-name>") {
            let args = between(s, "<command-args>", "</command-args>") ?? ""
            let n = name.hasPrefix("/") ? name : "/" + name
            return simple(id, "command", time, args.isEmpty ? n : "\(n) \(args)")
        }
        if let out = between(s, "<local-command-stdout>", "</local-command-stdout>") {
            let clean = stripAnsi(out).trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? false : simple(id, "output", time, clean)
        }
        if let cmd = between(s, "<bash-input>", "</bash-input>") {
            return simple(id, "command", time, "! " + cmd)
        }
        if s.contains("<bash-stdout>") || s.contains("<bash-stderr>") {
            let out = [between(s, "<bash-stdout>", "</bash-stdout>"), between(s, "<bash-stderr>", "</bash-stderr>")]
                .compactMap { $0 }.joined(separator: "\n")
            let clean = stripAnsi(out).trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? false : simple(id, "output", time, clean)
        }
        if s.hasPrefix("<local-command-caveat>") { return false }
        // Claude Code can attach reminders to your message. Show your words, not the reminders.
        var text = s
        while let r1 = text.range(of: "<system-reminder>"),
              let r2 = text.range(of: "</system-reminder>", range: r1.upperBound..<text.endIndex) {
            text.removeSubrange(r1.lowerBound..<r2.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        return simple(id, "user", time, text)
    }

    private func addAssistant(_ msg: [String: Any], _ id: String, _ time: String?) -> Bool {
        guard let parts = msg["content"] as? [[String: Any]] else { return false }
        var changed = false
        for p in parts {
            switch p["type"] as? String {
            case "text":
                let t = p["text"] as? String ?? ""
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                current(id, time).blocks.append(["type": "text", "text": t])
                current(id, time).version += 1
                changed = true
            case "tool_use":
                let name = p["name"] as? String ?? "Tool"
                let input = p["input"] as? [String: Any] ?? [:]
                let tid = p["id"] as? String ?? UUID().uuidString
                let it = current(id, time)
                it.blocks.append(["type": "tool", "name": name, "detail": toolDetail(name, input), "id": tid])
                it.version += 1
                toolAt[tid] = (items.count - 1, it.blocks.count - 1)
                if name == "AskUserQuestion" || name == "ExitPlanMode" { openAsk = (tid, name, input) }
                if name == "Agent" || name == "Task" {
                    agents[tid] = AgentRun(desc: input["description"] as? String ?? "Agent",
                                           type: input["subagent_type"] as? String ?? "general-purpose",
                                           status: "running")
                    it.blocks[it.blocks.count - 1]["agent"] = true
                }
                changed = true
            default: break   // thinking stays hidden
            }
        }
        return changed
    }

    /// The assistant bubble to add to. A new one starts after any non-assistant item.
    private func current(_ id: String, _ time: String?) -> ChatItem {
        if let last = items.last, last.role == "assistant" { return last }
        let it = ChatItem(id: id, role: "assistant", time: time)
        items.append(it)
        return it
    }

    private func attachResult(_ p: [String: Any]) -> Bool {
        guard let tid = p["tool_use_id"] as? String else { return false }
        if openAsk?.id == tid { openAsk = nil }
        guard let (i, b) = toolAt[tid], i < items.count, b < items[i].blocks.count else { return false }
        var text = ""
        if let s = p["content"] as? String { text = s }
        else if let arr = p["content"] as? [[String: Any]] {
            text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if var run = agents[tid] {
            if text.contains("Async agent launched") || text.contains("working in the background") {
                run.background = true
            } else {
                run.status = p["is_error"] as? Bool == true ? "failed" : "done"
            }
            agents[tid] = run
        }
        if text.count > 4000 { text = String(text.prefix(4000)) + "\n... (cut, open the tab for the rest)" }
        items[i].blocks[b]["output"] = stripAnsi(text)
        if p["is_error"] as? Bool == true { items[i].blocks[b]["error"] = true }
        items[i].version += 1
        return true
    }

    private func notificationText(_ o: [String: Any]) -> String? {
        guard let msg = o["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        return (msg["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Marks the agent (or background command) as finished and shows a small note.
    /// "<agent-message from=\"ID\">" with "[Subagent hand-back]": the id of the agent that finished.
    private func handBackFrom(_ s: String) -> String? {
        guard s.contains("[Subagent hand-back]"), let id = between(s, "<agent-message from=\"", "\"") else { return nil }
        return id
    }

    private func markFinished(_ s: String) {
        let status = between(s, "<status>", "</status>") ?? ""
        let ended = status == "completed" ? "done" : (status == "failed" ? "failed" : "stopped")
        if let task = between(s, "<task-id>", "</task-id>") { finishedTasks[task] = ended }
        if let tid = between(s, "<tool-use-id>", "</tool-use-id>"), var run = agents[tid] {
            run.status = status == "completed" ? "done" : (status == "failed" ? "failed" : "stopped")
            agents[tid] = run
        }
    }

    private func notification(_ s: String, _ id: String, _ time: String?) -> Bool {
        markFinished(s)
        let status = between(s, "<status>", "</status>") ?? ""
        let summary = between(s, "<summary>", "</summary>") ?? "A background task finished"
        let mark = status == "completed" ? "Finished" : (status.isEmpty ? "Update" : status.capitalized)
        return note(id, time, "\(mark): \(oneLine(summary, 160))")
    }
}

// MARK: - Helpers

func toolDetail(_ name: String, _ input: [String: Any]) -> String {
    let keys: [String]
    switch name {
    case "Bash": keys = ["command"]
    case "Read", "Write", "Edit", "NotebookEdit": keys = ["file_path", "notebook_path"]
    case "Grep", "Glob": keys = ["pattern"]
    case "WebFetch": keys = ["url"]
    case "WebSearch": keys = ["query"]
    case "Agent", "Task": keys = ["description"]
    case "Skill": keys = ["skill"]
    case "AskUserQuestion":
        if let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String { return q }
        keys = []
    default: keys = ["description", "command", "file_path", "query", "url", "name"]
    }
    for k in keys { if let s = input[k] as? String, !s.isEmpty { return oneLine(s, 160) } }
    return ""
}

func oneLine(_ s: String, _ max: Int) -> String {
    let flat = s.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    return flat.count > max ? String(flat.prefix(max)) + "..." : flat
}

func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

func stripAnsi(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
}
