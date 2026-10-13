// Claude Stack for Windows: the floating small stack, the reader window, alerts, and the test modes.
// Windows port of App.swift. Everything Linux-side (sessions, chats, tmux) runs in the WSL backend,
// started here through wsl.exe and spoken to with one JSON object per line.
"use strict";
const { app, BrowserWindow, WebContentsView, Menu, Notification, clipboard, shell, screen, ipcMain,
  powerMonitor, nativeTheme } = require("electron");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const here = __dirname;
const webDir = path.join(here, "web");
const preload = path.join(here, "preload.js");
const config = readJSON(path.join(here, "config.json"), {});
const args = process.argv.slice(app.isPackaged ? 1 : 2);
const testMode = ["--scroll-test", "--reader-snapshot", "--snapshot", "--coach-snapshot"].includes(args[0]);

app.setAppUserModelId("local.sundaran.claudestack");
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");
nativeTheme.themeSource = "dark";
// Test modes may run while the real app runs, so they keep their own profile.
if (testMode) {
  app.setPath("userData", path.join(app.getPath("temp"), "claudestack-test"));
  // The test windows sit off screen; without this Windows calls them hidden and Chromium pauses them.
  app.commandLine.appendSwitch("disable-features", "CalculateNativeWinOcclusion");
  app.commandLine.appendSwitch("disable-renderer-backgrounding");
}
else if (!app.requestSingleInstanceLock()) app.exit(0);

function readJSON(p, fallback) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; } }

// ---------- Settings (the Mac keeps these in UserDefaults) ----------

const prefsPath = path.join(app.getPath("userData"), "prefs.json");
const prefs = Object.assign({
  soundOnNeeds: true, bannerOnNeeds: true, soundOnDone: false, compact: false,
  fontSize: 15, keepOnTop: false, coachSound: true, topLeft: null, readerBounds: null,
}, readJSON(prefsPath, {}));
function savePrefs() {
  try { fs.mkdirSync(path.dirname(prefsPath), { recursive: true }); fs.writeFileSync(prefsPath, JSON.stringify(prefs, null, 2)); } catch { /* keep in memory */ }
}
function setPref(k, v) {
  prefs[k] = v;
  savePrefs();
  if (k === "fontSize" || k === "coachSound") toBackend({ t: "prefs", fontSize: prefs.fontSize, coachSound: prefs.coachSound });
  if (k === "keepOnTop") applyKeepOnTop();
  broadcast("prefs", prefs);
  layoutStack();
}

// ---------- State from the backend ----------

let rows = [];
let coach = null;
let selected = null;
let tab = "chats";
let readerReady = false;

// ---------- The backend (WSL) ----------

let backend = null;
let quitting = false;
const logPath = path.join(app.getPath("userData"), "backend.log");

function toBackend(m) {
  if (backend && backend.stdin.writable) backend.stdin.write(JSON.stringify(m) + "\n");
}

function startBackend() {
  const distro = config.distro || "Ubuntu";
  const node = config.node || "node";
  const main = config.backend;
  if (!main) { log("config.json has no backend path. Run win/install.sh again."); return; }
  // WSL often runs on UTC while Windows has the real time zone. The day coach needs the real one.
  const tz = `CS_TZ=${Intl.DateTimeFormat().resolvedOptions().timeZone || ""}`;
  const offset = `CS_TZ_OFFSET=${new Date().getTimezoneOffset()}`;
  backend = spawn("wsl.exe", ["-d", distro, "--", "env", tz, offset, node, main], { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
  readline.createInterface({ input: backend.stdout }).on("line", (line) => {
    let m;
    try { m = JSON.parse(line); } catch { return log("backend said: " + line); }
    try { fromBackend(m); } catch (e) { log("handling " + m.t + ": " + e.stack); }
  });
  backend.stderr.on("data", (d) => log(String(d).trimEnd()));
  backend.on("exit", (code) => {
    log("backend exited with " + code);
    backend = null;
    // It crashed or WSL restarted: start it again, and let the reader page say hello again.
    if (!quitting) setTimeout(() => { startBackend(); sendPrefsToBackend(); if (readerReady) toBackend({ t: "page", msg: { type: "ready" } }); }, 2000);
  });
}

function sendPrefsToBackend() {
  toBackend({ t: "prefs", fontSize: prefs.fontSize, coachSound: prefs.coachSound });
  toBackend({ t: "tab", tab });
}

function log(msg) {
  try { fs.appendFileSync(logPath, `${new Date().toISOString()} ${msg}\n`); } catch { /* no log */ }
}

function fromBackend(m) {
  switch (m.t) {
    case "rows":
      rows = m.rows;
      broadcast("rows", rows);
      layoutStack();
      break;
    case "coach":
      coach = m.state;
      broadcast("coach", coach);
      layoutStack();
      break;
    case "selected":
      selected = m.id;
      broadcast("selected", selected);
      break;
    case "tab":
      tab = m.tab;
      broadcast("tab", tab);
      layoutReader();
      break;
    case "js":
      if (readerView && readerReady) {
        readerView.webContents.executeJavaScript(`${m.fn}(${JSON.stringify(m.arg)})`).catch((e) => log("page: " + e.message));
      }
      break;
    case "alert": alert(m); break;
    case "sound": if (prefs.coachSound) play("coach"); break;
    case "focus": focusTab(m.tag, m.term); break;
  }
}

// ---------- Alerts ----------

const sounds = {
  needs: "C:\\Windows\\Media\\Windows Notify System Generic.wav",
  done: "C:\\Windows\\Media\\Windows Notify Messaging.wav",
  coach: "C:\\Windows\\Media\\Windows Notify Calendar.wav",
};
function play(name) {
  const f = sounds[name];
  if (f && fs.existsSync(f) && stackWin) stackWin.webContents.send("ui", "play", "file:///" + f.replace(/\\/g, "/"));
}

function alert(a) {
  if (a.kind === "needs") {
    if (prefs.soundOnNeeds) play("needs");
    if (prefs.bannerOnNeeds && Notification.isSupported()) {
      const n = new Notification({ title: a.title, body: a.body, silent: true, icon: path.join(here, "icon.png") });
      // Clicking the banner opens that tab.
      n.on("click", () => toBackend({ t: "focus", id: a.sid }));
      n.show();
    }
  } else if (a.kind === "done" && prefs.soundOnDone) {
    play("done");
  }
}

// ---------- Jump to the tab (Windows Terminal, through UI Automation) ----------

let helper = null;
function winHelper() {
  if (helper && !helper.killed && helper.exitCode == null) return helper;
  helper = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path.join(here, "winhelper.ps1")],
    { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
  readline.createInterface({ input: helper.stdout }).on("line", (l) => log("winhelper: " + l));
  helper.stderr.on("data", (d) => log("winhelper error: " + String(d).trimEnd()));
  return helper;
}
function focusTab(tag, term) {
  winHelper().stdin.write(JSON.stringify({ op: "focus", tag: tag || "", term: term || "" }) + "\n");
}

// ---------- Pages ----------

let stackWin = null;
let readerWin = null;
let sideView = null;
let readerView = null;

function broadcast(ch, m) {
  for (const wc of [stackWin && stackWin.webContents, sideView && sideView.webContents]) if (wc && !wc.isDestroyed()) wc.send("ui", ch, m);
}

function pageState() { return { rows, coach, selected, tab, prefs }; }

function lockDown(wc) {
  // The pages never navigate away. Links open in the browser through the "open" message.
  wc.on("will-navigate", (e) => e.preventDefault());
  wc.setWindowOpenHandler(() => ({ action: "deny" }));
}

// ---------- The small stack ----------

const STACK_W = 336;
let stackSize = { w: STACK_W, h: 80 };

function createStack() {
  stackWin = new BrowserWindow({
    width: STACK_W, height: 80, show: false, frame: false, transparent: true, resizable: false,
    alwaysOnTop: true, skipTaskbar: true, hasShadow: false, maximizable: false, minimizable: false,
    // The small stack never takes the keyboard.
    focusable: false,
    webPreferences: { preload, sandbox: true, contextIsolation: true, backgroundThrottling: false },
  });
  stackWin.setAlwaysOnTop(true, "floating");
  stackWin.setVisibleOnAllWorkspaces(true);
  lockDown(stackWin.webContents);
  stackWin.loadFile(path.join(here, "ui", "stack.html"));
}

/// The reader is in front: its window is on screen and focused (or kept on top).
function readerInFront() {
  if (!readerWin || !readerWin.isVisible() || readerWin.isMinimized()) return false;
  // A reader kept on top is always in front, so the small stack stays hidden while it is open.
  return prefs.keepOnTop || readerWin.isFocused();
}

/// The small stack sizes to its content. The top-left corner stays where the user put it.
function layoutStack() {
  if (!stackWin || testMode || dragging) return;
  if (!rows.length || readerInFront()) { if (stackWin.isVisible()) stackWin.hide(); return; }
  const tl = prefs.topLeft || defaultTopLeft();
  const b = clampToScreen({ x: Math.round(tl[0]), y: Math.round(tl[1]), width: Math.ceil(stackSize.w), height: Math.ceil(stackSize.h) });
  const cur = stackWin.getBounds();
  if (cur.x !== b.x || cur.y !== b.y || cur.width !== b.width || cur.height !== b.height) stackWin.setBounds(b);
  if (!stackWin.isVisible()) stackWin.showInactive();
}

function defaultTopLeft() {
  const wa = screen.getPrimaryDisplay().workArea;
  return [wa.x + wa.width - STACK_W - 16, wa.y + 16];
}

/// Keep the stack on a screen (a monitor may have been unplugged).
function clampToScreen(r) {
  const wa = screen.getDisplayMatching(r).workArea;
  return {
    ...r,
    x: Math.min(Math.max(r.x, wa.x), wa.x + wa.width - r.width),
    y: Math.min(Math.max(r.y, wa.y), wa.y + wa.height - r.height),
  };
}

/// While the button is down, the stack follows the cursor. The page says when the press starts
/// and ends; the position comes from the system cursor, so a fast move never loses the window.
let dragging = null;
function drag(m) {
  if (m.phase === "start") {
    const b = stackWin.getBounds();
    const c = screen.getCursorScreenPoint();
    clearInterval(dragging && dragging.timer);
    dragging = { win: [b.x, b.y], cur: [c.x, c.y], moved: false };
    dragging.timer = setInterval(() => {
      const p = screen.getCursorScreenPoint();
      const dx = p.x - dragging.cur[0], dy = p.y - dragging.cur[1];
      if (!dragging.moved && Math.hypot(dx, dy) < 3) return;
      dragging.moved = true;
      stackWin.setPosition(dragging.win[0] + dx, dragging.win[1] + dy);
    }, 16);
    return;
  }
  if (!dragging) return;
  clearInterval(dragging.timer);
  const moved = dragging.moved;
  dragging = null;
  if (!moved) return;
  const b = stackWin.getBounds();
  prefs.topLeft = [b.x, b.y];
  savePrefs();
}

function stackMenu() {
  const toggle = (label, key) => ({ label, type: "checkbox", checked: !!prefs[key], click: () => setPref(key, !prefs[key]) });
  return Menu.buildFromTemplate([
    toggle("Sound when a tab needs you", "soundOnNeeds"),
    toggle("Banner when a tab needs you", "bannerOnNeeds"),
    toggle("Sound when a task is done", "soundOnDone"),
    { type: "separator" },
    { label: "Open reader", click: () => openReader(null) },
    toggle("Compact (pill)", "compact"),
    { label: "Reset position", click: () => { prefs.topLeft = null; savePrefs(); layoutStack(); } },
    { type: "separator" },
    { label: "Quit Claude Stack", click: () => app.quit() },
  ]);
}

// ---------- The reader window ----------

const SIDE_W = 300;

function createReader() {
  const saved = prefs.readerBounds;
  readerWin = new BrowserWindow({
    width: saved ? saved.width : 1000, height: saved ? saved.height : 720,
    x: saved ? saved.x : undefined, y: saved ? saved.y : undefined,
    minWidth: 680, minHeight: 440, show: false, title: "Claude Stack", backgroundColor: "#0F1923",
    autoHideMenuBar: true, icon: path.join(here, "icon.ico"),
  });
  readerWin.setMenu(null);
  sideView = new WebContentsView({ webPreferences: { preload, sandbox: true, contextIsolation: true } });
  readerView = new WebContentsView({ webPreferences: { preload, sandbox: true, contextIsolation: true } });
  sideView.setBackgroundColor("#0F1923");
  readerView.setBackgroundColor("#0F1923");
  readerWin.contentView.addChildView(readerView);
  readerWin.contentView.addChildView(sideView);
  for (const v of [sideView, readerView]) {
    lockDown(v.webContents);
    v.webContents.on("before-input-event", (e, input) => {
      // Ctrl+Shift+T: keep on top, as Cmd+Shift+T on the Mac.
      if (input.type === "keyDown" && input.control && input.shift && !input.alt && input.key.toLowerCase() === "t") {
        e.preventDefault();
        setPref("keepOnTop", !prefs.keepOnTop);
      }
    });
  }
  // The page reloads after a crash; say hello again then.
  readerView.webContents.on("did-start-loading", () => { readerReady = false; });
  sideView.webContents.loadFile(path.join(here, "ui", "shell.html"));
  readerView.webContents.loadFile(path.join(webDir, "reader.html"));

  readerWin.on("resize", () => { layoutReader(); saveReaderBounds(); });
  readerWin.on("move", saveReaderBounds);
  for (const ev of ["focus", "blur", "minimize", "restore", "show", "hide"]) readerWin.on(ev, () => layoutStack());
  // Closing the reader keeps the small stack running.
  readerWin.on("close", (e) => {
    if (quitting) return;
    e.preventDefault();
    readerWin.hide();
  });
  applyKeepOnTop();
  layoutReader();
}

function saveReaderBounds() {
  if (!readerWin || readerWin.isMinimized() || readerWin.isMaximized() || readerWin.isFullScreen()) return;
  prefs.readerBounds = readerWin.getBounds();
  savePrefs();
}

/// Sessions on the left, the chat page on the right. Settings take the whole window.
function layoutReader() {
  if (!readerWin) return;
  const [w, h] = readerWin.getContentSize();
  const settings = tab === "settings";
  sideView.setBounds({ x: 0, y: 0, width: settings ? w : SIDE_W, height: h });
  readerView.setVisible(!settings);
  readerView.setBounds({ x: SIDE_W + 1, y: 0, width: Math.max(0, w - SIDE_W - 1), height: h });
}

function openReader(id) {
  if (id) toBackend({ t: "select", id });
  if (prefs.compact) setPref("compact", false);
  if (readerWin.isMinimized()) readerWin.restore();
  readerWin.show();
  readerWin.focus();
  layoutStack();
}

/// ON: floats above every app, on every desktop. OFF: a normal window.
function applyKeepOnTop() {
  if (!readerWin) return;
  readerWin.setAlwaysOnTop(!!prefs.keepOnTop, "floating");
  readerWin.setVisibleOnAllWorkspaces(!!prefs.keepOnTop);
  layoutStack();
}

// ---------- Messages from the pages ----------

ipcMain.on("page", (e, body) => {
  if (!readerView || e.sender !== readerView.webContents || !body || typeof body.type !== "string") return;
  switch (body.type) {
    case "copy":
      if (typeof body.text === "string") {
        // HTML keeps bold and lists when pasted into Teams or Outlook. Plain text is for the rest.
        clipboard.write(typeof body.html === "string" && body.html ? { text: body.text, html: body.html } : { text: body.text });
      }
      return;
    case "open":
      try { const u = new URL(body.url); if (u.protocol === "http:" || u.protocol === "https:") shell.openExternal(u.href); } catch { /* not a link */ }
      return;
    case "paste":
      readerView.webContents.executeJavaScript(`CS.paste(${JSON.stringify(clipboard.readText())})`).catch(() => {});
      return;
    case "font":
      if (typeof body.size === "number") setPref("fontSize", body.size);
      return;
    case "ready":
      readerReady = true;
      break;
  }
  toBackend({ t: "page", msg: body });
});

ipcMain.on("ui", (e, ch, m) => {
  switch (ch) {
    case "hello": e.sender.send("ui", "state", pageState()); break;
    case "size":
      if (stackWin && e.sender === stackWin.webContents) { stackSize = m; layoutStack(); }
      break;
    case "drag": drag(m); break;
    case "menu": stackMenu().popup({ window: stackWin }); break;
    case "focus": toBackend({ t: "focus", id: m }); break;
    case "openReader": openReader(m); break;
    case "select": toBackend({ t: "select", id: m }); if (tab === "settings") toBackend({ t: "tab", tab: "chats" }); break;
    case "tab": toBackend({ t: "tab", tab: m }); break;
    case "coach": toBackend({ t: "coach", ...m }); break;
    case "pref": if (m && m.key in prefs && typeof m.value === typeof prefs[m.key]) setPref(m.key, m.value); break;
    case "toggleCompact": setPref("compact", !prefs.compact); break;
  }
});

// ---------- Start ----------

/// Toasts on Windows need a Start menu shortcut that carries the app's id. Made once.
function ensureShortcut() {
  if (!app.isPackaged) return;
  const lnk = path.join(app.getPath("appData"), "Microsoft", "Windows", "Start Menu", "Programs", "Claude Stack.lnk");
  if (fs.existsSync(lnk)) return;
  shell.writeShortcutLink(lnk, "create", { target: process.execPath, appUserModelId: "local.sundaran.claudestack", description: "Claude Stack" });
}

if (!testMode) {
  app.on("second-instance", () => openReader(null));
  app.whenReady().then(() => {
    ensureShortcut();
    startBackend();
    sendPrefsToBackend();
    createStack();
    createReader();
    // The day coach counts work time every 5 seconds from your keyboard and mouse.
    const idle = () => toBackend({ t: "idle", secs: powerMonitor.getSystemIdleTime() });
    idle();
    setInterval(idle, 5000);
    screen.on("display-removed", () => layoutStack());
    screen.on("display-metrics-changed", () => layoutStack());
  });
  // Closing windows never quits; only Quit in the menu does.
  app.on("window-all-closed", () => {});
  app.on("before-quit", () => {
    quitting = true;
    toBackend({ t: "quit" });
    if (helper) helper.kill();
  });
} else {
  require("./testmodes").run(args, { here, webDir, preload });
}
