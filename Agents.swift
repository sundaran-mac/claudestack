// Subagents of one session: <session>/subagents/agent-<id>.jsonl plus agent-<id>.meta.json.
// The main chat says when an agent ended. The agent's own file says what it is doing now.
import Foundation

/// What one agent file says so far. Only the new bytes are read each time.
final class AgentScan {
    private var offset: UInt64 = 0
    private var leftover = Data()
    private(set) var steps = 0
    private(set) var lastTool = ""
    private(set) var lastDetail = ""
    private(set) var firstTime: Double?
    private(set) var lastTime: Double?
    /// tool_use ids of the agents this agent started, so the map can draw who started whom.
    private(set) var spawned: [String] = []
    var mtime: Date?

    func update(_ path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; leftover = Data(); steps = 0; firstTime = nil; spawned = [] }
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        var data = leftover
        data.append((try? h.readToEnd()) ?? Data())
        offset = size
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        leftover = Data(lines.removeLast())
        for line in lines where !line.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let ts = o["timestamp"] as? String, let d = isoDate(ts) {
                if firstTime == nil { firstTime = d }
                lastTime = d
            }
            guard o["type"] as? String == "assistant",
                  let parts = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            // SubagentHandback is the agent's internal "hand the answer back" step.
            for p in parts where p["type"] as? String == "tool_use" && p["name"] as? String != "SubagentHandback" {
                steps += 1
                lastTool = p["name"] as? String ?? ""
                if lastTool == "Agent" || lastTool == "Task", let id = p["id"] as? String { spawned.append(id) }
                lastDetail = toolDetail(lastTool, p["input"] as? [String: Any] ?? [:])
            }
        }
    }
}

private let isoFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func isoDate(_ s: String) -> Double? { isoFull.date(from: s)?.timeIntervalSince1970 }

final class AgentScanner {
    let dir: String
    private var metas: [String: [String: Any]] = [:]   // agent id -> meta.json
    private var scans: [String: AgentScan] = [:]

    /// `transcript` is the main chat file. Its agents live in a folder with the same name.
    init(transcript: String) {
        dir = String(transcript.dropLast(".jsonl".count)) + "/subagents"
    }

    func path(of id: String) -> String { "\(dir)/agent-\(id).jsonl" }

    /// Every agent of the session, running ones first. Runs on the parse queue.
    func list(main: [String: AgentRun], now: Double) -> [[String: Any]] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [[String: Any]] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let file = "\(dir)/\(name)"
            if metas[id] == nil, let d = fm.contents(atPath: "\(dir)/agent-\(id).meta.json"),
               let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                metas[id] = m
            }
            let meta = metas[id] ?? [:]
            let scan = scans[id] ?? AgentScan()
            scans[id] = scan
            let mtime = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            if mtime != scan.mtime { scan.mtime = mtime; scan.update(file) }
            let age = now - (mtime?.timeIntervalSince1970 ?? 0)

            let toolUse = meta["toolUseId"] as? String ?? ""
            let run = main[toolUse]
            var status: String
            if let run, run.status != "running" {
                status = run.status
            } else if run != nil {
                status = age > stuckAfter ? "stuck" : "running"
            } else {
                // Started by another agent, so the main chat does not say when it ended.
                status = age < 120 ? "running" : "done"
            }
            let start = scan.firstTime ?? mtime?.timeIntervalSince1970 ?? now
            let end = status == "running" || status == "stuck" ? now : (scan.lastTime ?? start)
            let item: [String: Any] = [
                "id": id,
                "toolUse": toolUse,
                "type": meta["agentType"] as? String ?? run?.type ?? "agent",
                "desc": meta["description"] as? String ?? run?.desc ?? "",
                "depth": meta["spawnDepth"] as? Int ?? 1,
                "status": status,
                "tool": scan.lastTool,
                "detail": scan.lastDetail,
                "steps": scan.steps,
                "secs": Int(max(0, end - start)),
                "start": start,
                "end": end,
            ]
            out.append(item)
        }
        // Who started whom: an agent's parent is the agent whose file holds its tool_use id.
        var startedBy: [String: String] = [:]
        for (id, scan) in scans { for t in scan.spawned { startedBy[t] = id } }
        out = out.map { a in
            var a = a
            a["parent"] = startedBy[a["toolUse"] as? String ?? ""] ?? ""
            return a
        }
        let live = out.filter { $0["status"] as? String == "running" || $0["status"] as? String == "stuck" }
            .sorted { ($0["start"] as? Double ?? 0) < ($1["start"] as? Double ?? 0) }
        let done = out.filter { !(($0["status"] as? String == "running") || ($0["status"] as? String == "stuck")) }
            .sorted { ($0["end"] as? Double ?? 0) > ($1["end"] as? Double ?? 0) }
        return live + done.prefix(40)
    }
}

/// Agent files changed in the last 90 s. Cheap enough for the small stack's 0.5 s loop.
func activeAgentCount(transcript: String, now: Double) -> Int {
    let dir = String(transcript.dropLast(".jsonl".count)) + "/subagents"
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
    var n = 0
    for name in names where name.hasSuffix(".jsonl") {
        if let d = (try? fm.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate] as? Date,
           now - d.timeIntervalSince1970 < 90 { n += 1 }
    }
    return n
}
