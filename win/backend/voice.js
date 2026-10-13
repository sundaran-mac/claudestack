// Voice through Claude Code itself, so it is exactly the voice you get in the tab. Port of TabVoice.swift.
// Holding space in the box sends a stream of spaces to the pane (like a held key), Claude Code
// listens and writes the words into its input line, then the app moves those words into the box.
"use strict";
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { stackDir } = require("./util");
const tmux = require("./tmux");

/// One line per step in ~/.claude/stack/voice.log, so a failed try can be read afterwards.
function voiceLog(msg) {
  try { fs.appendFileSync(path.join(stackDir, "voice.log"), `${new Date().toISOString()} ${msg}\n`); } catch { /* no log */ }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class TabVoice {
  constructor() {
    /// True from the hold until the release. The pane check is slow, so it checks this before sending.
    this.wanted = false;
    /// (state, text, error). States: listening, writing, done.
    this.onUpdate = null;
    /// The helper that sends the "held space". A separate process, so nothing else can slow it down.
    this.streamer = null;
    this.session = null;
    this.baseline = "";
    this.startedAt = null;
  }

  report(state, text, err) { if (this.onUpdate) this.onUpdate(state, text, err || ""); }

  /// Starts listening in the session's pane.
  async start(s) {
    if (this.streamer) return;
    this.wanted = true;
    this.session = null;
    voiceLog(`start session=${s.session_id.slice(0, 8)} pane=${s.tmux_pane || "-"} tty=${s.tty || "-"}`);
    const e = await tmux.check(s);
    if (e) {
      voiceLog("no pane: " + e);
      return this.report("done", "", e === tmux.errors.notTmux ? e : "Could not find this tab, so voice cannot start.");
    }
    // What the input line shows before you speak (a placeholder, or a draft you typed).
    const base = (await tmux.readInputLine(s)) ?? "";
    voiceLog(`pane=${s.tmux_pane} baseline=${base.slice(0, 40)}`);
    // You let go while the pane was being checked: do not start sending spaces.
    if (!this.wanted) return voiceLog("released before start, nothing sent");
    this.session = s;
    this.baseline = base;
    // Claude Code keeps listening only while spaces keep coming with no gap, so a steady space
    // every 10 ms, from its own process. Stopped on release; ends by itself after 60 seconds as a safety cap.
    const sock = s.tmux_socket ? `-S ${JSON.stringify(s.tmux_socket)}` : "";
    const script = `end=$((SECONDS+60)); while [ $SECONDS -lt $end ]; do tmux ${sock} send-keys -t ${JSON.stringify(s.tmux_pane)} ' ' || exit 1; sleep 0.01; done`;
    try {
      this.streamer = spawn("bash", ["-c", script], { stdio: "ignore" });
      this.streamer.on("error", (err) => voiceLog("space stream error: " + err.message));
    } catch (err) {
      voiceLog("could not start the space stream: " + err.message);
      return this.report("done", "", "Could not start voice: " + err.message);
    }
    this.startedAt = Date.now();
    this.report("listening", "", null);
  }

  /// The app is quitting: stop sending at once, take nothing.
  cancel() {
    this.wanted = false;
    if (this.streamer) this.streamer.kill();
    this.streamer = null;
  }

  /// You let go of space: stop the key stream, wait for Claude Code to write the words, take them.
  async stop() {
    this.wanted = false;
    // Let go before voice had started (the pane check takes a moment): say so, never hang.
    const streamer = this.streamer;
    if (!streamer) {
      voiceLog("stop before start");
      return this.report("done", "", 'Voice had not started yet. Hold space until "Listening" shows, then speak.');
    }
    streamer.kill();
    this.streamer = null;
    const held = (Date.now() - (this.startedAt || Date.now())) / 1000;
    voiceLog(`stop after ${held.toFixed(1)} s`);
    const s = this.session;
    if (!s) return;
    this.report("writing", "", null);
    const base = this.baseline;
    let last = null, same = 0, text = "";
    // Claude Code needs a moment to turn the recording into text, and adds the last words
    // late. Take the line once it has stayed the same for three reads (about a second).
    for (let i = 0; i < 30; i++) {
      await sleep(350);
      const now = await tmux.readInputLine(s);
      if (now == null) continue;
      same = now === last ? same + 1 : 0;
      last = now;
      if (same >= 2 && now !== base) { text = now; break; }
    }
    voiceLog(`read text=${text.slice(0, 60)} last=${(last ?? "nil").slice(0, 40)}`);
    if (!text) {
      return this.report("done", "", 'No words came through. Hold space a little longer, and speak after "listening" shows.');
    }
    // Move the words: clear the pane's input line, then hand them to the box.
    await tmux.clearInputLine(s, Array.from(text).length);
    this.report("done", text, null);
  }
}

module.exports = { TabVoice, voiceLog };
