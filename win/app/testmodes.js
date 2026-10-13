// Test modes, as the Mac binary's flags (App.swift). They draw off screen and exit.
//   --scroll-test items.json script.js out.txt     does the chat stay where the user scrolled?
//   --reader-snapshot items.json out.png [state.json]
//   --snapshot out.png [compact]                    the small stack with one row of each status
//   --coach-snapshot out.png                         the day strip and every reminder card
// items.json is the "items" list printed by `claudestack --parse`. win/bin/app-test makes it.
"use strict";
const { app, BrowserWindow } = require("electron");
const fs = require("fs");
const path = require("path");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function offscreen(w, h, opts = {}) {
  return new BrowserWindow({
    x: -4000, y: -4000, width: w, height: h, show: true, frame: false, skipTaskbar: true, focusable: false,
    backgroundColor: opts.transparent ? undefined : "#0F1923", transparent: !!opts.transparent,
    webPreferences: { preload: opts.preload, sandbox: true, contextIsolation: true, backgroundThrottling: false },
  });
}

async function savePNG(win, out) {
  await sleep(700);
  const img = await win.webContents.capturePage();
  fs.writeFileSync(out, img.toPNG());
}

const baseState = {
  sid: "test", project: "test-project", branch: "main", display: "Done", color: "#06C27A", running: false,
  tool: "", detail: "", canSend: true, block: "", fontSize: 15,
};

async function scrollTest(items, script, out) {
  const win = offscreen(700, 500, {});
  await win.loadFile(path.join(this.webDir, "reader.html"));
  const st = { ...baseState, display: "Running", color: "#5B9BE6", running: true, tool: "Bash" };
  const setup = `window.__items = ${JSON.stringify(items)}; window.__state = ${JSON.stringify(st)}; CS.reset({sid:'test'});
    CS.setItems({sid:'test', hasMore:false, items: window.__items}); CS.setState(window.__state);`;
  await win.webContents.executeJavaScript(setup + fs.readFileSync(script, "utf8"));
  for (let i = 0; i < 60; i++) {
    await sleep(200);
    const r = await win.webContents.executeJavaScript("window.__result || ''");
    if (r) { fs.writeFileSync(out, r); return; }
  }
  fs.writeFileSync(out, "timeout");
}

async function readerSnapshot(items, out, stateFile) {
  const st = { ...baseState, ...(stateFile ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : {}) };
  const win = offscreen(860, 1300, {});
  await win.loadFile(path.join(this.webDir, "reader.html"));
  await win.webContents.executeJavaScript(`CS.reset({sid:'test'}); CS.setItems(${JSON.stringify({ sid: "test", items, hasMore: false })});
    CS.setState(${JSON.stringify(st)}); CS.mode(${JSON.stringify(st.mode || "chats")}); ${st.js || ""}; 0`);
  await savePNG(win, out);
}

function demoRows() {
  const now = Date.now() / 1000;
  const r = (id, display, label, color, title, detail, since, extra = {}) =>
    ({ id, display, label, color, title, detail, since: now - since, background: false, agents: 0, branch: "main", prompt: "", cwd: "/home/you/" + title, ...extra });
  return [
    r("a", "needs", "Needs you", "#FF9A00", "humini-send", "Permission", 12, { prompt: "Fix the OTP expiry bug and add a test" }),
    r("b", "running", "Running", "#5B9BE6", "claudestack", "Running", 95, { prompt: "Port the app to Windows", agents: 2, branch: "stack-windows" }),
    r("c", "stuck", "Maybe stuck", "#F4A500", "arus-proof", "Maybe stuck", 700),
    r("d", "done", "Done", "#06C27A", "humini-gate", "Done", 240, { prompt: "Add the login page" }),
    r("e", "ready", "Ready", "#5FA889", "humini-app", "Ready", 30),
    r("f", "idle", "Idle", "#8A9BAE", "arus-decks", "Idle", 4000, { background: true, prompt: "Regenerate the deck" }),
  ];
}

function demoCoach(reminder, phase = "working") {
  return {
    reminder, phase, dayFraction: phase === "windDown" ? 0.95 : 0.55, waterFraction: 0.7, restFraction: 0.4,
    minutesLeft: phase === "windDown" ? 25 : 250, dayOff: false,
    summary: { prompts: 42, tasksDone: 17, agents: 6, water: 5, breaks: 3, workSecs: 6.5 * 3600 },
    config: { start: "09:30", end: "18:30", checkFrom: "18:00", lunchStart: "13:00", lunchEnd: "13:45", waterMinutes: 60, restMinutes: 120, workdays: [2, 3, 4, 5, 6] },
  };
}

async function stackSnapshot(out, compact) {
  const win = offscreen(400, 700, { transparent: false, preload: this.preload });
  await win.loadFile(path.join(this.here, "ui", "stack.html"));
  win.webContents.send("ui", "state", { rows: demoRows(), coach: demoCoach(null), prefs: { compact } });
  await savePNG(win, out);
}

async function coachSnapshot(out) {
  const win = offscreen(680, 900, { preload: this.preload });
  await win.loadFile(path.join(this.here, "ui", "stack.html"));
  const cases = [[{ kind: "water" }, "working"], [{ kind: "rest" }, "working"], [{ kind: "lunch" }, "working"],
    [{ kind: "windDown", minutesLeft: 25 }, "windDown"], [{ kind: "dayDone" }, "done"], [{ kind: "overtime", minutes: 30 }, "done"]];
  const html = `<div style="display:grid;grid-template-columns:300px 300px;gap:12px;padding:16px;background:#0F1923">` +
    cases.map(([r, p]) => `<div style="display:flex;flex-direction:column;gap:6px">\${stripHTML(${JSON.stringify(demoCoach(r, p))})}\${reminderHTML(${JSON.stringify(demoCoach(r, p))})}</div>`).join("") + `</div>`;
  await win.webContents.executeJavaScript("document.body.style.background='#0F1923'; document.body.innerHTML = `" + html + "`; 0");
  await savePNG(win, out);
}

exports.run = function (args, ctx) {
  app.whenReady().then(async () => {
    try {
      const [flag, a, b, c] = args;
      const items = (f) => { const o = JSON.parse(fs.readFileSync(f, "utf8")); return Array.isArray(o) ? o : o.items; };
      if (flag === "--scroll-test") await scrollTest.call(ctx, items(a), b, c);
      else if (flag === "--reader-snapshot") await readerSnapshot.call(ctx, items(a), b, c);
      else if (flag === "--snapshot") await stackSnapshot.call(ctx, a, b === "compact");
      else if (flag === "--coach-snapshot") await coachSnapshot.call(ctx, a);
    } catch (e) {
      try { fs.writeFileSync(path.join(app.getPath("temp"), "claudestack-test-error.txt"), String(e.stack || e)); } catch { /* nothing */ }
      app.exit(1);
    }
    app.exit(0);
  });
};
