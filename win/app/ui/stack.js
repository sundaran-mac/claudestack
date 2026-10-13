// The small stack: header, day strip, reminder, and one row per session. Port of StackView (Views.swift).
"use strict";
let S = { rows: [], coach: null, prefs: {} };
const box = document.getElementById("box");

function render() {
  const rows = S.rows || [];
  const compact = !!S.prefs.compact;
  const needCount = rows.filter((r) => r.display === "needs").length;
  box.className = (compact ? "compact" : "") + (needCount ? " needs" : "");
  let head = `<div class="head" title="Drag to move. Double-click to shrink or grow."><span class="logo">${ICON.stack}</span><span class="name">Claude</span>`;
  if (compact) {
    for (const d of ORDER) {
      const n = rows.filter((r) => r.display === d).length;
      if (n) head += `<span class="pill d-${d}" style="--c:${COLORS[d]}">${ICON[d]}<span class="mono">${n}</span></span>`;
    }
  } else {
    head += `<span class="spacer"></span>`;
    head += needCount
      ? `<span class="count needs">${needCount} need${needCount === 1 ? "s" : ""} you</span>`
      : `<span class="count">${rows.length} session${rows.length === 1 ? "" : "s"}</span>`;
    head += `<button class="open" data-open title="Open the reader">${ICON.expand}</button>`;
  }
  head += `</div>`;
  let body = "";
  if (!compact) {
    if (S.coach && S.coach.phase !== "off") body += stripHTML(S.coach, true);
    body += reminderHTML(S.coach);
    body += `<div class="rows">${rows.map((r) => rowHTML(r, { expand: true })).join("")}</div>`;
  }
  box.innerHTML = head + body;
}

// The window follows the size of the box.
new ResizeObserver(() => {
  const r = document.getElementById("wrap").getBoundingClientRect();
  stack.send("size", { w: r.width, h: r.height });
}).observe(document.getElementById("wrap"));

// Drag anywhere to move. The app follows the real cursor while the button is down (page mouse
// events stop as soon as the window moves under them). A move of 3 px or more is a drag; less is
// a click, handled here on release, because the pointer is captured to the box.
let press = null, lastHeadUp = 0;
box.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  press = { x: e.screenX, y: e.screenY, target: e.target };
  box.setPointerCapture(e.pointerId);
  stack.send("drag", { phase: "start" });
});
function release(e, cancelled) {
  if (!press) return;
  const p = press;
  press = null;
  stack.send("drag", { phase: "end" });
  if (cancelled || Math.hypot(e.screenX - p.x, e.screenY - p.y) >= 3) return;
  const t = p.target;
  const coach = t.closest("[data-coach]");
  if (coach) return stack.send("coach", { action: coach.dataset.coach });
  const exp = t.closest("[data-expand]");
  if (exp) return stack.send("openReader", exp.dataset.expand);
  if (t.closest("[data-open]")) return stack.send("openReader", null);
  if (t.closest(".head")) {
    // Double-click the title to switch between the full stack and the pill.
    if (e.timeStamp - lastHeadUp < 400) { lastHeadUp = 0; return stack.send("toggleCompact"); }
    lastHeadUp = e.timeStamp;
    return;
  }
  const row = t.closest(".row");
  if (row) return stack.send("focus", row.dataset.id);
}
box.addEventListener("pointerup", (e) => release(e, false));
box.addEventListener("pointercancel", (e) => release(e, true));
box.addEventListener("lostpointercapture", (e) => release(e, false));
document.addEventListener("contextmenu", (e) => { e.preventDefault(); stack.send("menu"); });

stack.on((ch, m) => {
  if (ch === "state") { S = m; render(); }
  else if (ch === "rows") { S.rows = m; render(); }
  else if (ch === "coach") { S.coach = m; render(); }
  else if (ch === "prefs") { S.prefs = m; render(); }
  else if (ch === "play") { new Audio(m).play().catch(() => {}); }
});
setInterval(() => tickAgo(box), 1000);
stack.send("hello");
