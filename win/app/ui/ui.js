// Shared parts of the small stack and the reader sidebar: icons, a session row, the day strip and the
// reminder card. Port of RowView (Views.swift) and DayStrip, Gauge, ReminderCard (DayViews.swift).
"use strict";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const svg = (d, vb = "0 0 24 24") => `<svg class="i" viewBox="${vb}" aria-hidden="true">${d}</svg>`;
const ICON = {
  needs: svg('<path d="M10.5 3a1.5 1.5 0 0 1 3 0v7h1V4.5a1.5 1.5 0 0 1 3 0V11h1V7.5a1.5 1.5 0 0 1 3 0V15a7 7 0 0 1-7 7h-1.2a7 7 0 0 1-5.6-2.8L2.6 14.4a1.5 1.5 0 0 1 2.3-1.9L7.5 15V5.5a1.5 1.5 0 0 1 3 0V10h0z"/>'),
  running: svg('<path d="M6 2h12v2h-1v3.2a5 5 0 0 1-2.3 4.2L13.2 12l1.5.6A5 5 0 0 1 17 16.8V20h1v2H6v-2h1v-3.2a5 5 0 0 1 2.3-4.2l1.5-.6-1.5-.6A5 5 0 0 1 7 7.2V4H6zm3 2v3.2c0 .6.2 1.2.6 1.6h4.8c.4-.4.6-1 .6-1.6V4zm3 9.6-1.7.8A3 3 0 0 0 9 16.8V20h6v-3.2a3 3 0 0 0-1.3-2.4z"/>'),
  stuck: svg('<path d="M12 2.5c.6 0 1.1.3 1.4.8l9.2 16a1.6 1.6 0 0 1-1.4 2.4H2.8a1.6 1.6 0 0 1-1.4-2.4l9.2-16c.3-.5.8-.8 1.4-.8zM11 9v5.5h2V9zm1 7.3a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z"/>'),
  done: svg('<path d="M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20zm4.3 6.3L10.5 14l-2.8-2.8-1.4 1.4 4.2 4.2 7.2-7.1z"/>'),
  ready: svg('<path d="M12 2.5a9.5 9.5 0 1 1 0 19 9.5 9.5 0 0 1 0-19zm0 2.2a7.3 7.3 0 1 0 0 14.6 7.3 7.3 0 0 0 0-14.6z"/>'),
  idle: svg('<path d="M10 3a8 8 0 0 0 9.8 10.4A8.5 8.5 0 1 1 10 3z"/><path d="M15 3h5v1.3L17 7.5h3V9h-5V7.7L18 4.5h-3z"/>'),
  stack: svg('<path d="M12 2 2 7l10 5 10-5zM4.2 10.9 2 12l10 5 10-5-2.2-1.1L12 14.8zm0 5L2 17l10 5 10-5-2.2-1.1L12 19.8z"/>'),
  expand: svg('<path d="M4 4h7v2H7.4l4.3 4.3-1.4 1.4L6 7.4V11H4zm16 16h-7v-2h3.6l-4.3-4.3 1.4-1.4 4.3 4.3V13h2z"/>'),
  chat: svg('<path d="M4 3h16a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H9l-5 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zm3 5v2h10V8zm0 4v2h7v-2z"/>'),
  drop: svg('<path d="M12 2s7 7.6 7 12.5a7 7 0 0 1-14 0C5 9.6 12 2 12 2z"/>'),
  walk: svg('<path d="M13.5 5.5a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM9.8 8.9 7 23h2.1l1.8-8 2.1 2v6h2v-7.5l-2.1-2 .6-3A7.3 7.3 0 0 0 19 13v-2a5 5 0 0 1-4.3-2.4l-1-1.6A2 2 0 0 0 12 6c-.3 0-.5 0-.8.1L6 8.3V13h2V9.6z"/>'),
  fork: svg('<path d="M7 2v7a2 2 0 0 1-1 1.7V22H4V10.7A2 2 0 0 1 3 9V2h1.3v5h1V2h1.4v5h1V2zm9 0c2.2 0 4 2.7 4 6.5 0 2.3-1 4.3-2.5 5.1V22h-2v-8.4C14 12.8 13 10.8 13 8.5 13 4.7 14.4 2 16 2z"/>'),
  moonStars: svg('<path d="M10 3a8 8 0 0 0 9.8 10.4A8.5 8.5 0 1 1 10 3z"/><path d="M17 2l.7 1.6L19.3 4l-1.6.7L17 6.3l-.7-1.6L14.7 4l1.6-.4zM20.5 7.5l.5 1 1 .5-1 .5-.5 1-.5-1-1-.5 1-.5z"/>'),
  check: svg('<path d="M9.5 16.6 4.9 12l-1.4 1.4 6 6L21 7.9l-1.4-1.4z"/>'),
  pin: svg('<path d="M14.5 2.5 21.5 9.5l-1.4 1.4-1.1-1.1-3.6 3.6.4 4.4-1.4 1.4-4.3-4.3L5 19.9 4.1 19l4.9-5.1-4.3-4.3L6.1 8.2l4.4.4 3.6-3.6L13 3.9zm-.1 4-4 4-2.6-.2 5.8 5.8-.2-2.6 4-4z"/>'),
  pinOn: svg('<path d="M14.5 2.5 21.5 9.5l-1.4 1.4-1.1-1.1-3.6 3.6.4 4.4-1.4 1.4-4.3-4.3L5 19.9 4.1 19l4.9-5.1-4.3-4.3L6.1 8.2l4.4.4 3.6-3.6L13 3.9z"/>'),
};

const ORDER = ["needs", "running", "stuck", "done", "ready", "idle"];
const COLORS = { needs: "#FF9A00", running: "#5B9BE6", stuck: "#F4A500", done: "#06C27A", ready: "#5FA889", idle: "#8A9BAE" };

function ago(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
}
function hm(secs) {
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}
const nowSecs = () => Date.now() / 1000;

/// Times move every second without redrawing the rows.
function tickAgo(root) {
  for (const el of root.querySelectorAll("[data-since]")) el.textContent = ago(nowSecs() - Number(el.dataset.since));
}

function rowHTML(r, { selected = false, expand = false } = {}) {
  const sub = r.prompt || (r.display === "ready" ? "Waiting for your first message" : r.cwd);
  const help = expand ? "Click to open this tab" : "Click to read this chat";
  return `<div class="row d-${r.display}${selected ? " selected" : ""}" data-id="${esc(r.id)}" style="--c:${COLORS[r.display]}" title="${help}">
    <div class="ic">${ICON[r.display]}</div>
    <div class="mid">
      <div class="l1"><span class="title">${esc(r.title)}</span>${r.background ? '<span class="bg">BG</span>' : ""}${r.branch ? `<span class="branch mono">${esc(r.branch)}</span>` : ""}</div>
      <div class="l2">${r.agents > 0 ? `<span class="agents" title="Subagents working right now">${r.agents} agent${r.agents === 1 ? "" : "s"}</span>` : ""}<span class="sub">${esc(sub)}</span></div>
    </div>
    ${expand ? `<button class="expand" data-expand="${esc(r.id)}" title="Read this chat">${ICON.chat}</button>` : ""}
    <div class="right"><div class="detail">${esc(r.detail)}</div><div class="ago mono" data-since="${r.since}">${ago(nowSecs() - r.since)}</div></div>
  </div>`;
}

function gauge(icon, color, value, help) {
  const c = 2 * Math.PI * 8.75;
  const v = Math.max(0.02, Math.min(1, value || 0));
  return `<div class="gauge" style="--gc:${color}" title="${esc(help)}">
    <svg class="ring" viewBox="0 0 20 20"><circle class="track" cx="10" cy="10" r="8.75"/><circle class="val" cx="10" cy="10" r="8.75" stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - v)}"/></svg>
    ${ICON[icon]}
  </div>`;
}

/// Day progress plus the water and rest gauges.
function stripHTML(coach, compact = false) {
  if (!coach) return "";
  const s = coach.summary, cfg = coach.config;
  let label;
  switch (coach.phase) {
    case "off": label = `Day off · ${hm(s.workSecs)} worked`; break;
    case "before": label = `Day starts at ${esc(cfg.start)}`; break;
    case "done": label = `Day complete · ${hm(s.workSecs)} worked`; break;
    default: label = `${hm(s.workSecs)} worked · ${hm(coach.minutesLeft * 60)} left`;
  }
  return `<div class="strip p-${coach.phase}${compact ? " compact" : ""}" title="Your day ${esc(cfg.start)} to ${esc(cfg.end)}">
    <div class="top"><span class="label">${label}</span>
      ${gauge("drop", "#4FC3F7", coach.waterFraction, "Water: fills up to the next reminder")}
      ${gauge("walk", "#06C27A", coach.restFraction, "Rest: fills up to the next break")}
    </div>
    <div class="bar"><span style="width:${(coach.dayFraction * 100).toFixed(2)}%"></span></div>
  </div>`;
}

const REMINDER = {
  water: { color: "#4FC3F7", title: () => "Time for water", body: (c) => `You worked ${c.config.waterMinutes} minutes. Drink a glass of water.`, done: "I drank water" },
  rest: { color: "#06C27A", title: () => "Time to rest", body: () => "Two hours without a break. Stand up, walk, and look away from the screen for 5 minutes.", done: "I took a break" },
  lunch: { color: "#06C27A", title: () => "Lunch time", body: (c) => `Step away until ${esc(c.config.lunchEnd)}. Claude can wait.`, done: "Back from lunch" },
  windDown: { color: "#F4A500", title: (r) => `${r.minutesLeft} minutes left today`, body: () => "Finish what you have. New tasks now get a time check from Claude before they start.", done: "OK" },
  dayDone: { color: "#06C27A", title: () => "Day complete. Well done.", body: () => "Here is today. Save your work and stop for the day.", done: "Close for today" },
  overtime: { color: "#F4A500", title: (r) => `${r.minutes} minutes past your day`, body: () => "Save your work and leave the rest for tomorrow.", done: "OK" },
};

function artHTML(r) {
  switch (r.kind) {
    case "water":
      // A drop that fills and settles with a slow wave.
      return `<svg viewBox="0 0 24 24"><defs><clipPath id="dropclip"><path d="M12 2s7 7.6 7 12.5a7 7 0 0 1-14 0C5 9.6 12 2 12 2z"/></clipPath></defs>
        <path d="M12 2s7 7.6 7 12.5a7 7 0 0 1-14 0C5 9.6 12 2 12 2z" fill="currentColor" opacity="0.18"/>
        <g clip-path="url(#dropclip)"><g class="level"><path class="wave" fill="currentColor"
          d="M0 11 q3 -1.5 6 0 t6 0 t6 0 t6 0 t6 0 t6 0 t6 0 V30 H0z"/></g></g></svg>`;
    case "rest": case "lunch":
      // A breathing circle: four seconds in, four seconds out.
      return `<div class="breath"></div><div class="center">${r.kind === "lunch" ? ICON.fork : ICON.walk}</div>`;
    case "windDown": {
      const c = 2 * Math.PI * 18, v = Math.min(1, r.minutesLeft / 30);
      return `<svg viewBox="0 0 44 44" style="transform:rotate(-90deg)"><circle cx="22" cy="22" r="18" fill="none" stroke="currentColor" stroke-width="4" opacity="0.2"/>
        <circle cx="22" cy="22" r="18" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - v)}"/></svg>
        <div class="center num">${r.minutesLeft}</div>`;
    }
    case "dayDone":
      // A ring that draws itself, then a soft glow.
      return `<div class="breath" style="animation-duration:6.6s"></div><svg viewBox="0 0 44 44" style="position:absolute;inset:0;transform:rotate(-90deg)">
        <circle class="draw" cx="22" cy="22" r="20" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round"/></svg>
        <div class="center tick">${ICON.check}</div>`;
    case "overtime":
      return `<div class="center soft" style="font-size:22px">${ICON.moonStars}</div>`;
  }
  return "";
}

/// The one reminder that is due now. Calm colours and slow motion: orange blinking stays for "Claude needs you".
function reminderHTML(coach) {
  const r = coach && coach.reminder;
  if (!r) return "";
  const m = REMINDER[r.kind];
  const s = coach.summary;
  const grid = r.kind === "dayDone" ? `<div class="grid">${[["Worked", hm(s.workSecs)], ["Prompts", s.prompts], ["Tasks done", s.tasksDone],
    ["Agents", s.agents], ["Water", s.water], ["Breaks", s.breaks]].map(([k, v]) => `<div><b>${v}</b><span>${k}</span></div>`).join("")}</div>` : "";
  return `<div class="card" style="--rc:${m.color}">
    <div class="head"><div class="art">${artHTML(r)}</div>
      <div class="words"><div class="t">${esc(m.title(r))}</div><div class="b">${m.body(coach)}</div></div></div>
    ${grid}
    <div class="btns"><button class="cbtn filled" style="--bc:${m.color}" data-coach="done">${m.done}</button>
      ${r.kind !== "dayDone" ? `<button class="cbtn" style="--bc:${m.color}" data-coach="later">10 min later</button>` : ""}</div>
  </div>`;
}
