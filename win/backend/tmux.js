// Talks to tmux: paste text into a session's pane, press keys in it, read its screen. Windows port of Ghostty.swift.
// The worst bug here is text going to the wrong tab, so every send checks the target first:
// the pane named by the hook must still exist and still hold the session's own tty.
"use strict";
const { execFile } = require("child_process");
const { alive } = require("./util");

function tmux(s, args, input) {
  const full = s.tmux_socket ? ["-S", s.tmux_socket, ...args] : args;
  return new Promise((resolve) => {
    const p = execFile("tmux", full, { timeout: 5000 }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: String(stdout || "").replace(/\n$/, ""), err: String(stderr || (err && err.message) || "").trim() });
    });
    if (input != null) { p.stdin.on("error", () => {}); p.stdin.end(input); }
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const errors = {
  notTmux: "This Claude was started with plain claude, so the box cannot type into it. Start Claude with cs to send from here.",
  gone: "This Claude has stopped. Nothing was sent.",
  notFound: "Could not prove this is the right tab. Nothing was sent.",
};

/// One job at a time, as the Mac's serial queue: keys from two clicks never interleave.
let chain = Promise.resolve();
function serial(job) {
  const run = chain.then(job, job);
  chain = run.catch(() => {});
  return run;
}

/// Checks that the session is a live tmux pane that still holds its tty. Resolves to null when it is fine.
async function check(s) {
  if (!s.tmux_pane) return errors.notTmux;
  if (!s.pid || !alive(s.pid)) return errors.gone;
  const r = await tmux(s, ["display-message", "-p", "-t", s.tmux_pane, "#{pane_tty} #{pane_dead}"]);
  if (!r.ok) return errors.notFound;
  const [tty, dead] = r.out.split(" ");
  if (dead === "1" || !s.tty || tty !== "/dev/" + s.tty) return errors.notFound;
  return null;
}

/// Pastes `text` into the session's pane (as one bracketed paste), then presses Enter.
function send(text, s) {
  return serial(async () => {
    const e = await check(s);
    if (e) return e;
    const buf = "claudestack-" + process.pid;
    let r = await tmux(s, ["load-buffer", "-b", buf, "-"], text);
    if (!r.ok) return "tmux did not accept it: " + r.err;
    r = await tmux(s, ["paste-buffer", "-p", "-d", "-b", buf, "-t", s.tmux_pane]);
    if (!r.ok) return "tmux did not accept it: " + r.err;
    await sleep(150);
    r = await tmux(s, ["send-keys", "-t", s.tmux_pane, "Enter"]);
    return r.ok ? null : "tmux did not accept it: " + r.err;
  });
}

const keyNames = { enter: "Enter", escape: "Escape", up: "Up", down: "Down", tab: "Tab" };

/// Presses keys in order, for example ["down", "down", "enter"].
function keys(names, s) {
  return serial(async () => {
    const e = await check(s);
    if (e) return e;
    for (const n of names) {
      const r = await tmux(s, ["send-keys", "-t", s.tmux_pane, keyNames[n]]);
      if (!r.ok) return "tmux did not accept it: " + r.err;
      await sleep(80);
    }
    return null;
  });
}

/// The visible screen of the pane, as text. Null when tmux cannot read it.
async function screen(s) {
  const r = await tmux(s, ["capture-pane", "-p", "-t", s.tmux_pane]);
  return r.ok ? r.out : null;
}

/// Claude Code draws its input between two rules, starting with "❯" and a no-break space.
/// Returns the text in it.
function inputLine(text) {
  const lines = text.split("\n");
  let start = -1;
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i].startsWith("❯")) { start = i; break; }
  if (start < 0) return null;
  const parts = [];
  for (let i = start; i < lines.length; i++) {
    if (i > start && lines[i].startsWith("─")) break;
    let l = lines[i];
    if (i === start) l = Array.from(l).slice(1).join("");
    // Spaces and tabs, including the no-break space Claude Code puts after the "❯".
    const t = l.replace(/^[ \t ]+|[ \t ]+$/g, "");
    if (t) parts.push(t);
  }
  return parts.join(" ");
}

async function readInputLine(s) {
  const sc = await screen(s);
  return sc == null ? null : inputLine(sc);
}

/// Deletes `count` characters before the cursor in the input line.
/// Not Ctrl+U: in Claude Code that clears only the current screen row of a long input.
async function clearInputLine(s, count) {
  let left = count + 3;
  while (left > 0) {
    const n = Math.min(left, 200);
    await tmux(s, ["send-keys", "-t", s.tmux_pane, "-N", String(n), "BSpace"]);
    left -= n;
  }
}

/// Selects the pane's window and pane, and returns its tmux session name (the tag in the tab title).
async function reveal(s) {
  if (!s.tmux_pane) return null;
  await tmux(s, ["select-window", "-t", s.tmux_pane]);
  await tmux(s, ["select-pane", "-t", s.tmux_pane]);
  const r = await tmux(s, ["display-message", "-p", "-t", s.tmux_pane, "#{session_name}"]);
  return r.ok ? r.out : null;
}

module.exports = { tmux, check, send, keys, screen, inputLine, readInputLine, clearInputLine, reveal, serial, errors };
