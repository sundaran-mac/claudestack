// The day coach: work time, water and rest reminders, lunch, the end of the day, and today's numbers.
// Port of DayCoach.swift. Work time counts while you use the computer: any keyboard or mouse input in
// the last 5 minutes (the Windows app sends the idle time). Five minutes with no input is a break.
"use strict";
const fs = require("fs");
const path = require("path");
const { stackDir, daysDir, mtimeOf } = require("./util");

const dayConfigPath = path.join(stackDir, "day.json");

/// Shared with day-hook.sh, so both read the same hours.
function defaultConfig() {
  return {
    start: "09:30", end: "18:30",
    checkFrom: "18:00",          // new tasks after this get a time check
    lunchStart: "13:00", lunchEnd: "13:45",
    waterMinutes: 60, restMinutes: 120,
    workdays: [2, 3, 4, 5, 6],   // Calendar weekdays: 1 is Sunday, so Monday to Friday
  };
}

function loadConfig() {
  try {
    const c = JSON.parse(fs.readFileSync(dayConfigPath, "utf8"));
    if (c && typeof c === "object") return { ...defaultConfig(), ...c };
  } catch { /* first run */ }
  const c = defaultConfig();
  try { fs.mkdirSync(stackDir, { recursive: true }); fs.writeFileSync(dayConfigPath, sortedJSON(c)); } catch { /* read-only */ }
  return c;
}

function sortedJSON(o) { return JSON.stringify(Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]])), null, 2); }

/// "18:30" on the day of `d`, as a Date.
function timeOn(hm, d) {
  const p = String(hm).split(":").map((x) => parseInt(x, 10));
  const t = new Date(d);
  t.setHours(Number.isFinite(p[0]) ? p[0] : 0, Number.isFinite(p[1]) ? p[1] : 0, 0, 0);
  return t;
}

function dayString(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function hm(secs) {
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

/// Per-day numbers in days/<date>.coach.json, so a restart keeps them. Tests use a plain object.
class FileStore {
  constructor() { this.day = ""; this.data = {}; }
  load(day) {
    if (day === this.day) return;
    this.day = day;
    try { this.data = JSON.parse(fs.readFileSync(path.join(daysDir, `${day}.coach.json`), "utf8")) || {}; } catch { this.data = {}; }
  }
  get(k) { return this.data[k]; }
  set(k, v) {
    this.data[k] = v;
    try {
      fs.mkdirSync(daysDir, { recursive: true });
      const f = path.join(daysDir, `${this.day}.coach.json`);
      fs.writeFileSync(f + ".tmp", JSON.stringify(this.data));
      fs.renameSync(f + ".tmp", f);
    } catch { /* keep going in memory */ }
  }
}
class MemoryStore { constructor() { this.data = {}; } load() {} get(k) { return this.data[k]; } set(k, v) { this.data[k] = v; } }

function sameReminder(a, b) {
  if (!a || !b) return a === b;
  return a.kind === b.kind && a.minutesLeft === b.minutesLeft && a.minutes === b.minutes;
}

class DayCoach {
  /// Tests pass their own store and no log, so they never touch the real numbers.
  constructor({ store = new FileStore(), useLog = true, config } = {}) {
    this.store = store;
    this.useLog = useLog;
    this.config = config || loadConfig();
    this.soundOn = true;
    this.onSound = null;
    this.reminder = null;
    this.summary = { prompts: 0, tasksDone: 0, agents: 0, water: 0, breaks: 0, workSecs: 0 };
    this.phase = "before";      // before, working, windDown, done, off
    this.dayFraction = 0;       // 0 at start, 1 at end
    this.waterFraction = 0;     // fills up to the next water reminder
    this.restFraction = 0;
    this.minutesLeft = 0;
    this.lastTick = null; this.idleSince = null; this.snoozedUntil = null; this.answeredAt = null;
    this.day = "";
    this.logCache = null;
  }

  num(k) { const v = this.store.get(k); return typeof v === "number" ? v : 0; }
  get workSecs() { return this.num("work"); }
  set workSecs(v) { this.store.set("work", v); }
  get waterAt() { return this.num("waterAt"); }
  set waterAt(v) { this.store.set("waterAt", v); }
  get restAt() { return this.num("restAt"); }
  set restAt(v) { this.store.set("restAt", v); }
  flag(k) { return this.store.get(k) === true; }
  setFlag(k) { this.store.set(k, true); }
  count(k) { return this.num(k); }
  bump(k) { this.store.set(k, this.count(k) + 1); }

  /// Today only. day-hook.sh reads the same switch as a file: days/<date>.off
  get dayOff() { return this.flag("off"); }
  set dayOff(v) {
    this.store.set("off", v);
    const f = path.join(daysDir, `${this.day}.off`);
    try {
      if (v) { fs.mkdirSync(daysDir, { recursive: true }); fs.writeFileSync(f, ""); } else fs.rmSync(f, { force: true });
    } catch { /* the hook just will not see it */ }
    this.tick(this.lastIdle ?? 0);
  }

  save(c) {
    this.config = { ...defaultConfig(), ...c };
    try { fs.writeFileSync(dayConfigPath, sortedJSON(this.config)); } catch { /* keep in memory */ }
    this.tick(this.lastIdle ?? 0);
  }

  /// `idle`: seconds since your last keyboard or mouse input.
  tick(idle, now = new Date()) {
    this.lastIdle = idle;
    const today = dayString(now);
    if (today !== this.day) {
      this.day = today; this.store.load(today);
      this.reminder = null; this.snoozedUntil = null; this.idleSince = null; this.answeredAt = null;
    }
    // The computer may have slept.
    const dt = this.lastTick ? Math.max(0, Math.min((now - this.lastTick) / 1000, 30)) : 0;
    this.lastTick = now;

    const log = this.useLog ? this.readLog(today) : { prompts: 0, stops: 0, agents: 0 };
    const active = idle < 300;
    if (active) {
      this.workSecs = this.workSecs + dt;
      this.idleSince = null;
    } else if (this.idleSince == null) {
      // Five minutes with no keyboard or mouse: you stepped away. That is a break, once.
      this.idleSince = now;
      if (this.workSecs - this.restAt > 60) {
        this.restAt = this.workSecs;
        this.bump("breaks");
      }
    }

    const c = this.config;
    const weekday = now.getDay() + 1;
    const start = timeOn(c.start, now), end = timeOn(c.end, now), checkFrom = timeOn(c.checkFrom, now);
    const workday = c.workdays.includes(weekday) && !this.dayOff;
    this.minutesLeft = Math.max(0, Math.trunc((end - now) / 60000));
    this.dayFraction = Math.max(0, Math.min(1, (now - start) / (end - start)));
    this.waterFraction = Math.min(1, (this.workSecs - this.waterAt) / (c.waterMinutes * 60));
    this.restFraction = Math.min(1, (this.workSecs - this.restAt) / (c.restMinutes * 60));
    this.summary = { prompts: log.prompts, tasksDone: log.stops, agents: log.agents,
      water: this.count("water"), breaks: this.count("breaks"), workSecs: this.workSecs };

    if (!workday) this.phase = "off";
    else if (now < start) this.phase = "before";
    else if (now < checkFrom) this.phase = "working";
    else if (now < end) this.phase = "windDown";
    else this.phase = "done";

    const next = this.pick(now, workday, active, end);
    if (!sameReminder(next, this.reminder)) {
      if (next && this.soundOn && !this.isSameKind(next, this.reminder) && this.onSound) this.onSound();
      this.reminder = next;
    }
  }

  /// One reminder at a time, the most important first.
  pick(now, workday, active, end) {
    // Weekends and days off: no reminders at all.
    if (!workday) return null;
    if (this.snoozedUntil && now < this.snoozedUntil) return null;
    if (this.phase === "done") {
      if (!this.flag("dayDoneSeen")) return { kind: "dayDone" };
      // After the day: a gentle note every 15 minutes, only while you keep working.
      const past = Math.trunc((now - end) / 60000);
      if (active && past >= 15 && Math.floor(past / 15) > this.count("overtimeSeen")) return { kind: "overtime", minutes: past };
      return null;
    }
    if (this.phase === "windDown" && !this.flag("windDownSeen")) return { kind: "windDown", minutesLeft: this.minutesLeft };
    const lunchStart = timeOn(this.config.lunchStart, now), lunchEnd = timeOn(this.config.lunchEnd, now);
    if (now >= lunchStart && now < lunchEnd) return this.flag("lunchSeen") ? null : { kind: "lunch" };
    // After you answer one reminder, the next water or rest waits at least 15 minutes.
    if (this.answeredAt && (now - this.answeredAt) / 1000 < 900) return null;
    if (this.restFraction >= 1) return { kind: "rest" };
    if (this.waterFraction >= 1) return { kind: "water" };
    return null;
  }

  isSameKind(a, b) {
    if (!b) return false;
    if (a.kind === b.kind && (a.kind === "windDown" || a.kind === "overtime")) return true;
    return sameReminder(a, b);
  }

  // ---------- Buttons ----------

  done() {
    const r = this.reminder;
    if (!r) return;
    switch (r.kind) {
      case "water": this.waterAt = this.workSecs; this.bump("water"); break;
      // A rest or lunch includes a drink of water, so water starts again too. The water count stays.
      case "rest": this.restAt = this.workSecs; this.waterAt = this.workSecs; this.bump("breaks"); break;
      case "lunch": this.setFlag("lunchSeen"); this.restAt = this.workSecs; this.waterAt = this.workSecs; break;
      case "windDown": this.setFlag("windDownSeen"); break;
      case "dayDone": this.setFlag("dayDoneSeen"); break;
      case "overtime": this.bump("overtimeSeen"); break;
    }
    this.reminder = null;
    this.answeredAt = this.lastTick || new Date();
    this.tick(this.lastIdle ?? 0, this.lastTick || new Date());
  }

  later() {
    this.snoozedUntil = new Date(Date.now() + 600 * 1000);
    this.reminder = null;
  }

  // ---------- Today's log, written by stack-hook.sh ----------

  readLog(day) {
    const f = path.join(daysDir, `${day}.jsonl`);
    const mtime = mtimeOf(f);
    if (this.logCache && this.logCache.day === day && this.logCache.mtime === mtime) return this.logCache.log;
    const log = { prompts: 0, stops: 0, agents: 0 };
    let text = "";
    try { text = fs.readFileSync(f, "utf8"); } catch { /* no log yet */ }
    for (const line of text.split("\n")) {
      let o;
      try { o = JSON.parse(line); } catch { continue; }
      if (!o) continue;
      if (o.e === "prompt") log.prompts += 1;
      else if (o.e === "stop") log.stops += 1;
      else if (o.e === "agent") log.agents += 1;
    }
    this.logCache = { day, mtime, log };
    return log;
  }

  get state() {
    return {
      reminder: this.reminder, summary: this.summary, phase: this.phase, dayFraction: this.dayFraction,
      waterFraction: this.waterFraction, restFraction: this.restFraction, minutesLeft: this.minutesLeft,
      config: this.config, dayOff: this.dayOff,
    };
  }
}

/// Wednesday 2026-10-07, default hours. Busy all day except a 6-minute pause at 11:40 and lunch.
/// Each reminder is answered one minute after it appears, as a person would.
function coachSim() {
  const c = new DayCoach({ store: new MemoryStore(), useLog: false, config: defaultConfig() });
  c.soundOn = false;
  let t = new Date(2026, 9, 7, 9, 30);
  const stop = new Date(2026, 9, 7, 19, 5);
  const p = (n) => String(n).padStart(2, "0");
  const f = (d) => `${p(d.getHours())}:${p(d.getMinutes())}`;
  let shownAt = null, last = null;
  while (t < stop) {
    const m = t.getHours() * 60 + t.getMinutes();
    // At the desk all day, except a 6-minute pause at 11:40 and lunch away from the computer.
    const away = (m >= 11 * 60 + 40 && m < 11 * 60 + 46) || (m >= 13 * 60 && m < 13 * 60 + 45);
    const awaySince = m >= 13 * 60 ? 13 * 60 : 11 * 60 + 40;
    c.tick(away ? (m - awaySince) * 60 + 1 : 2, t);
    // Print the kind only: "25 minutes left" counting down is the same card.
    const name = c.reminder ? c.reminder.kind : null;
    if (name !== last && name) { console.log(`${f(t)} ${name}`); shownAt = t; }
    last = name;
    if (shownAt && c.reminder && (t - shownAt) / 1000 >= 60) { c.done(); shownAt = null; last = null; }
    t = new Date(t.getTime() + 5000);
  }
  console.log(`summary work=${hm(c.summary.workSecs)} water=${c.summary.water} breaks=${c.summary.breaks} phase=${c.phase}`);
  // Saturday: no reminders at all.
  const sat = new DayCoach({ store: new MemoryStore(), useLog: false, config: defaultConfig() });
  sat.soundOn = false;
  let s = new Date(2026, 9, 10, 9, 30);
  let any = false;
  for (let i = 0; i < 4 * 720; i++) { sat.tick(2, s); if (sat.reminder) any = true; s = new Date(s.getTime() + 5000); }
  console.log(`saturday phase=${sat.phase} reminders=${any}`);
}

module.exports = { DayCoach, coachSim, loadConfig, defaultConfig, hm };
