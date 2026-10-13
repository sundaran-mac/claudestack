// tmux control against a fake Claude in a real tmux pane (its own tmux server). Usage: node win/tests/tmux-test.js
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const tmux = require("../backend/tmux");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cs-tmux-"));
const sock = path.join(dir, "sock");
const log = path.join(dir, "log");
const fake = path.join(dir, "fake.sh");
// The fake Claude draws an input box like Claude Code, then records every byte it is sent.
fs.writeFileSync(fake, `#!/bin/bash
printf 'Claude Code\\n────────────\\n❯\\u00a0hello there\\n────────────\\n'
stty raw -echo
exec cat > ${JSON.stringify(log)}
`);
fs.chmodSync(fake, 0o755);
const t = (...a) => execFileSync("tmux", ["-S", sock, "-f", "/dev/null", ...a]).toString().trim();
let fail = 0;
const ok = (name, cond, extra = "") => { console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond ? "" : " " + extra}`); if (!cond) fail = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The fake keeps writing at its own offset, so each check reads only what came after `mark`.
let mark = 0;
const bytes = () => { try { return fs.readFileSync(log, "latin1").slice(mark); } catch { return ""; } };
const next = () => { mark += bytes().length; };

(async () => {
  t("new-session", "-d", "-s", "t", "-x", "80", "-y", "20", fake);
  await sleep(400);
  const pane = t("display-message", "-p", "-t", "t", "#{pane_id}");
  const tty = t("display-message", "-p", "-t", "t", "#{pane_tty}").replace("/dev/", "");
  const pid = Number(t("display-message", "-p", "-t", "t", "#{pane_pid}"));
  const s = { session_id: "x", tmux_pane: pane, tmux_socket: sock, tty, pid };

  ok("input line read from the screen", (await tmux.readInputLine(s)) === "hello there", await tmux.readInputLine(s));
  ok("send is refused without a tmux pane", (await tmux.send("x", { ...s, tmux_pane: undefined })) === tmux.errors.notTmux);
  ok("send is refused when the pane holds another tty", (await tmux.send("x", { ...s, tty: "pts/999" })) === tmux.errors.notFound);
  ok("send is refused when Claude is gone", (await tmux.send("x", { ...s, pid: 999999 })) === tmux.errors.gone);
  ok("nothing reached the pane after refusals", bytes() === "", JSON.stringify(bytes()));

  ok("send works", (await tmux.send("hello\nworld", s)) === null);
  await sleep(300);
  ok("text pasted as one block, then Enter", bytes() === "hello\rworld\r", JSON.stringify(bytes()));

  next();
  ok("keys work", (await tmux.keys(["escape", "down", "up", "tab", "enter"], s)) === null);
  await sleep(300);
  ok("Esc, arrows, Tab and Enter arrive in order", bytes() === "\x1b\x1b[B\x1b[A\t\r", JSON.stringify(bytes()));

  next();
  await tmux.clearInputLine(s, 5);
  await sleep(300);
  ok("clearing the input line sends one Backspace per character, plus 3", bytes() === "\x7f".repeat(8), JSON.stringify(bytes()));

  ok("reveal gives the tmux session name for the tab tag", (await tmux.reveal(s)) === "t");
  t("kill-server");
  fs.rmSync(dir, { recursive: true, force: true });
  process.exit(fail);
})();
