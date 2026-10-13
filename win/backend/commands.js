// The slash command list: built-in commands, your skills and commands, the repo's, and plugin skills.
// Port of the slash command part of Reader.swift.
"use strict";
const fs = require("fs");
const path = require("path");
const { home, oneLine } = require("./util");

/// Slash commands that open a menu in the tab. After sending one, the tab is brought to the front.
const interactiveCommands = new Set([
  "/agents", "/config", "/hooks", "/mcp", "/model", "/permissions", "/plugin", "/resume",
  "/rewind", "/theme", "/statusline", "/export", "/login", "/logout", "/status", "/usage", "/memory",
]);

const builtinCommands = [
  ["/add-dir", "Add another folder Claude can work in"],
  ["/agents", "Manage subagents"],
  ["/bg", "Move this chat to the background"],
  ["/clear", "Start a fresh chat"],
  ["/compact", "Shrink the chat to save context"],
  ["/config", "Open settings"],
  ["/context", "Show how much context is used"],
  ["/copy", "Copy the last answer"],
  ["/cost", "Show cost and time of this chat"],
  ["/doctor", "Check the Claude Code install"],
  ["/export", "Export this chat"],
  ["/help", "Show help"],
  ["/hooks", "Manage hooks"],
  ["/init", "Write a CLAUDE.md for this repo"],
  ["/mcp", "Manage MCP servers"],
  ["/memory", "Edit memory files"],
  ["/model", "Change the model"],
  ["/permissions", "Manage tool permissions"],
  ["/plugin", "Manage plugins"],
  ["/resume", "Open an older chat"],
  ["/review", "Review a pull request"],
  ["/rewind", "Go back to an earlier point"],
  ["/status", "Show status"],
  ["/theme", "Change colours"],
  ["/usage", "Show plan usage"],
];

/// Reads `name:` and `description:` from a markdown file's frontmatter.
function frontmatter(p) {
  let head;
  try {
    const fd = fs.openSync(p, "r");
    const buf = Buffer.alloc(4096);
    const n = fs.readSync(fd, buf, 0, 4096, 0);
    fs.closeSync(fd);
    head = buf.subarray(0, n).toString("utf8");
  } catch { return {}; }
  if (!head.startsWith("---")) return {};
  const out = {};
  for (const line of head.split("\n").filter((l) => l !== "").slice(1)) {
    if (line.startsWith("---")) break;
    for (const key of ["name", "description"]) {
      if (!line.startsWith(key + ":")) continue;
      let v = line.slice(key.length + 1).replace(/^[ \t]+|[ \t]+$/g, "");
      if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) v = v.slice(1, -1);
      out[key] = v;
    }
  }
  return out;
}

function list(dir) { try { return fs.readdirSync(dir); } catch { return []; } }

function loadCommands(cwd) {
  const out = builtinCommands.slice();
  const roots = [[path.join(home, ".claude"), ""]];
  if (cwd) roots.push([path.join(cwd, ".claude"), ""]);
  try {
    const o = JSON.parse(fs.readFileSync(path.join(home, ".claude/plugins/installed_plugins.json"), "utf8"));
    for (const [key, entries] of Object.entries((o && o.plugins) || {})) {
      const p = Array.isArray(entries) && entries[0] && entries[0].installPath;
      if (typeof p === "string") roots.push([p, key.split("@")[0] + ":"]);
    }
  } catch { /* no plugins */ }
  for (const [root, prefix] of roots) {
    for (const name of list(path.join(root, "skills"))) {
      const file = path.join(root, "skills", name, "SKILL.md");
      if (!fs.existsSync(file)) continue;
      const meta = frontmatter(file);
      out.push(["/" + prefix + (meta.name ?? name), meta.description ?? ""]);
    }
    for (const name of list(path.join(root, "commands"))) {
      if (!name.endsWith(".md")) continue;
      const meta = frontmatter(path.join(root, "commands", name));
      out.push(["/" + prefix + name.slice(0, -3), meta.description ?? ""]);
    }
  }
  const seen = new Set();
  return out.filter(([n]) => !seen.has(n) && seen.add(n)).map(([n, d]) => ({ name: n, desc: oneLine(d, 140) }));
}

module.exports = { loadCommands, interactiveCommands };
