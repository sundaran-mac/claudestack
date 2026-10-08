// The reader: shows the selected session's chat in a web view, and sends prompts and answers to its tab.
import AppKit
import SwiftUI
import WebKit

/// Slash commands that open a menu in the tab. After sending one, the tab is brought to the front.
let interactiveCommands: Set<String> = [
    "/agents", "/config", "/hooks", "/mcp", "/model", "/permissions", "/plugin", "/resume",
    "/rewind", "/theme", "/statusline", "/export", "/login", "/logout", "/status", "/usage", "/memory",
]

let builtinCommands: [(String, String)] = [
    ("/add-dir", "Add another folder Claude can work in"),
    ("/agents", "Manage subagents"),
    ("/bg", "Move this chat to the background"),
    ("/clear", "Start a fresh chat"),
    ("/compact", "Shrink the chat to save context"),
    ("/config", "Open settings"),
    ("/context", "Show how much context is used"),
    ("/copy", "Copy the last answer"),
    ("/cost", "Show cost and time of this chat"),
    ("/doctor", "Check the Claude Code install"),
    ("/export", "Export this chat"),
    ("/help", "Show help"),
    ("/hooks", "Manage hooks"),
    ("/init", "Write a CLAUDE.md for this repo"),
    ("/mcp", "Manage MCP servers"),
    ("/memory", "Edit memory files"),
    ("/model", "Change the model"),
    ("/permissions", "Manage tool permissions"),
    ("/plugin", "Manage plugins"),
    ("/resume", "Open an older chat"),
    ("/review", "Review a pull request"),
    ("/rewind", "Go back to an earlier point"),
    ("/status", "Show status"),
    ("/theme", "Change colours"),
    ("/usage", "Show plan usage"),
]

final class ReaderModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var web: WKWebView?
    let prefs: Prefs
    var onFocusTab: ((Session) -> Void)?
    var onSelect: (() -> Void)?

    @Published private(set) var selectedId: String?
    /// The reader's tab: chats, agents or settings. Agents and chats share the same page.
    @Published var tab = "chats" { didSet { if tab != "settings" { js("CS.mode", tab) } } }
    private var rows: [Row] = []
    private var mainReader: TranscriptReader?
    private var agentReader: TranscriptReader?
    private var scanner: AgentScanner?
    /// The agent whose chat is shown instead of the main chat, if any.
    private var viewAgent: String?
    private var busy = false
    private var limit = 60
    private var lastItemsKey = ""
    private var lastStateJSON = ""
    private var lastAgentsJSON = ""
    private var commandsCwd: String?
    private var ready = false
    private let parseQ = DispatchQueue(label: "parse")
    let voice = TabVoice()

    init(prefs: Prefs) {
        self.prefs = prefs
        super.init()
        voice.onUpdate = { [weak self] state, text, err in
            self?.js("CS.voice", ["state": state, "text": text, "error": err ?? ""])
        }
    }

    var selectedRow: Row? { rows.first { $0.id == selectedId } }

    func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        mainReader = nil; agentReader = nil; scanner = nil; viewAgent = nil
        limit = 60; lastItemsKey = ""; lastStateJSON = ""; lastAgentsJSON = ""; lastAsk = nil
        js("CS.reset", ["sid": id])
        refresh()
        onSelect?()
    }

    /// Called by the store on every reload (0.5 s).
    func update(rows: [Row]) {
        self.rows = rows
        if selectedRow == nil, let first = rows.first {
            select(first.id)
            return
        }
        refresh()
    }

    /// Reads what is new in the main chat, the open agent chat and the agent folder, then updates the page.
    private func refresh() {
        guard ready, let row = selectedRow else { return }
        let s = row.s
        if s.cwd != commandsCwd { commandsCwd = s.cwd; pushCommands(cwd: s.cwd) }
        pushState()
        guard let tp = s.transcript_path, !busy else { return }
        if mainReader?.path != tp {
            mainReader = TranscriptReader(path: tp)
            scanner = AgentScanner(transcript: tp)
            agentReader = nil
        }
        if let a = viewAgent, let p = scanner?.path(of: a) {
            if agentReader?.path != p { agentReader = TranscriptReader(path: p, keepSidechain: true) }
        } else {
            agentReader = nil
        }
        guard let main = mainReader, let sc = scanner else { return }
        let view = agentReader ?? main
        let sid = s.session_id, agentId = viewAgent, limit = self.limit
        busy = true
        parseQ.async {
            main.readNew()
            if view !== main { view.readNew() }
            let all = view.items
            let slice = all.suffix(limit)
            let items: [String: Any] = ["items": slice.map { $0.json }, "hasMore": all.count > slice.count]
            let agents = sc.list(main: main.agents, finished: main.finishedTasks, now: Date().timeIntervalSince1970)
            let ask: [String: Any]? = main.openAsk.map { ["tool": $0.name, "id": $0.id, "input": $0.input] }
            DispatchQueue.main.async {
                self.busy = false
                guard self.selectedId == sid, self.viewAgent == agentId else { return }
                self.lastAsk = ask
                self.pushItems(items, sid: sid)
                self.pushAgents(agents, sid: sid)
                self.pushState()
            }
        }
    }

    // MARK: - Payloads

    private var lastAsk: [String: Any]?

    private func pushItems(_ payload: [String: Any], sid: String) {
        let items = payload["items"] as? [[String: Any]] ?? []
        let key = (viewAgent ?? "main") + items.map { "\($0["id"] ?? "")\($0["v"] ?? "")" }.joined(separator: ",") + "\(payload["hasMore"] ?? "")"
        guard key != lastItemsKey else { return }
        lastItemsKey = key
        var p = payload
        p["sid"] = sid
        js("CS.setItems", p)
    }

    private func pushAgents(_ list: [[String: Any]], sid: String) {
        // Times tick every second; compare without them so the page is not redrawn for nothing.
        let shape = list.map { a in a.filter { $0.key != "secs" && $0.key != "end" } }
        guard let d = try? JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys]),
              let str = String(data: d, encoding: .utf8) else { return }
        let changed = str != lastAgentsJSON
        lastAgentsJSON = str
        if changed || list.contains(where: { $0["status"] as? String == "running" }) {
            js("CS.setAgents", ["sid": sid, "agents": list, "view": viewAgent ?? ""])
        }
    }

    /// Show one agent's chat, or the main chat again when `id` is nil.
    private func openAgent(_ id: String?, label: String) {
        viewAgent = id
        agentReader = nil
        limit = 60
        lastItemsKey = ""
        js("CS.view", ["agent": id ?? "", "label": label])
        refresh()
    }

    private func pushState() {
        guard let row = selectedRow else { return }
        let s = row.s
        let canSend: Bool
        var block = ""
        let term = (s.term ?? "").lowercased()
        if !(term == "ghostty" || term.isEmpty) { canSend = false; block = "This session runs in \(s.term ?? "another app"), not Ghostty. You can read here, but send from that app." }
        else if row.background { canSend = false; block = "This is a background chat with no tab. You can read it here." }
        else if s.tty == nil { canSend = false; block = "The tab for this session is not known yet. Send one message in the tab first." }
        else { canSend = true }

        var pending: [String: Any]? = nil
        if row.display == .needs {
            switch s.reason {
            case "Permission":
                pending = ["kind": "permission", "tool": s.pending_tool ?? "", "detail": s.pending_detail ?? ""]
            case "Plan approval":
                let plan = (lastAsk?["tool"] as? String == "ExitPlanMode") ? ((lastAsk?["input"] as? [String: Any])?["plan"] as? String ?? "") : ""
                pending = ["kind": "plan", "plan": plan]
            case "Question":
                if lastAsk?["tool"] as? String == "AskUserQuestion", let input = lastAsk?["input"] as? [String: Any] {
                    pending = ["kind": "question", "questions": input["questions"] ?? []]
                } else {
                    pending = ["kind": "question", "questions": []]
                }
            default:
                pending = ["kind": "other"]
            }
        }
        let state: [String: Any] = [
            "sid": s.session_id,
            "project": row.title,
            "branch": s.branch ?? "",
            "display": row.display.label,
            "color": row.display.hex,
            "running": row.display == .running,
            // SubagentHandback is an agent's internal last step, not something to show.
            "tool": s.last_tool == "SubagentHandback" ? "" : (s.last_tool ?? ""),
            "detail": s.last_tool == "SubagentHandback" ? "" : (s.last_detail ?? ""),
            "canSend": canSend,
            "block": block,
            "pending": pending as Any,
            "fontSize": prefs.fontSize,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let str = String(data: data, encoding: .utf8), str != lastStateJSON else { return }
        lastStateJSON = str
        web?.evaluateJavaScript("CS.setState(\(str))")
    }

    private func pushCommands(cwd: String?) {
        DispatchQueue.global().async {
            let list = loadCommands(cwd: cwd).map { ["name": $0.0, "desc": $0.1] }
            DispatchQueue.main.async { self.js("CS.setCommands", list) }
        }
    }

    private func js(_ fn: String, _ arg: Any) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("\(fn)(\(str))")
    }

    // MARK: - Messages from the page

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        // Every action names the session it was made for. If the selection moved, drop it.
        let sid = body["sid"] as? String
        let row = selectedRow
        func sameSession() -> Bool { sid != nil && sid == row?.id }

        switch type {
        case "ready":
            ready = true
            lastItemsKey = ""; lastStateJSON = ""; lastAgentsJSON = ""; viewAgent = nil; agentReader = nil
            if tab == "agents" { js("CS.mode", "agents") }
            if let id = selectedId { js("CS.reset", ["sid": id]) }
            commandsCwd = nil
            refresh()
        case "copy":
            if let text = body["text"] as? String {
                let pb = NSPasteboard.general
                pb.clearContents()
                // HTML keeps bold and lists when pasted into Teams or Outlook. Plain text is for the rest.
                if let html = body["html"] as? String, !html.isEmpty {
                    pb.setString("<meta charset=\"utf-8\">" + html, forType: .html)
                }
                pb.setString(text, forType: .string)
            }
        case "open":
            if let s = body["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
        case "more":
            limit += 60
            refresh()
        case "tab":
            if let t = body["tab"] as? String, ["chats", "agents", "settings"].contains(t) { tab = t }
        case "openAgent":
            if sameSession(), let id = body["id"] as? String {
                tab = "chats"
                openAgent(id, label: body["label"] as? String ?? "Agent")
            }
        case "closeAgent":
            openAgent(nil, label: "")
        case "font":
            if let n = body["size"] as? Double { prefs.fontSize = n }
        case "paste":
            if let text = NSPasteboard.general.string(forType: .string) { js("CS.paste", text) }
        case "focusTab":
            if let row { onFocusTab?(row.s) }
        case "voice":
            if body["on"] as? Bool == true {
                // Voice runs in the selected tab, through Claude Code's own voice mode.
                guard sameSession(), let row else {
                    voiceLog("refused: the message was not for the selected session")
                    return js("CS.voice", ["state": "done", "text": "", "error": "You switched sessions. Voice did not start."])
                }
                voice.start(row.s)
            } else {
                voice.stop()
            }
        case "send":
            guard sameSession(), let row, let text = body["text"] as? String else {
                return js("CS.sent", ["ok": false, "error": "You switched sessions. Nothing was sent."])
            }
            Terminals.shared.send(text, to: row.s) { err in
                DispatchQueue.main.async {
                    self.js("CS.sent", ["ok": err == nil, "error": err?.description ?? ""])
                    let cmd = String(text.split(separator: " ").first ?? "")
                    if err == nil, interactiveCommands.contains(cmd), !text.contains(" ") { self.onFocusTab?(row.s) }
                }
            }
        case "keys":
            guard sameSession(), let row, let keys = body["keys"] as? [String] else {
                return js("CS.sent", ["ok": false, "error": "You switched sessions. Nothing was sent."])
            }
            let allowed: Set<String> = ["enter", "escape", "up", "down", "right", "tab"]
            guard keys.allSatisfy(allowed.contains) else { return }
            Terminals.shared.keys(keys.map(ghosttyKeyName), to: row.s, expect: body["expect"] as? String) { err in
                DispatchQueue.main.async { self.js("CS.sent", ["ok": err == nil, "error": err?.description ?? "", "quiet": true]) }
            }
        default: break
        }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page never navigates away. Links open in the browser through the "open" message.
        decisionHandler(a.navigationType == .other && a.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// Our short names to Ghostty's key names.
func ghosttyKeyName(_ k: String) -> String {
    switch k {
    case "up": return "arrowUp"
    case "down": return "arrowDown"
    case "right": return "arrowRight"
    default: return k
    }
}

// MARK: - Slash command list

func loadCommands(cwd: String?) -> [(String, String)] {
    var out = builtinCommands
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var roots: [(String, String)] = [("\(home)/.claude", "")]
    if let cwd { roots.append(("\(cwd)/.claude", "")) }
    if let data = fm.contents(atPath: "\(home)/.claude/plugins/installed_plugins.json"),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let plugins = o["plugins"] as? [String: [[String: Any]]] {
        for (key, list) in plugins {
            if let path = list.first?["installPath"] as? String {
                roots.append((path, String(key.split(separator: "@").first ?? "") + ":"))
            }
        }
    }
    for (root, prefix) in roots {
        for name in (try? fm.contentsOfDirectory(atPath: "\(root)/skills")) ?? [] {
            let file = "\(root)/skills/\(name)/SKILL.md"
            guard fm.fileExists(atPath: file) else { continue }
            let meta = frontmatter(file)
            out.append(("/" + prefix + (meta["name"] ?? name), meta["description"] ?? ""))
        }
        for name in (try? fm.contentsOfDirectory(atPath: "\(root)/commands")) ?? [] where name.hasSuffix(".md") {
            let meta = frontmatter("\(root)/commands/\(name)")
            out.append(("/" + prefix + String(name.dropLast(3)), meta["description"] ?? ""))
        }
    }
    var seen = Set<String>()
    return out.filter { seen.insert($0.0).inserted }.map { ($0.0, oneLine($0.1, 140)) }
}

/// Reads `name:` and `description:` from a markdown file's frontmatter.
func frontmatter(_ path: String) -> [String: String] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [:] }
    defer { try? h.close() }
    let head = String(decoding: (try? h.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
    guard head.hasPrefix("---") else { return [:] }
    var out: [String: String] = [:]
    for line in head.split(separator: "\n").dropFirst() {
        if line.hasPrefix("---") { break }
        for key in ["name", "description"] where line.hasPrefix("\(key):") {
            var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            out[key] = v
        }
    }
    return out
}

// MARK: - Web view

/// The reader's web view. A click that also brings the window forward still reaches the page.
final class ReaderWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func webDir() -> URL {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("web"), FileManager.default.fileExists(atPath: r.path) { return r }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stack/web")
}

func makeWebView(model: ReaderModel) -> ReaderWebView {
    let cfg = WKWebViewConfiguration()
    let weakHandler = WeakHandler(model)
    cfg.userContentController.add(weakHandler, name: "cs")
    let w = ReaderWebView(frame: .zero, configuration: cfg)
    w.navigationDelegate = model
    w.setValue(false, forKey: "drawsBackground")
    w.allowsMagnification = false
    model.web = w
    let dir = webDir()
    w.loadFileURL(dir.appendingPathComponent("reader.html"), allowingReadAccessTo: dir)
    return w
}

/// WKUserContentController keeps its handler strongly. This breaks the loop.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

struct ReaderPane: NSViewRepresentable {
    let web: ReaderWebView
    func makeNSView(context: Context) -> ReaderWebView { web }
    func updateNSView(_ v: ReaderWebView, context: Context) {}
}
