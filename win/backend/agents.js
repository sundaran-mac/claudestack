// Subagents of one session: <session>/subagents/agent-<id>.jsonl plus agent-<id>.meta.json. Port of Agents.swift.
// The main chat says when an agent ended. The agent's own file says what it is doing now.
"use strict";
const fs = require("fs");
const { toolDetail, isoDate, mtimeOf, LineTail, parseJSON, stuckAfter } = require("./util");

/// What one agent file says so far. Only the new bytes are read each time.
class AgentScan {
  constructor() { this.tail = null; this.clear(); this.mtime = undefined; }
  clear() {
    this.steps = 0; this.lastTool = ""; this.lastDetail = ""; this.firstTime = null; this.lastTime = null;
    /// tool_use ids of the agents this agent started, so the map can draw who started whom.
    this.spawned = [];
  }
  update(p) {
    if (!this.tail || this.tail.path !== p) this.tail = new LineTail(p);
    const r = this.tail.read();
    if (!r) return;
    if (r.reset) { this.steps = 0; this.firstTime = null; this.spawned = []; }
    for (const line of r.lines) {
      if (!line) continue;
      const o = parseJSON(line);
      if (!o) continue;
      const d = isoDate(o.timestamp);
      if (d != null) {
        if (this.firstTime == null) this.firstTime = d;
        this.lastTime = d;
      }
      const parts = o.type === "assistant" && o.message && Array.isArray(o.message.content) ? o.message.content : null;
      if (!parts) continue;
      // SubagentHandback is the agent's internal "hand the answer back" step.
      for (const p2 of parts) {
        if (!p2 || p2.type !== "tool_use" || p2.name === "SubagentHandback") continue;
        this.steps += 1;
        this.lastTool = typeof p2.name === "string" ? p2.name : "";
        if ((this.lastTool === "Agent" || this.lastTool === "Task") && typeof p2.id === "string") this.spawned.push(p2.id);
        this.lastDetail = toolDetail(this.lastTool, p2.input && typeof p2.input === "object" ? p2.input : {});
      }
    }
  }
}

function subagentDir(transcript) {
  return transcript.slice(0, transcript.length - ".jsonl".length) + "/subagents";
}

class AgentScanner {
  /// `transcript` is the main chat file. Its agents live in a folder with the same name.
  constructor(transcript) {
    this.dir = subagentDir(transcript);
    this.metas = {};
    this.scans = {};
  }

  path(id) { return `${this.dir}/agent-${id}.jsonl`; }

  /// Every agent of the session, running ones first.
  list(main, finished = {}, now = Date.now() / 1000) {
    let names;
    try { names = fs.readdirSync(this.dir); } catch { return []; }
    let out = [];
    for (const name of names) {
      if (!name.startsWith("agent-") || !name.endsWith(".jsonl")) continue;
      const id = name.slice("agent-".length, name.length - ".jsonl".length);
      const file = `${this.dir}/${name}`;
      if (this.metas[id] == null) {
        try {
          const m = parseJSON(fs.readFileSync(`${this.dir}/agent-${id}.meta.json`, "utf8"));
          if (m) this.metas[id] = m;
        } catch { /* no meta yet */ }
      }
      const meta = this.metas[id] || {};
      const scan = this.scans[id] || (this.scans[id] = new AgentScan());
      const mtime = mtimeOf(file);
      if (mtime !== scan.mtime) { scan.mtime = mtime; scan.update(file); }
      const age = now - (mtime ?? 0);

      const toolUse = typeof meta.toolUseId === "string" ? meta.toolUseId : "";
      const run = main[toolUse];
      let status;
      if (run && run.status !== "running") status = run.status;
      // A later notice or a hand-back named this agent by its own id.
      else if (finished[id] != null) status = finished[id];
      else if (run) status = age > stuckAfter ? "stuck" : "running";
      // Started by another agent, so the main chat does not say when it ended.
      else status = age < 120 ? "running" : "done";
      const start = scan.firstTime ?? mtime ?? now;
      const end = status === "running" || status === "stuck" ? now : (scan.lastTime ?? start);
      out.push({
        id,
        toolUse,
        type: typeof meta.agentType === "string" ? meta.agentType : (run ? run.type : "agent"),
        desc: typeof meta.description === "string" ? meta.description : (run ? run.desc : ""),
        depth: Number.isInteger(meta.spawnDepth) ? meta.spawnDepth : 1,
        status,
        tool: scan.lastTool,
        detail: scan.lastDetail,
        steps: scan.steps,
        secs: Math.floor(Math.max(0, end - start)),
        start,
        end,
      });
    }
    // Who started whom: an agent's parent is the agent whose file holds its tool_use id.
    const startedBy = {};
    for (const [id, scan] of Object.entries(this.scans)) for (const t of scan.spawned) startedBy[t] = id;
    out = out.map((a) => ({ ...a, parent: startedBy[a.toolUse] ?? "" }));
    const isLive = (a) => a.status === "running" || a.status === "stuck";
    const live = out.filter(isLive).sort((a, b) => a.start - b.start);
    const done = out.filter((a) => !isLive(a)).sort((a, b) => b.end - a.end);
    return live.concat(done.slice(0, 40));
  }
}

/// Agent files changed in the last 90 s. Cheap enough for the small stack's 0.5 s loop.
function activeAgentCount(transcript, now) {
  const dir = subagentDir(transcript);
  let names;
  try { names = fs.readdirSync(dir); } catch { return 0; }
  let n = 0;
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const m = mtimeOf(`${dir}/${name}`);
    if (m != null && now - m < 90) n += 1;
  }
  return n;
}

module.exports = { AgentScanner, activeAgentCount };
