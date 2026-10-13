// The reader's model: which session is selected, its chat, its agents, and the actions sent from the page.
// Port of ReaderModel in Reader.swift. The Windows app draws the page; this side feeds it through `js`.
"use strict";
const { TranscriptReader } = require("./transcript");
const { AgentScanner } = require("./agents");
const { loadCommands, interactiveCommands } = require("./commands");
const { rowView } = require("./store");
const { TabVoice, voiceLog } = require("./voice");
const tmux = require("./tmux");

class ReaderModel {
  /// `emit` sends a message to the Windows app.
  constructor(emit) {
    this.emit = emit;
    this.selectedId = null;
    /// The reader's tab: chats, agents or settings. Agents and chats share the same page.
    this.tab = "chats";
    this.rows = [];
    this.fontSize = 15;
    this.ready = false;
    this.mainReader = null; this.agentReader = null; this.scanner = null;
    /// The agent whose chat is shown instead of the main chat, if any.
    this.viewAgent = null;
    this.limit = 60;
    this.lastItemsKey = ""; this.lastStateJSON = ""; this.lastAgentsJSON = "";
    this.commandsCwd = undefined;
    this.lastAsk = null;
    this.voice = new TabVoice();
    this.voice.onUpdate = (state, text, error) => this.js("CS.voice", { state, text, error });
  }

  js(fn, arg) { if (this.ready) this.emit({ t: "js", fn, arg }); }

  setTab(t) {
    this.tab = t;
    if (t !== "settings") this.js("CS.mode", t);
    this.emit({ t: "tab", tab: t });
  }

  get selectedRow() { return this.rows.find((r) => r.s.session_id === this.selectedId) || null; }

  select(id) {
    if (id === this.selectedId) return;
    this.selectedId = id;
    this.mainReader = null; this.agentReader = null; this.scanner = null; this.viewAgent = null;
    this.limit = 60; this.lastItemsKey = ""; this.lastStateJSON = ""; this.lastAgentsJSON = ""; this.lastAsk = null;
    this.js("CS.reset", { sid: id });
    this.emit({ t: "selected", id });
    this.refresh();
  }

  /// Called by the store on every reload (0.5 s).
  update(rows) {
    this.rows = rows;
    if (!this.selectedRow && rows.length) return this.select(rows[0].s.session_id);
    this.refresh();
  }

  /// Reads what is new in the main chat, the open agent chat and the agent folder, then updates the page.
  refresh() {
    const row = this.selectedRow;
    if (!this.ready || !row) return;
    const s = row.s;
    if (s.cwd !== this.commandsCwd) { this.commandsCwd = s.cwd; this.js("CS.setCommands", loadCommands(s.cwd)); }
    this.pushState();
    const tp = s.transcript_path;
    if (typeof tp !== "string") return;
    if (!this.mainReader || this.mainReader.path !== tp) {
      this.mainReader = new TranscriptReader(tp);
      this.scanner = new AgentScanner(tp);
      this.agentReader = null;
    }
    if (this.viewAgent) {
      const p = this.scanner.path(this.viewAgent);
      if (!this.agentReader || this.agentReader.path !== p) this.agentReader = new TranscriptReader(p, true);
    } else {
      this.agentReader = null;
    }
    const main = this.mainReader;
    const view = this.agentReader || main;
    main.readNew();
    if (view !== main) view.readNew();
    const all = view.items;
    const slice = all.slice(Math.max(0, all.length - this.limit));
    const items = { items: slice.map((i) => i.json), hasMore: all.length > slice.length };
    const agents = this.scanner.list(main.agents, main.finishedTasks, Date.now() / 1000);
    this.lastAsk = main.openAsk ? { tool: main.openAsk.name, id: main.openAsk.id, input: main.openAsk.input } : null;
    this.pushItems(items, s.session_id);
    this.pushAgents(agents, s.session_id);
    this.pushState();
  }

  // ---------- Payloads ----------

  pushItems(payload, sid) {
    const key = (this.viewAgent ?? "main") + payload.items.map((i) => `${i.id}${i.v}`).join(",") + String(payload.hasMore);
    if (key === this.lastItemsKey) return;
    this.lastItemsKey = key;
    this.js("CS.setItems", { ...payload, sid });
  }

  pushAgents(list, sid) {
    // Times tick every second; compare without them so the page is not redrawn for nothing.
    const shape = JSON.stringify(list.map((a) => Object.fromEntries(Object.entries(a).filter(([k]) => k !== "secs" && k !== "end"))));
    const changed = shape !== this.lastAgentsJSON;
    this.lastAgentsJSON = shape;
    if (changed || list.some((a) => a.status === "running")) {
      this.js("CS.setAgents", { sid, agents: list, view: this.viewAgent ?? "" });
    }
  }

  /// Show one agent's chat, or the main chat again when `id` is null.
  openAgent(id, label) {
    this.viewAgent = id;
    this.agentReader = null;
    this.limit = 60;
    this.lastItemsKey = "";
    this.js("CS.view", { agent: id ?? "", label });
    this.refresh();
  }

  pushState() {
    const row = this.selectedRow;
    if (!row) return;
    const s = row.s;
    let canSend = false, block = "";
    if (row.background) block = "This is a background chat with no tab. You can read it here.";
    else if (!s.tmux_pane) block = "This Claude was started with plain claude. You can read here; to send from here, start Claude with cs.";
    else if (!s.tty) block = "The tab for this session is not known yet. Send one message in the tab first.";
    else canSend = true;

    let pending = null;
    if (row.display === "needs") {
      const ask = this.lastAsk;
      switch (s.reason) {
        case "Permission":
          pending = { kind: "permission", tool: s.pending_tool ?? "", detail: s.pending_detail ?? "" };
          break;
        case "Plan approval":
          pending = { kind: "plan", plan: ask && ask.tool === "ExitPlanMode" && typeof ask.input.plan === "string" ? ask.input.plan : "" };
          break;
        case "Question":
          pending = { kind: "question", questions: ask && ask.tool === "AskUserQuestion" ? (ask.input.questions ?? []) : [] };
          break;
        default:
          pending = { kind: "other" };
      }
    }
    const v = rowView(row);
    const handback = s.last_tool === "SubagentHandback";
    const state = {
      sid: s.session_id,
      project: v.title,
      branch: s.branch ?? "",
      display: v.label,
      color: v.color,
      running: row.display === "running",
      // SubagentHandback is an agent's internal last step, not something to show.
      tool: handback ? "" : (s.last_tool ?? ""),
      detail: handback ? "" : (s.last_detail ?? ""),
      canSend,
      block,
      pending,
      fontSize: this.fontSize,
    };
    const str = JSON.stringify(state);
    if (str === this.lastStateJSON) return;
    this.lastStateJSON = str;
    this.js("CS.setState", state);
  }

  // ---------- Messages from the page ----------

  async onPage(body) {
    if (!body || typeof body.type !== "string") return;
    // Every action names the session it was made for. If the selection moved, drop it.
    const sid = body.sid;
    const row = this.selectedRow;
    const sameSession = () => sid != null && row && sid === row.s.session_id;

    switch (body.type) {
      case "ready":
        this.ready = true;
        this.lastItemsKey = ""; this.lastStateJSON = ""; this.lastAgentsJSON = ""; this.viewAgent = null; this.agentReader = null;
        if (this.tab === "agents") this.js("CS.mode", "agents");
        if (this.selectedId) this.js("CS.reset", { sid: this.selectedId });
        this.commandsCwd = undefined;
        this.refresh();
        break;
      case "more":
        this.limit += 60;
        this.refresh();
        break;
      case "tab":
        if (["chats", "agents", "settings"].includes(body.tab)) this.setTab(body.tab);
        break;
      case "openAgent":
        if (sameSession() && typeof body.id === "string") {
          this.setTab("chats");
          this.openAgent(body.id, typeof body.label === "string" ? body.label : "Agent");
        }
        break;
      case "closeAgent":
        this.openAgent(null, "");
        break;
      case "focusTab":
        if (row) this.focus(row.s);
        break;
      case "voice":
        if (body.on === true) {
          // Voice runs in the selected tab, through Claude Code's own voice mode.
          if (!sameSession()) {
            voiceLog("refused: the message was not for the selected session");
            return this.js("CS.voice", { state: "done", text: "", error: "You switched sessions. Voice did not start." });
          }
          this.voice.start(row.s);
        } else {
          this.voice.stop();
        }
        break;
      case "send": {
        if (!sameSession() || typeof body.text !== "string") {
          return this.js("CS.sent", { ok: false, error: "You switched sessions. Nothing was sent." });
        }
        const text = body.text;
        const err = await tmux.send(text, row.s);
        this.js("CS.sent", { ok: !err, error: err || "" });
        const cmd = text.split(" ")[0];
        if (!err && interactiveCommands.has(cmd) && !text.includes(" ")) this.focus(row.s);
        break;
      }
      case "keys": {
        if (!sameSession() || !Array.isArray(body.keys)) {
          return this.js("CS.sent", { ok: false, error: "You switched sessions. Nothing was sent." });
        }
        const allowed = new Set(["enter", "escape", "up", "down", "tab"]);
        if (!body.keys.every((k) => allowed.has(k))) return;
        const err = await tmux.keys(body.keys, row.s);
        this.js("CS.sent", { ok: !err, error: err || "", quiet: true });
        break;
      }
      default: break;
    }
  }

  /// Brings the session's tab to the front. tmux selects the pane; the Windows app selects the tab.
  async focus(s) {
    const name = await tmux.reveal(s).catch(() => null);
    this.emit({ t: "focus", tag: name ? `[${name}]` : "", term: s.term ?? "", sid: s.session_id });
  }
}

module.exports = { ReaderModel };
