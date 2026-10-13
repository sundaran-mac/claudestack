// Reads a Claude Code transcript (.jsonl) into chat items for the reader. Port of Transcript.swift.
// Only the new bytes are read on each call, because a transcript can be many MB.
"use strict";
const crypto = require("crypto");
const { oneLine, between, stripAnsi, toolDetail, LineTail, parseJSON, capitalized } = require("./util");

/// One bubble in the reader. `blocks` holds text and tool steps in order.
class ChatItem {
  constructor(id, role, time) { this.id = id; this.role = role; this.time = time; this.blocks = []; this.version = 0; }
  get json() { return { id: this.id, role: this.role, blocks: this.blocks, v: this.version, time: this.time ?? "" }; }
}

class TranscriptReader {
  /// Agent chats are all "sidechain" lines, so their reader keeps them.
  constructor(path, keepSidechain = false) {
    this.path = path;
    this.keepSidechain = keepSidechain;
    this.tail = new LineTail(path);
    this.reset();
  }

  reset() {
    this.items = [];
    /// tool_use id -> { item, block }, so a tool_result finds its step.
    this.toolAt = new Map();
    /// The newest AskUserQuestion or ExitPlanMode that has no result yet.
    this.openAsk = null;
    /// tool_use id of each Agent call -> { desc, type, status, background }.
    this.agents = {};
    /// Agent id (the agent-<id>.jsonl name) -> how it ended. Later notices and hand-backs name only this id.
    this.finishedTasks = {};
  }

  /// Reads what was added since the last call. Returns true when something changed.
  readNew() {
    const r = this.tail.read();
    if (!r) return false;
    if (r.reset) this.reset();
    let changed = false;
    for (const line of r.lines) {
      if (!line) continue;
      const o = parseJSON(line);
      if (!o) continue;
      if (this.add(o)) changed = true;
    }
    return changed;
  }

  // ---------- One line ----------

  add(o) {
    if (o.isSidechain === true && !this.keepSidechain) return false;
    const type = typeof o.type === "string" ? o.type : "";
    const uuid = typeof o.uuid === "string" ? o.uuid : crypto.randomUUID();
    const time = typeof o.timestamp === "string" ? o.timestamp : null;
    // A notice that arrives while Claude is busy is queued first. Both lines carry it;
    // the queue line only updates the status, the attachment line also shows the note.
    if (type === "queue-operation" && o.operation === "enqueue" && typeof o.content === "string") {
      const c = o.content;
      if (c.includes("<task-notification>")) this.markFinished(c);
      const from = handBackFrom(c);
      if (from) this.finishedTasks[from] = this.finishedTasks[from] ?? "done";
      return false;
    }
    const att = o.attachment;
    if (type === "attachment" && att && typeof att === "object" && att.type === "queued_command" &&
        typeof att.prompt === "string" && att.prompt.includes("<task-notification>")) {
      return this.notification(att.prompt, uuid, time);
    }
    if (type === "system") {
      // Newer Claude Code saves slash commands and their output as system lines.
      if (o.subtype === "local_command" && typeof o.content === "string") return this.addUserText(o.content, uuid, time);
      if (o.subtype === "compact_boundary") return this.note(uuid, time, "Chat was compacted here. Older messages are summarised.");
      return false;
    }
    if (o.isCompactSummary === true) return false;
    // "A background task finished" arrives as a user line, sometimes marked meta.
    if (type === "user") {
      const n = notificationText(o);
      if (n != null && n.includes("<task-notification>")) return this.notification(n, uuid, time);
    }
    // An agent handing back its report: it is done. When the line is only that hand-back, show a
    // short note instead of the whole report. When your own words share the line, keep them.
    if (type === "user") {
      const n = notificationText(o);
      const from = n != null ? handBackFrom(n) : null;
      if (from) {
        this.finishedTasks[from] = this.finishedTasks[from] ?? "done";
        const t = n.trim();
        if (t.startsWith("Another Claude session sent a message") || t.startsWith("<agent-message")) {
          return this.note(uuid, time, "An agent handed back its report.");
        }
      }
    }
    if (o.isMeta === true) return false;
    const msg = o.message;
    if (!msg || typeof msg !== "object") return false;
    if (type === "assistant") return this.addAssistant(msg, uuid, time);
    if (type === "user") return this.addUser(msg, uuid, time);
    return false;
  }

  note(id, time, text) {
    const it = new ChatItem(id, "note", time);
    it.blocks = [{ type: "text", text }];
    this.items.push(it);
    return true;
  }

  simple(id, role, time, text) {
    const it = new ChatItem(id, role, time);
    it.blocks = [{ type: "text", text }];
    this.items.push(it);
    return true;
  }

  addUser(msg, id, time) {
    if (typeof msg.content === "string") return this.addUserText(msg.content, id, time);
    if (!Array.isArray(msg.content)) return false;
    let changed = false;
    const texts = [];
    for (const p of msg.content) {
      if (!p || typeof p !== "object") continue;
      switch (p.type) {
        case "tool_result":
          if (this.attachResult(p)) changed = true;
          break;
        case "text": {
          const t = typeof p.text === "string" ? p.text : "";
          if (t.startsWith("[Request interrupted by user")) {
            if (this.note(id + "-stop", time, "You stopped Claude here.")) changed = true;
          } else if (!t.startsWith("<system-reminder>")) {
            texts.push(t);
          }
          break;
        }
        case "image":
          texts.push("_[image]_");
          break;
        default: break;
      }
    }
    if (texts.length && this.addUserText(texts.join("\n\n"), id, time)) changed = true;
    return changed;
  }

  addUserText(s, id, time) {
    const name = between(s, "<command-name>", "</command-name>");
    if (name != null) {
      const args = between(s, "<command-args>", "</command-args>") ?? "";
      const n = name.startsWith("/") ? name : "/" + name;
      return this.simple(id, "command", time, args === "" ? n : `${n} ${args}`);
    }
    const out = between(s, "<local-command-stdout>", "</local-command-stdout>");
    if (out != null) {
      const clean = stripAnsi(out).trim();
      return clean === "" ? false : this.simple(id, "output", time, clean);
    }
    const cmd = between(s, "<bash-input>", "</bash-input>");
    if (cmd != null) return this.simple(id, "command", time, "! " + cmd);
    if (s.includes("<bash-stdout>") || s.includes("<bash-stderr>")) {
      const o = [between(s, "<bash-stdout>", "</bash-stdout>"), between(s, "<bash-stderr>", "</bash-stderr>")]
        .filter((x) => x != null).join("\n");
      const clean = stripAnsi(o).trim();
      return clean === "" ? false : this.simple(id, "output", time, clean);
    }
    if (s.startsWith("<local-command-caveat>")) return false;
    // Claude Code can attach reminders to your message. Show your words, not the reminders.
    let text = s;
    for (;;) {
      const a = text.indexOf("<system-reminder>");
      if (a < 0) break;
      const b = text.indexOf("</system-reminder>", a + "<system-reminder>".length);
      if (b < 0) break;
      text = text.slice(0, a) + text.slice(b + "</system-reminder>".length);
    }
    text = text.trim();
    if (text === "") return false;
    return this.simple(id, "user", time, text);
  }

  addAssistant(msg, id, time) {
    if (!Array.isArray(msg.content)) return false;
    let changed = false;
    for (const p of msg.content) {
      if (!p || typeof p !== "object") continue;
      if (p.type === "text") {
        const t = typeof p.text === "string" ? p.text : "";
        if (t.trim() === "") continue;
        const it = this.current(id, time);
        it.blocks.push({ type: "text", text: t });
        it.version += 1;
        changed = true;
      } else if (p.type === "tool_use") {
        const name = typeof p.name === "string" ? p.name : "Tool";
        const input = p.input && typeof p.input === "object" ? p.input : {};
        const tid = typeof p.id === "string" ? p.id : crypto.randomUUID();
        const it = this.current(id, time);
        it.blocks.push({ type: "tool", name, detail: toolDetail(name, input), id: tid });
        it.version += 1;
        this.toolAt.set(tid, { item: this.items.length - 1, block: it.blocks.length - 1 });
        if (name === "AskUserQuestion" || name === "ExitPlanMode") this.openAsk = { id: tid, name, input };
        if (name === "Agent" || name === "Task") {
          this.agents[tid] = {
            desc: typeof input.description === "string" ? input.description : "Agent",
            type: typeof input.subagent_type === "string" ? input.subagent_type : "general-purpose",
            status: "running",
            background: false,
          };
          it.blocks[it.blocks.length - 1].agent = true;
        }
        changed = true;
      }
      // thinking stays hidden
    }
    return changed;
  }

  /// The assistant bubble to add to. A new one starts after any non-assistant item.
  current(id, time) {
    const last = this.items[this.items.length - 1];
    if (last && last.role === "assistant") return last;
    const it = new ChatItem(id, "assistant", time);
    this.items.push(it);
    return it;
  }

  attachResult(p) {
    const tid = p.tool_use_id;
    if (typeof tid !== "string") return false;
    if (this.openAsk && this.openAsk.id === tid) this.openAsk = null;
    const at = this.toolAt.get(tid);
    if (!at || at.item >= this.items.length || at.block >= this.items[at.item].blocks.length) return false;
    let text = "";
    if (typeof p.content === "string") text = p.content;
    else if (Array.isArray(p.content)) {
      text = p.content.filter((x) => x && typeof x.text === "string").map((x) => x.text).join("\n");
    }
    const run = this.agents[tid];
    if (run) {
      if (text.includes("Async agent launched") || text.includes("working in the background")) run.background = true;
      else run.status = p.is_error === true ? "failed" : "done";
    }
    const chars = Array.from(text);
    if (chars.length > 4000) text = chars.slice(0, 4000).join("") + "\n... (cut, open the tab for the rest)";
    const item = this.items[at.item];
    item.blocks[at.block].output = stripAnsi(text);
    if (p.is_error === true) item.blocks[at.block].error = true;
    item.version += 1;
    return true;
  }

  /// Marks the agent (or background command) as finished.
  markFinished(s) {
    const status = between(s, "<status>", "</status>") ?? "";
    const ended = status === "completed" ? "done" : (status === "failed" ? "failed" : "stopped");
    const task = between(s, "<task-id>", "</task-id>");
    if (task != null) this.finishedTasks[task] = ended;
    const tid = between(s, "<tool-use-id>", "</tool-use-id>");
    if (tid != null && this.agents[tid]) this.agents[tid].status = ended;
  }

  notification(s, id, time) {
    this.markFinished(s);
    const status = between(s, "<status>", "</status>") ?? "";
    const summary = between(s, "<summary>", "</summary>") ?? "A background task finished";
    const mark = status === "completed" ? "Finished" : (status === "" ? "Update" : capitalized(status));
    return this.note(id, time, `${mark}: ${oneLine(summary, 160)}`);
  }
}

function notificationText(o) {
  const msg = o.message;
  if (!msg || typeof msg !== "object") return null;
  if (typeof msg.content === "string") return msg.content;
  if (!Array.isArray(msg.content)) return null;
  return msg.content.filter((x) => x && typeof x.text === "string").map((x) => x.text).join("\n");
}

/// "<agent-message from=\"ID\">" with "[Subagent hand-back]": the id of the agent that finished.
function handBackFrom(s) {
  if (!s.includes("[Subagent hand-back]")) return null;
  return between(s, '<agent-message from="', '"');
}

module.exports = { TranscriptReader, ChatItem };
