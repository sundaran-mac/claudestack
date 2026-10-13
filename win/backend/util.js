// Shared helpers and paths. Ported from the helpers in Transcript.swift and ClaudeStack.swift.
"use strict";
const os = require("os");
const path = require("path");
const fs = require("fs");

const home = process.env.CS_HOME || os.homedir();
const stackDir = path.join(home, ".claude", "stack");
const sessionsDir = path.join(stackDir, "sessions");
const daysDir = path.join(stackDir, "days");

const stuckAfter = 600; // running with no event for 10 min
const idleAfter = 600;  // done for 10 min

function oneLine(s, max) {
  const flat = String(s).split(/[\n\r\u2028\u2029\u0085\v\f]+/).filter((x) => x !== "").join(" ");
  const chars = Array.from(flat);
  return chars.length > max ? chars.slice(0, max).join("") + "..." : flat;
}

function between(s, a, b) {
  const i = s.indexOf(a);
  if (i < 0) return null;
  const j = s.indexOf(b, i + a.length);
  if (j < 0) return null;
  return s.slice(i + a.length, j);
}

function stripAnsi(s) {
  return String(s).replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "");
}

function toolDetail(name, input) {
  input = input || {};
  let keys;
  switch (name) {
    case "Bash": keys = ["command"]; break;
    case "Read": case "Write": case "Edit": case "NotebookEdit": keys = ["file_path", "notebook_path"]; break;
    case "Grep": case "Glob": keys = ["pattern"]; break;
    case "WebFetch": keys = ["url"]; break;
    case "WebSearch": keys = ["query"]; break;
    case "Agent": case "Task": keys = ["description"]; break;
    case "Skill": keys = ["skill"]; break;
    case "AskUserQuestion": {
      const q = Array.isArray(input.questions) && input.questions[0] && input.questions[0].question;
      if (typeof q === "string") return q;
      keys = [];
      break;
    }
    default: keys = ["description", "command", "file_path", "query", "url", "name"];
  }
  for (const k of keys) {
    const s = input[k];
    if (typeof s === "string" && s !== "") return oneLine(s, 160);
  }
  return "";
}

/// ISO 8601 with fractional seconds, to seconds since 1970. Null when it does not parse.
function isoDate(s) {
  if (typeof s !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+(Z|[+-]\d\d:?\d\d)$/.test(s)) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t / 1000;
}

function mtimeOf(p) {
  try { return fs.statSync(p).mtimeMs / 1000; } catch { return null; }
}

/// A pid is alive unless the system says there is no such process (as kill(pid, 0) with ESRCH).
function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code !== "ESRCH"; }
}

/// Reads only what was added to a file since the last call, as whole lines.
class LineTail {
  constructor(p) { this.path = p; this.offset = 0; this.leftover = Buffer.alloc(0); }
  /// Returns { lines, reset }. `reset` is true when the file shrank (it was replaced).
  read() {
    let fd;
    try { fd = fs.openSync(this.path, "r"); } catch { return null; }
    try {
      const size = fs.fstatSync(fd).size;
      let reset = false;
      if (size < this.offset) { this.offset = 0; this.leftover = Buffer.alloc(0); reset = true; }
      if (size === this.offset) return { lines: [], reset };
      const buf = Buffer.alloc(size - this.offset);
      let got = 0;
      while (got < buf.length) {
        const n = fs.readSync(fd, buf, got, buf.length - got, this.offset + got);
        if (n <= 0) break;
        got += n;
      }
      this.offset += got;
      const data = Buffer.concat([this.leftover, buf.subarray(0, got)]);
      const lines = [];
      let start = 0;
      for (let i = 0; i < data.length; i++) {
        if (data[i] === 0x0a) { lines.push(data.subarray(start, i).toString("utf8")); start = i + 1; }
      }
      // Keep a half-written last line for the next call.
      this.leftover = Buffer.from(data.subarray(start));
      return { lines, reset };
    } finally {
      fs.closeSync(fd);
    }
  }
}

function parseJSON(s) {
  try { const o = JSON.parse(s); return o && typeof o === "object" && !Array.isArray(o) ? o : null; } catch { return null; }
}

function capitalized(s) {
  return s.replace(/\S+/g, (w) => w[0].toUpperCase() + w.slice(1).toLowerCase());
}

function ago(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
}

module.exports = {
  home, stackDir, sessionsDir, daysDir, stuckAfter, idleAfter,
  oneLine, between, stripAnsi, toolDetail, isoDate, mtimeOf, alive, LineTail, parseJSON, capitalized, ago,
};
