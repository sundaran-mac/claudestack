// Reads ~/.claude/stack/sessions/*.json (written by stack-hook.sh) into sorted rows. Port of Store in ClaudeStack.swift.
"use strict";
const fs = require("fs");
const path = require("path");
const { sessionsDir, stuckAfter, idleAfter, isoDate, mtimeOf, alive, parseJSON } = require("./util");
const { activeAgentCount } = require("./agents");

const displays = {
  needs: { rank: 0, label: "Needs you", color: "#FF9A00" },
  running: { rank: 1, label: "Running", color: "#5B9BE6" },
  stuck: { rank: 2, label: "Maybe stuck", color: "#F4A500" },
  done: { rank: 3, label: "Done", color: "#06C27A" },
  ready: { rank: 4, label: "Ready", color: "#5FA889" },
  idle: { rank: 5, label: "Idle", color: "#8A9BAE" },
};

/// One row of the stack, as the Mac's Row.
function makeRow(s, now, interruptedAt) {
  const r = { s, background: false, agents: 0 };
  // Esc sends no hook event, so the transcript is the only sign of it.
  if (interruptedAt != null && interruptedAt >= (s.updated_at ?? Infinity) &&
      (s.status === "needs_input" || s.status === "running")) {
    r.stopped = true;
    r.since = interruptedAt;
    r.display = now - interruptedAt > idleAfter ? "idle" : "done";
    return r;
  }
  r.stopped = false;
  const since = s.status_since ?? s.updated_at ?? now;
  r.since = since;
  switch (s.status ?? "running") {
    case "needs_input": r.display = "needs"; break;
    case "waiting":
      r.display = s.reason === "Ready" ? "ready" : (now - since > idleAfter ? "idle" : "done");
      break;
    default:
      r.display = now - (s.updated_at ?? now) > stuckAfter ? "stuck" : "running";
  }
  return r;
}

function rowTitle(r) { return r.s.project ?? "Claude"; }
function rowDetail(r) {
  if (r.stopped && r.display === "done") return "Stopped";
  if (r.display === "needs" && r.s.reason) return r.s.reason;
  return displays[r.display].label;
}

/// What the pages need to draw a row.
function rowView(r) {
  const d = displays[r.display];
  return {
    id: r.s.session_id, display: r.display, label: d.label, color: d.color,
    title: rowTitle(r), detail: rowDetail(r), since: r.since, background: r.background, agents: r.agents,
    branch: r.s.branch ?? "", prompt: r.s.prompt ?? "", cwd: r.s.cwd ?? "",
    canType: !!r.s.tmux_pane,
  };
}

class Store {
  constructor() {
    this.rows = [];
    this.last = {};
    this.firstLoad = true;
    this.onAlert = null;
    /// pid -> runs under a "--bg-pty-host" parent. Asked once per process.
    this.bgCache = new Map();
    /// path -> { mtime, tail }
    this.tailCache = new Map();
    try { fs.mkdirSync(sessionsDir, { recursive: true }); } catch { /* read-only home */ }
  }

  reload() {
    const now = Date.now() / 1000;
    let names = [];
    try { names = fs.readdirSync(sessionsDir); } catch { /* none yet */ }
    let out = [];
    const fileOf = {};
    const rm = (f) => { try { fs.rmSync(f, { force: true }); } catch { /* gone */ } };
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const f = path.join(sessionsDir, name);
      let s;
      try { s = parseJSON(fs.readFileSync(f, "utf8")); } catch { continue; }
      if (!s || typeof s.session_id !== "string") continue;
      // The tab was closed or Claude was killed without a SessionEnd event.
      if (Number.isInteger(s.pid) && !alive(s.pid)) { rm(f); continue; }
      if (!Number.isInteger(s.pid) && now - (s.updated_at ?? 0) > 3 * 3600) { rm(f); continue; }
      let interruptedAt = null;
      if (typeof s.transcript_path === "string") {
        const tail = this.transcriptTail(s.transcript_path);
        // The chat moved on to a new session id (/bg, agent view). This one is over.
        if (tail.continued) { rm(f); continue; }
        if (s.status === "needs_input" || s.status === "running") interruptedAt = tail.interruptedAt;
      }
      // A spare the daemon made in advance. Nobody has used it yet.
      const bg = Number.isInteger(s.pid) ? this.isBackground(s.pid) : false;
      if (bg && s.status === "waiting" && s.reason === "Ready" && s.prompt == null) continue;
      const row = makeRow(s, now, interruptedAt);
      row.background = bg;
      if (typeof s.transcript_path === "string") row.agents = activeAgentCount(s.transcript_path, now);
      out.push(row);
      fileOf[s.session_id] = f;
    }
    // One Claude process runs one session at a time (/clear, /resume). Keep the newest.
    const newest = {};
    for (const r of out) if (r.s.pid) newest[r.s.pid] = Math.max(newest[r.s.pid] ?? 0, r.s.started_at ?? 0);
    out = out.filter((r) => {
      if (!r.s.pid || (r.s.started_at ?? 0) >= (newest[r.s.pid] ?? 0)) return true;
      if (fileOf[r.s.session_id]) rm(fileOf[r.s.session_id]);
      return false;
    });
    out.sort((a, b) => displays[a.display].rank !== displays[b.display].rank
      ? displays[a.display].rank - displays[b.display].rank
      : (a.s.started_at ?? 0) - (b.s.started_at ?? 0));
    this.alertOnChanges(out);
    this.rows = out;
    this.now = now;
    return out;
  }

  isBackground(pid) {
    if (this.bgCache.has(pid)) return this.bgCache.get(pid);
    let b = false;
    try {
      // /proc/<pid>/stat: "pid (comm) state ppid ...". The comm can hold spaces, so split after the last ")".
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const ppid = stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1];
      const args = fs.readFileSync(`/proc/${ppid}/cmdline`, "utf8").split("\0").join(" ");
      b = args.includes("--bg-pty-host");
    } catch { /* not readable */ }
    this.bgCache.set(pid, b);
    return b;
  }

  // Reads the end of the transcript.
  // interruptedAt: time of the Esc when the last user line is "[Request interrupted by user...]".
  // continued: a "continued-in" line comes after the last message, so the chat lives on elsewhere.
  transcriptTail(p) {
    const mtime = mtimeOf(p);
    if (mtime == null) return { interruptedAt: null, continued: false };
    const c = this.tailCache.get(p);
    if (c && c.mtime === mtime) return c.tail;
    let result = null, continued = false, seenMessage = false;
    let fd;
    try {
      fd = fs.openSync(p, "r");
      const size = fs.fstatSync(fd).size;
      const from = size > 65536 ? size - 65536 : 0;
      const buf = Buffer.alloc(size - from);
      fs.readSync(fd, buf, 0, buf.length, from);
      const lines = buf.toString("utf8").split("\n").filter((l) => l !== "").reverse();
      for (const line of lines) {
        const o = parseJSON(line);
        if (!o) continue;
        if (o.type === "continued-in" && !seenMessage) continued = true;
        if (o.type === "user" || o.type === "assistant") seenMessage = true;
        if (o.type !== "user" || o.isMeta === true || !o.message || typeof o.message !== "object") continue;
        // The first real user line from the end decides it.
        const items = o.message.content;
        if (Array.isArray(items) &&
            items.some((x) => x && typeof x.text === "string" && x.text.startsWith("[Request interrupted by user"))) {
          const d = isoDate(o.timestamp);
          if (d != null) result = d;
        }
        break;
      }
    } catch { /* unreadable: treat as nothing */ } finally {
      if (fd != null) fs.closeSync(fd);
    }
    const tail = { interruptedAt: result, continued };
    this.tailCache.set(p, { mtime, tail });
    return tail;
  }

  alertOnChanges(rows) {
    const next = {};
    for (const r of rows) {
      const id = r.s.session_id;
      next[id] = r.display;
      const before = this.last[id];
      if (this.firstLoad || before === r.display) continue;
      if (r.display === "needs") {
        this.onAlert && this.onAlert({ kind: "needs", sid: id, title: "Claude needs you", body: `${rowTitle(r)}: ${rowDetail(r)}` });
      } else if (r.display === "done" && before === "running") {
        this.onAlert && this.onAlert({ kind: "done", sid: id });
      }
    }
    this.last = next;
    this.firstLoad = false;
  }
}

module.exports = { Store, rowView, displays, rowTitle };
