// The reader sidebar: tabs, day strip, reminder and sessions; and the Settings page.
// Port of ReaderView (Views.swift) and SettingsView (DayViews.swift).
"use strict";
let S = { rows: [], coach: null, selected: null, tab: "chats", prefs: {} };
let draft = null;      // the day settings being edited, saved with "Save day settings"
let savedFlash = false;
const $ = (id) => document.getElementById(id);

function renderSide() {
  for (const b of document.querySelectorAll("#tabs button")) b.classList.toggle("on", b.dataset.tab === S.tab);
  const on = !!S.prefs.keepOnTop;
  $("pin").className = "pin" + (on ? " on" : "");
  $("pin").innerHTML = on ? ICON.pinOn : ICON.pin;
  $("pin").title = on ? "Kept on top of all apps. Click for a normal window. (Ctrl+Shift+T)" : "Normal window. Click to keep it on top of all apps. (Ctrl+Shift+T)";
  $("strip").innerHTML = stripHTML(S.coach);
  $("reminder").innerHTML = reminderHTML(S.coach);
  $("rows").innerHTML = (S.rows || []).map((r) => rowHTML(r, { selected: r.id === S.selected })).join("");
}

const DAYS = [[2, "Mon"], [3, "Tue"], [4, "Wed"], [5, "Thu"], [6, "Fri"], [7, "Sat"], [1, "Sun"]];
const toggle = (key, label, on) => `<div class="toggle${on ? " on" : ""}" data-toggle="${key}"><span class="sw"></span><span>${esc(label)}</span></div>`;
const timeRow = (key, label, note = "") => `<div><div class="line"><span class="k">${esc(label)}</span>
  <input type="time" data-time="${key}" value="${esc(draft[key])}"></div>${note ? `<div class="small">${esc(note)}</div>` : ""}</div>`;
const stepRow = (key, label, note = "") => `<div><div class="line"><span class="k">${esc(label)}</span>
  <span class="step"><button data-step="${key}" data-d="-15">−</button><span>${draft[key]} min</span><button data-step="${key}" data-d="15">+</button></span></div>
  ${note ? `<div class="small">${esc(note)}</div>` : ""}</div>`;
const section = (title, note, body) => `<section class="sec"><h2>${esc(title)}</h2>${note ? `<p class="note">${esc(note)}</p>` : ""}<div class="box">${body}</div></section>`;
const LIMITS = { waterMinutes: [15, 180], restMinutes: [30, 240] };

function renderSettings() {
  const show = S.tab === "settings";
  $("settings").hidden = !show;
  if (!show || !S.coach) return;
  if (!draft) draft = JSON.parse(JSON.stringify(S.coach.config));
  const p = S.prefs;
  $("settings").innerHTML = `<div class="inner"><h1>Settings</h1>
    ${section("Your day", "Work time, reminders and the evening time check use these hours.",
      timeRow("start", "Day starts") + timeRow("end", "Day ends") +
      timeRow("checkFrom", "Time check for new tasks from", "After this time, Claude checks if a new task fits before the day ends, and asks you first if it does not.") +
      timeRow("lunchStart", "Lunch starts") + timeRow("lunchEnd", "Lunch ends") +
      `<div><div class="k" style="margin-bottom:6px">Workdays</div><div class="days">${DAYS.map(([n, l]) =>
        `<button class="cbtn${draft.workdays.includes(n) ? " filled" : ""}" data-day="${n}">${l}</button>`).join("")}</div></div>`)}
    ${section("Reminders", "Counted in work time: while you use the keyboard or mouse. Five minutes with no input is a break.",
      stepRow("waterMinutes", "Water every") +
      stepRow("restMinutes", "Rest after", "Five minutes away from the keyboard and mouse count as a break and start this again.") +
      toggle("coachSound", "Soft sound when a reminder comes", p.coachSound) +
      toggle("dayOff", "Day off today (no reminders, no time check)", S.coach.dayOff))}
    <div class="actions"><button class="cbtn filled save" data-save>${savedFlash ? "Saved" : "Save day settings"}</button>
      <button class="cbtn undo" data-undo>Undo changes</button></div>
    ${section("Claude alerts", "When a tab needs you or finishes.",
      toggle("soundOnNeeds", "Sound when a tab needs you", p.soundOnNeeds) +
      toggle("bannerOnNeeds", "Windows banner when a tab needs you", p.bannerOnNeeds) +
      toggle("soundOnDone", "Sound when a task is done", p.soundOnDone))}
    ${section("Window", "", toggle("keepOnTop", "Keep the reader on top of all apps", p.keepOnTop))}
  </div>`;
}

function render() { renderSide(); renderSettings(); }

document.addEventListener("click", (e) => {
  const t = e.target;
  const tabB = t.closest("[data-tab]");
  if (tabB) { if (tabB.dataset.tab === "settings") draft = null; return stack.send("tab", tabB.dataset.tab); }
  if (t.closest("#pin")) return stack.send("pref", { key: "keepOnTop", value: !S.prefs.keepOnTop });
  const coach = t.closest("[data-coach]");
  if (coach) return stack.send("coach", { action: coach.dataset.coach });
  const row = t.closest(".row");
  if (row) return stack.send("select", row.dataset.id);
  const day = t.closest("[data-day]");
  if (day) {
    const n = Number(day.dataset.day);
    draft.workdays = draft.workdays.includes(n) ? draft.workdays.filter((d) => d !== n) : draft.workdays.concat([n]);
    return renderSettings();
  }
  const step = t.closest("[data-step]");
  if (step) {
    const k = step.dataset.step, [lo, hi] = LIMITS[k];
    draft[k] = Math.min(hi, Math.max(lo, draft[k] + Number(step.dataset.d)));
    return renderSettings();
  }
  const tg = t.closest("[data-toggle]");
  if (tg) {
    const k = tg.dataset.toggle;
    if (k === "dayOff") return stack.send("coach", { action: "dayOff", on: !S.coach.dayOff });
    return stack.send("pref", { key: k, value: !S.prefs[k] });
  }
  if (t.closest("[data-save]")) {
    stack.send("coach", { action: "save", config: draft });
    savedFlash = true;
    renderSettings();
    setTimeout(() => { savedFlash = false; renderSettings(); }, 1500);
    return;
  }
  if (t.closest("[data-undo]")) { draft = JSON.parse(JSON.stringify(S.coach.config)); return renderSettings(); }
});
document.addEventListener("change", (e) => {
  const k = e.target.dataset && e.target.dataset.time;
  if (k && /^\d\d:\d\d$/.test(e.target.value)) draft[k] = e.target.value;
});

stack.on((ch, m) => {
  if (ch === "state") { S = m; render(); }
  else if (ch === "rows") { S.rows = m; renderSide(); }
  else if (ch === "coach") {
    S.coach = m;
    renderSide();
    // Do not redraw the form while you type in it; only fill it the first time.
    if (S.tab === "settings" && !document.querySelector("#settings .inner")) renderSettings();
    else if (S.tab === "settings") {
      const t = document.querySelector('[data-toggle="dayOff"]');
      if (t) t.classList.toggle("on", !!m.dayOff);
    }
  }
  else if (ch === "selected") { S.selected = m; renderSide(); }
  else if (ch === "tab") { S.tab = m; render(); }
  else if (ch === "prefs") { S.prefs = m; renderSide(); if (S.tab === "settings") renderSettings(); }
});
setInterval(() => tickAgo($("rows")), 1000);
stack.send("hello");
