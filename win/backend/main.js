// Claude Stack backend for Windows. Runs in WSL, started by the Windows app through wsl.exe.
// It does every Linux-side job (session files, transcripts, processes, tmux) and talks to the app
// with one JSON object per line: the app writes to stdin, this writes to stdout.
"use strict";
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { stackDir } = require("./util");

// Use the Windows time zone, not WSL's (often UTC), so day hours match the clock on screen.
// Node knows every zone name. The hooks (bash `date`) need a file in /usr/share/zoneinfo, which may
// lack old names Windows still uses (Asia/Calcutta), so the tz file falls back to the current offset.
function useWindowsTimeZone() {
  const name = process.env.CS_TZ || "", off = parseInt(process.env.CS_TZ_OFFSET, 10);
  if (name) process.env.TZ = name;
  let forShell = "";
  if (name && fs.existsSync(path.join("/usr/share/zoneinfo", name))) forShell = name;
  else if (Number.isFinite(off)) {
    // getTimezoneOffset is minutes behind UTC; POSIX TZ uses the same sign. India (-330) is "<+0530>-05:30".
    const a = Math.abs(off), hh = String(Math.trunc(a / 60)).padStart(2, "0"), mm = String(a % 60).padStart(2, "0");
    forShell = `<${off <= 0 ? "+" : "-"}${hh}${mm}>${off < 0 ? "-" : "+"}${hh}:${mm}`;
  }
  if (!forShell) return;
  try { fs.mkdirSync(stackDir, { recursive: true }); fs.writeFileSync(path.join(stackDir, "tz"), forShell + "\n"); } catch { /* nothing */ }
}
useWindowsTimeZone();
const { Store, rowView } = require("./store");
const { ReaderModel } = require("./reader");
const { DayCoach } = require("./coach");

function emit(m) {
  try { process.stdout.write(JSON.stringify(m) + "\n"); } catch { process.exit(0); }
}
const log = (msg) => process.stderr.write(`[backend] ${msg}\n`);

const store = new Store();
const reader = new ReaderModel(emit);
const coach = new DayCoach();

store.onAlert = (a) => emit({ t: "alert", ...a });
coach.onSound = () => emit({ t: "sound", name: "coach" });

let lastRows = "";
function tick() {
  try {
    const rows = store.reload();
    const views = rows.map(rowView);
    const str = JSON.stringify(views);
    if (str !== lastRows) { lastRows = str; emit({ t: "rows", rows: views }); }
    reader.update(rows);
  } catch (e) { log("tick: " + (e && e.stack || e)); }
}

let lastCoach = "";
function pushCoach() {
  const str = JSON.stringify(coach.state);
  if (str !== lastCoach) { lastCoach = str; emit({ t: "coach", state: coach.state }); }
}

// The hook starts the app when this heartbeat is older than 5 seconds.
const alivePath = path.join(stackDir, "app.alive");
function heartbeat() {
  try { fs.mkdirSync(stackDir, { recursive: true }); fs.writeFileSync(alivePath, String(Date.now())); } catch { /* read-only */ }
}

async function handle(m) {
  switch (m.t) {
    case "page": return reader.onPage(m.msg);
    case "select": return reader.select(m.id);
    case "tab": return reader.setTab(m.tab);
    case "prefs":
      if (typeof m.fontSize === "number") reader.fontSize = m.fontSize;
      if (typeof m.coachSound === "boolean") coach.soundOn = m.coachSound;
      reader.lastStateJSON = "";
      return reader.pushState();
    case "focus": {
      const r = store.rows.find((x) => x.s.session_id === m.id);
      if (r) return reader.focus(r.s);
      return;
    }
    // The app reads the idle time on Windows every 5 seconds.
    case "idle": coach.tick(Number(m.secs) || 0); return pushCoach();
    case "coach":
      if (m.action === "done") coach.done();
      else if (m.action === "later") coach.later();
      else if (m.action === "save" && m.config) coach.save(m.config);
      else if (m.action === "dayOff") coach.dayOff = !!m.on;
      return pushCoach();
    case "quit": reader.voice.cancel(); process.exit(0);
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  Promise.resolve(handle(m)).catch((e) => log("handle " + m.t + ": " + (e && e.stack || e)));
});
// The app went away (closed or crashed): stop too, so the heartbeat stops and the hook can start it again.
rl.on("close", () => { reader.voice.cancel(); process.exit(0); });

emit({ t: "hello", home: require("./util").home, pid: process.pid });
coach.tick(0);
pushCoach();
tick();
heartbeat();
setInterval(tick, 500);
setInterval(heartbeat, 1000);
