// Claude Stack reader page. Swift calls CS.* and the page answers through post().
"use strict";

const $ = (id) => document.getElementById(id);
const post = (msg) => {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cs;
  if (h) h.postMessage(msg);
};
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---------- Markdown ----------
// Raw HTML in an answer is shown as text, never run. The page can type into terminals,
// so nothing from a transcript may become live markup.
marked.use({
  gfm: true,
  breaks: true, // the terminal keeps every line break, so the reader does too
  renderer: {
    html(token) { return esc(token.text); },
    code(token) {
      const lang = (token.lang || "").trim().split(/\s+/)[0];
      // A ```message block is text to send to a person: a card, filled in by renderMd.
      if (lang === "message") {
        cards.push(token.text);
        return `<div class="msgcard" data-card="${cards.length - 1}"></div>`;
      }
      // A ```timecheck block is the day coach's answer: does this task fit before the day ends?
      if (lang === "timecheck") {
        const card = timecheckCard(token.text);
        if (card) return card;
      }
      let body;
      try {
        if (lang && hljs.getLanguage(lang)) body = hljs.highlight(token.text, { language: lang }).value;
        else if (token.text.length < 4000) body = hljs.highlightAuto(token.text).value;
        else body = esc(token.text);
      } catch (e) { body = esc(token.text); }
      return `<div class="code"><div class="code-head"><span>${esc(lang || "code")}</span>` +
        `<button class="copy" data-copy="code">Copy</button></div><pre><code class="hljs">${body}</code></pre></div>`;
    },
    link(token) {
      const text = this.parser.parseInline(token.tokens);
      const href = String(token.href || "");
      if (!/^https?:\/\//i.test(href)) return text;
      return `<a href="${esc(href)}" title="${esc(token.title || href)}">${text}</a>`;
    },
    image(token) {
      return esc(token.text || "image");
    },
  },
});

// The page's security rule (style-src 'self') ignores style="..." in HTML, so generated HTML
// carries data-style instead, and this watcher applies it through the DOM, which is allowed.
function applyStyles(root) {
  if (root.dataset && root.dataset.style) root.style.cssText = root.dataset.style;
  root.querySelectorAll && root.querySelectorAll("[data-style]").forEach((el) => { el.style.cssText = el.dataset.style; });
}
new MutationObserver((list) => {
  for (const m of list) m.addedNodes.forEach((n) => { if (n.nodeType === 1) applyStyles(n); });
}).observe(document.body, { childList: true, subtree: true });

let cards = [];

function timecheckCard(text) {
  let t;
  try { t = JSON.parse(text); } catch (e) { return null; }
  const need = Math.max(1, +t.minutes || 0), left = Math.max(0, +t.left || 0);
  const fits = !!t.fits;
  // The ring shows the estimate as a share of the time left (full ring = all of it, or more).
  const share = left ? Math.min(1, need / left) : 1;
  const r = 26, len = 2 * Math.PI * r;
  const title = fits
    ? `Fits: about ${need} min of the ${left} min left`
    : left ? `Does not fit: needs about ${need} min, ${left} min left` : `Your day is over: this needs about ${need} min`;
  const row = (k, v) => v ? `<div class="tc-row"><span class="tc-k">${k}</span><span>${esc(v)}</span></div>` : "";
  return `<div class="timecheck ${fits ? "fits" : "nofit"}">` +
    `<svg class="tc-ring" viewBox="0 0 64 64"><circle class="tc-bg" cx="32" cy="32" r="${r}"/>` +
    `<circle class="tc-fg" cx="32" cy="32" r="${r}" data-style="--len:${len.toFixed(1)};--off:${(len * (1 - share)).toFixed(1)}"/>` +
    `<text x="32" y="36" text-anchor="middle">${need}m</text></svg>` +
    `<div class="tc-body"><div class="tc-label">End-of-day time check</div><div class="tc-title">${esc(title)}</div>` +
    row("Now", t.now) + row("Tomorrow", t.later) + `</div></div>`;
}

function copyButton(kind, label) {
  const b = document.createElement("button");
  b.className = "copy " + kind;
  b.dataset.copy = kind;
  b.textContent = label || "Copy";
  return b;
}

function renderMd(text) {
  const div = document.createElement("div");
  div.className = "md";
  const outer = cards;
  cards = [];
  div.innerHTML = marked.parse(text || "");
  const mine = cards;
  cards = outer;
  div.querySelectorAll(".msgcard[data-card]").forEach((c) => {
    const head = document.createElement("div");
    head.className = "mc-head";
    head.innerHTML = `<span class="mc-title">Ready to send</span>`;
    head.appendChild(copyButton("card", "Copy message"));
    const body = renderMd(mine[+c.dataset.card] || "");
    body.classList.add("mc-body");
    c.removeAttribute("data-card");
    c.append(head, body);
  });
  div.querySelectorAll("table").forEach((t) => {
    const w = document.createElement("div");
    w.className = "table-wrap";
    t.replaceWith(w);
    w.appendChild(t);
    w.appendChild(copyButton("block corner"));
  });
  div.querySelectorAll("blockquote").forEach((q) => {
    if (q.closest(".msgcard")) return;
    q.appendChild(copyButton("block corner"));
  });
  return div;
}

/// Rich copy: HTML keeps bold and lists in Teams or Outlook, plain text for everything else.
function richCopy(el) {
  const clone = el.cloneNode(true);
  clone.querySelectorAll("button").forEach((b) => b.remove());
  const plain = (clone.innerText || clone.textContent || "").replace(/\n{3,}/g, "\n\n").trim();
  return { text: plain, html: clone.innerHTML };
}

// ---------- State ----------
let sid = null;
let state = {};
let commands = [];
const rendered = new Map(); // item id -> { v, el, item }
let lastPendingKey = "";
const drafts = {};
let sending = false;

const chat = $("chat"), scroller = $("scroll"), input = $("input");

window.CS = {
  reset({ sid: id }) {
    sid = id;
    rendered.clear();
    chat.innerHTML = "";
    lastPendingKey = "";
    setStick(true);
    $("pending").hidden = true;
    $("more").hidden = true;
    $("live").hidden = true; liveNow = ""; liveDrawn = "";
    agents = []; viewAgent = ""; showDone = false; mapKey = ""; centerLeadSoon();
    if (mode === "agents") drawMap();
    $("agents").hidden = true;
    $("viewbar").hidden = true;
    $("empty").hidden = true;
    input.value = drafts[id] || "";
    autosize();
    closeSlash();
    first = true;
  },

  setItems({ sid: id, items, hasMore }) {
    if (id !== sid) return;
    const atBottom = stick;
    const oldTop = chat.firstElementChild;
    const oldOffset = oldTop ? oldTop.getBoundingClientRect().top : 0;
    const keep = new Set(items.map((i) => i.id));
    for (const [k, r] of rendered) if (!keep.has(k)) { r.el.remove(); rendered.delete(k); }
    let prev = null;
    let prepended = false;
    for (const it of items) {
      let r = rendered.get(it.id);
      if (!r) {
        const el = build(it);
        if (prev) prev.after(el); else { chat.prepend(el); prepended = oldTop != null; }
        r = { v: it.v, el, item: it };
        rendered.set(it.id, r);
      } else if (r.v !== it.v) {
        const open = openKeys(r.el);
        const el = build(it);
        reopen(el, open);
        r.el.replaceWith(el);
        r.el = el; r.v = it.v; r.item = it;
      }
      prev = r.el;
    }
    $("more").hidden = !hasMore;
    $("empty").hidden = items.length > 0;
    updateAgentChips();
    // The message may have reached the transcript: the live copy then steps aside.
    if (liveNow) drawLive();
    if (first || atBottom) toBottom();
    else if (prepended && oldTop) scroller.scrollTop += oldTop.getBoundingClientRect().top - oldOffset;
    first = false;
  },

  setState(st) {
    if (st.sid !== sid) {
      // A voice try from the old chat must not block the new one or land in its box.
      if (voiceOn) {
        post({ type: "voice", on: false, cancel: true, sid });
        voiceOn = false;
        voiceBase = null;
        $("voice").hidden = true;
      }
      sid = st.sid;
    }
    state = st;
    document.documentElement.style.setProperty("--fs", (st.fontSize || 15) + "px");
    $("project").textContent = st.project || "Claude";
    $("branch").textContent = st.branch || "";
    $("status").textContent = st.display || "";
    $("status").style.color = st.color || "";
    $("dot").style.background = st.color || "";
    $("target").innerHTML = st.canSend
      ? `Sending to: <b>${esc(st.project)}</b>${st.branch ? " · " + esc(st.branch) : ""}`
      : "";
    $("blocked").hidden = !!st.canSend;
    $("blocked").textContent = st.block || "";
    input.disabled = !st.canSend;
    $("send").disabled = !st.canSend || sending;
    $("stop").hidden = !(st.canSend && st.running);
    const w = $("working");
    const atBottom = stick;
    w.hidden = !st.running;
    if (st.running) {
      $("working-text").textContent = st.tool
        ? `Claude is working · ${st.tool}${st.detail ? ": " + st.detail : ""}`
        : "Claude is working";
    }
    renderPending(st.pending);
    if (atBottom) toBottom();
  },

  setCommands(list) { commands = list || []; },

  sent({ ok, error, quiet }) {
    sending = false;
    $("send").disabled = !state.canSend;
    if (!ok) return toast(error || "Not sent", false);
    if (!quiet) {
      input.value = "";
      drafts[sid] = "";
      autosize();
      toast(state.running ? "Queued. Claude reads it after the current step." : "Sent", true);
    } else toast("Sent", true);
  },

  // Voice runs in the tab through Claude Code's own voice mode. States: listening, writing, done.
  voice({ state, text, error }) {
    if (state === "listening") {
      $("voice-text").textContent = "Listening in the tab (Claude Code voice)... let go of space to stop";
      // The words so far, shown in the box as you speak. The final words replace them on release.
      if (text && voiceBase) showVoiceWords(text);
      return;
    }
    if (state === "writing") { $("voice-text").textContent = "Claude Code is writing your words..."; return; }
    voiceOn = false;
    $("voice").hidden = true;
    if (error) {
      // Take back any words shown while you spoke: the box goes back to what you had typed.
      if (voiceBase) { input.value = voiceBase.before + voiceBase.after; drafts[sid] = input.value; autosize(); }
      voiceBase = null;
      return toast(error, false);
    }
    if (voiceBase && text) {
      const join = voiceBase.before && !/\s$/.test(voiceBase.before) ? " " : "";
      input.value = voiceBase.before + join + text + voiceBase.after;
      const pos = (voiceBase.before + join + text).length;
      input.focus();
      input.setSelectionRange(pos, pos);
      drafts[sid] = input.value;
      autosize();
    }
    voiceBase = null;
  },

  paste(text) { insertText(text); },

  // The answer Claude is writing now, read from the tab's screen. Plain text, a preview only:
  // the formatted bubble takes its place when the message reaches the transcript.
  live({ sid: id, text }) {
    if (id !== sid) return;
    liveNow = text || "";
    drawLive();
  },

  setAgents({ sid: id, agents: list }) {
    if (id !== sid) return;
    agents = list || [];
    if (mode === "agents") drawMap();
    const key = JSON.stringify(agents.map((a) => [a.id, a.status, a.tool, a.detail, a.steps])) + viewAgent + showDone + agentsOpen;
    if (key === agentsKey) {
      // Only the timers moved: change those numbers in place, no redraw.
      for (const a of agents) {
        const m = document.querySelector(`.agent[data-agent="${CSS.escape(a.id)}"] .ameta`);
        if (m) m.textContent = `${a.steps} step${a.steps === 1 ? "" : "s"} · ${dur(a.secs)}`;
      }
      return;
    }
    agentsKey = key;
    drawAgents();
    updateAgentChips();
  },

  // The reader's tab: "chats" shows the chat, "agents" shows the map and the timeline.
  mode(m) {
    mode = m === "agents" ? "agents" : "chats";
    const a = mode === "agents";
    $("agentsview").hidden = !a;
    $("scroll").hidden = a;
    $("latest").hidden = a || stick;
    $("viewbar").hidden = a || !viewAgent;
    drawAgents();
    if (a) { mapKey = ""; centerLeadSoon(); drawMap(); } else if (stick) toBottom();
  },

  view({ agent, label }) {
    viewAgent = agent || "";
    $("live").hidden = true; liveNow = ""; liveDrawn = "";
    rendered.clear();
    chat.innerHTML = "";
    first = true;
    setStick(true);
    $("viewbar").hidden = !viewAgent;
    $("viewlabel").textContent = viewAgent ? "Agent chat: " + label : "";
    drawAgents();
  },
};
let first = true;

/// The live bubble: the answer Claude is writing, as the terminal shows it. Answer lines in the
/// normal font; table lines (box drawing) in a fixed-width block so the columns stay lined up.
/// Only what changed is redrawn, so the bubble grows in place and never jumps.
let liveNow = "", liveDrawn = "";
function drawLive() {
  const atBottom = stick;
  const show = !!liveNow && !viewAgent && !alreadyShown(liveNow);
  $("live").hidden = !show;
  if (show && liveNow !== liveDrawn) {
    liveDrawn = liveNow;
    const box = $("live-text");
    const parts = [];
    for (const line of liveNow.split("\n")) {
      const table = /^\s*[│┌└├┬┴┼─╭╰]/.test(line);
      const last = parts[parts.length - 1];
      if (last && last.table === table) last.lines.push(line); else parts.push({ table, lines: [line] });
    }
    // Reuse the blocks already on the page; change only the text that is new.
    while (box.children.length > parts.length) box.lastChild.remove();
    parts.forEach((p, i) => {
      let el = box.children[i];
      const cls = p.table ? "live-table" : "live-para";
      if (!el || el.className !== cls) {
        const fresh = document.createElement(p.table ? "pre" : "div");
        fresh.className = cls;
        if (el) el.replaceWith(fresh); else box.appendChild(fresh);
        el = fresh;
      }
      const t = p.lines.join("\n");
      if (el.textContent !== t) el.textContent = t;
    });
  }
  if (!show) liveDrawn = "";
  if (atBottom) toBottom();
}

/// Puts the words heard so far into the box, between what was before and after the cursor.
function showVoiceWords(text) {
  const join = voiceBase.before && !/\s$/.test(voiceBase.before) ? " " : "";
  input.value = voiceBase.before + join + text + voiceBase.after;
  autosize();
}

/// True when the newest Claude bubble already holds this text, so the live preview would repeat it.
/// Compared on letters and digits only: the screen drops markdown marks and wraps lines.
const norm = (t) => String(t || "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
function alreadyShown(text) {
  const want = norm(text).slice(0, 80);
  if (!want) return true;
  const mine = [...chat.querySelectorAll(".msg.assistant")].slice(-2).map((el) => rendered.get(el.dataset.id)).filter(Boolean);
  return mine.some((r) => r.item.blocks.some((b) => b.type === "text" && norm(b.text).includes(want)));
}

// Follow new messages only while you are at the bottom. Any scroll up stops following at
// once, even a small one; scrolling back to the very bottom starts it again. Updates arrive
// every half second, so a loose "near the bottom" test pulled the view back while you read.
let stick = true;
const atEnd = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 4;
function setStick(v) { stick = v; $("latest").hidden = v; }
scroller.addEventListener("wheel", (e) => { if (e.deltaY < 0) setStick(false); }, { passive: true });
scroller.addEventListener("mousedown", (e) => {
  // A drag on the scroll bar.
  if (e.offsetX > scroller.clientWidth) setStick(false);
});
document.addEventListener("keydown", (e) => {
  if (document.activeElement !== input && ["ArrowUp", "PageUp", "Home"].includes(e.key)) setStick(false);
});
scroller.addEventListener("scroll", () => { if (atEnd()) setStick(true); }, { passive: true });
new ResizeObserver(() => { if (stick) toBottom(); }).observe(scroller);
function toBottom() { scroller.scrollTop = scroller.scrollHeight; }
$("latest").onclick = () => { setStick(true); toBottom(); };

function openKeys(el) {
  return new Set([...el.querySelectorAll("details[open]")].map((d) => d.dataset.key));
}
function reopen(el, keys) {
  el.querySelectorAll("details").forEach((d) => { if (keys.has(d.dataset.key)) d.open = true; });
}

// ---------- Building one item ----------
function build(it) {
  const el = document.createElement("div");
  el.className = "msg " + it.role;
  el.dataset.id = it.id;
  const text = (it.blocks.find((b) => b.type === "text") || {}).text || "";
  if (it.role === "user") {
    const b = document.createElement("div");
    b.className = "bubble";
    b.textContent = text;
    el.appendChild(b);
  } else if (it.role === "command" || it.role === "note") {
    const c = document.createElement("span");
    c.className = "chip";
    c.textContent = text;
    el.appendChild(c);
  } else if (it.role === "output") {
    const p = document.createElement("pre");
    p.className = "plain";
    p.textContent = text;
    el.appendChild(p);
  } else {
    const role = document.createElement("div");
    role.className = "role";
    role.innerHTML = `<span>Claude</span><button class="copy copy-msg" data-copy="msg">Copy</button>`;
    el.appendChild(role);
    let group = [];
    let g = 0;
    const flush = () => {
      if (!group.length) return;
      el.appendChild(buildSteps(group, it.id + "-g" + g++));
      group = [];
    };
    for (const b of it.blocks) {
      if (b.type === "tool") { group.push(b); continue; }
      flush();
      el.appendChild(renderMd(b.text));
    }
    flush();
  }
  return el;
}

function buildSteps(tools, key) {
  const d = document.createElement("details");
  d.className = "steps";
  d.dataset.key = key;
  const names = [...new Set(tools.map((t) => t.name))].join(", ");
  const s = document.createElement("summary");
  s.innerHTML = `<span>${tools.length} step${tools.length === 1 ? "" : "s"}</span><span class="names">${esc(names)}</span>`;
  d.appendChild(s);
  for (const t of tools) {
    const st = document.createElement("details");
    st.className = "step" + (t.error ? " err" : "");
    st.dataset.key = t.id;
    const chip = t.agent ? `<span class="achip" data-tool="${esc(t.id)}"></span>` : "";
    st.innerHTML = `<summary><span class="tname">${esc(t.name)}</span>${chip}<span class="tdetail">${esc(t.detail || "")}</span></summary>`;
    const out = document.createElement("div");
    out.className = "out";
    const pre = document.createElement("pre");
    pre.className = "plain";
    pre.textContent = t.output != null ? (t.output || "(no output)") : "(still running)";
    out.appendChild(pre);
    st.appendChild(out);
    d.appendChild(st);
  }
  return d;
}

function messageText(el) {
  const r = rendered.get(el.dataset.id);
  if (!r) return "";
  return r.item.blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n\n");
}

// ---------- Clicks in the chat ----------
document.addEventListener("click", (e) => {
  const a = e.target.closest("a[href]");
  if (a) { e.preventDefault(); post({ type: "open", url: a.getAttribute("href") }); return; }
  const c = e.target.closest("[data-copy]");
  if (c) {
    const kind = c.dataset.copy;
    if (kind === "code") post({ type: "copy", text: c.closest(".code").querySelector("code").textContent });
    else if (kind === "msg") post({ type: "copy", text: messageText(c.closest(".msg")) });
    else if (kind === "card") post({ type: "copy", ...richCopy(c.closest(".msgcard").querySelector(".mc-body")) });
    else post({ type: "copy", ...richCopy(c.closest(".table-wrap, blockquote")) });
    const label = c.textContent;
    c.textContent = "Copied";
    c.classList.add("done");
    setTimeout(() => { c.textContent = label; c.classList.remove("done"); }, 1400);
  }
});

$("more").onclick = () => post({ type: "more" });
$("open-tab").onclick = () => post({ type: "focusTab" });
$("copy-last").onclick = () => {
  const items = [...rendered.values()].filter((r) => r.item.role === "assistant");
  const last = items[items.length - 1];
  if (!last) return toast("No answer yet", false);
  post({ type: "copy", text: messageText(last.el) });
  toast("Last answer copied", true);
};
function setFont(d) {
  const n = Math.max(12, Math.min(22, (state.fontSize || 15) + d));
  state.fontSize = n;
  document.documentElement.style.setProperty("--fs", n + "px");
  post({ type: "font", size: n });
}
$("font-down").onclick = () => setFont(-1);
$("font-up").onclick = () => setFont(1);

// ---------- Agents ----------
let agents = [], viewAgent = "", showDone = false, agentsOpen = true, agentsKey = "";
let mode = "chats", mapKey = "";
// Timeline range: "recent" shows the last 30 minutes, so a long chat does not squeeze new agents into dots.
let tlRange = "recent";
const AGENT_LABEL = { running: "Running", stuck: "Maybe stuck", done: "Done", failed: "Failed", stopped: "Stopped" };

function dur(s) {
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
  return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
}

function agentRow(a) {
  const step = a.status === "running" || a.status === "stuck"
    ? (a.tool ? `${a.tool}${a.detail ? ": " + a.detail : ""}` : "Starting...")
    : AGENT_LABEL[a.status] + (a.tool ? ` · last step ${a.tool}` : "");
  const pad = a.depth > 1 ? ` data-style="margin-left:${(a.depth - 1) * 18}px"` : "";
  return `<div class="agent st-${esc(a.status)}${a.id === viewAgent ? " on" : ""}" data-agent="${esc(a.id)}" data-label="${esc(a.desc)}"${pad} title="Click to read this agent's chat">` +
    `<span class="adot"></span><span class="atype">${esc(a.type)}</span><span class="adesc">${esc(a.desc)}</span>` +
    `<span class="ameta">${a.steps} step${a.steps === 1 ? "" : "s"} · ${dur(a.secs)}</span>` +
    `<span class="astep">${esc(step)}</span></div>`;
}

function drawAgents() {
  if (mode === "agents") { $("agents").hidden = true; return; }
  agentsKey = JSON.stringify(agents.map((a) => [a.id, a.status, a.tool, a.detail, a.steps])) + viewAgent + showDone + agentsOpen;
  const box = $("agents");
  if (!agents.length) { box.hidden = true; box.innerHTML = ""; return; }
  const live = agents.filter((a) => a.status === "running" || a.status === "stuck");
  const done = agents.filter((a) => !(a.status === "running" || a.status === "stuck"));
  let html = `<div class="ag-head${agentsOpen ? "" : " closed"}" data-toggle="1"><b>Agents</b>` +
    (live.length ? `<span class="run">${live.length} running</span>` : "") +
    (done.length ? `<span>${done.length} finished</span>` : "") +
    `<span class="ag-open" data-openmap="1">Open map</span></div>`;
  if (agentsOpen) {
    html += live.map(agentRow).join("");
    if (done.length) {
      // Always show the agent you are reading, even when finished ones are folded.
      const shown = showDone ? done : done.filter((a) => a.id === viewAgent);
      html += shown.map(agentRow).join("");
      html += `<button class="ag-more" data-done="1">${showDone ? "Hide finished agents" : `Show ${done.length} finished agent${done.length === 1 ? "" : "s"}`}</button>`;
    }
  }
  box.innerHTML = html;
  box.hidden = false;
}

function updateAgentChips() {
  const byTool = new Map(agents.map((a) => [a.toolUse, a]));
  chat.querySelectorAll(".achip").forEach((c) => {
    const a = byTool.get(c.dataset.tool);
    if (!a) { c.hidden = true; return; }
    c.hidden = false;
    c.className = "achip st-" + a.status;
    c.textContent = AGENT_LABEL[a.status] + " · open";
    c.dataset.agent = a.id;
    c.dataset.label = a.desc;
  });
}

// ---------- Agent map and timeline ----------
const TYPE_CLASS = (t) => ({ Plan: "t-plan", Explore: "t-explore", "general-purpose": "t-general" }[t] || "t-other");
const isLive = (a) => a.status === "running" || a.status === "stuck";

function ring(status) {
  const r = 9, c = 2 * Math.PI * r;
  const mark = { done: '<path d="M7 12.5l3.2 3 6.3-6.5"/>', failed: '<path d="M8.5 8.5l7 7M15.5 8.5l-7 7"/>',
                 stuck: '<path d="M12 7.5v5.5M12 16.2v.3"/>', stopped: '<path d="M9 12h6"/>' }[status] || "";
  return `<svg class="ring r-${status}" viewBox="0 0 24 24"><circle class="rb" cx="12" cy="12" r="${r}"/>` +
    `<circle class="rf" cx="12" cy="12" r="${r}" data-style="stroke-dasharray:${c.toFixed(1)};stroke-dashoffset:${(status === "running" ? c * 0.7 : 0).toFixed(1)}"/>${mark}</svg>`;
}

function card(a) {
  const step = isLive(a) ? (a.tool ? `${a.tool}${a.detail ? ": " + a.detail : ""}` : "Starting...") : (a.tool ? `Last step: ${a.tool}` : "");
  return `<div class="acard st-${esc(a.status)} ${TYPE_CLASS(a.type)}" data-agent="${esc(a.id)}" data-label="${esc(a.desc)}" title="Click to read this agent's chat">` +
    `<div class="ac-top">${ring(a.status)}<span class="ac-type">${esc(a.type)}</span><span class="ac-time" data-time="${esc(a.id)}">${dur(a.secs)}</span></div>` +
    `<div class="ac-desc">${esc(a.desc || "Agent")}</div>` +
    (step ? `<div class="ac-step">${esc(step)}</div>` : "") +
    `<div class="ac-meta"><span class="ac-steps" data-steps="${esc(a.id)}">${a.steps} step${a.steps === 1 ? "" : "s"}</span> · ${esc(AGENT_LABEL[a.status] || a.status)}</div></div>`;
}

function leadCard() {
  return `<div class="acard lead" id="am-lead"><div class="ac-top"><span class="lead-dot" data-style="background:${esc(state.color || "#8A9BAE")}"></span>` +
    `<span class="ac-type">Lead · your Claude tab</span></div><div class="ac-desc">${esc(state.project || "Claude")}</div>` +
    `<div class="ac-meta">${esc(state.branch || "")}${state.branch ? " · " : ""}${esc(state.display || "")}</div></div>`;
}

function drawMap() {
  const view = $("agentsview");
  const has = agents.length > 0;
  $("am-empty").hidden = has;
  view.querySelectorAll(".am-title, #am-mapwrap, #am-timeline, #am-summary").forEach((el) => { el.hidden = !has; });
  if (!has) {
    $("am-empty").innerHTML = `<div class="am-empty-title">No agents in this chat yet</div>` +
      `<div class="am-empty-sub">When Claude starts agents, they show up here live. This is how they work:</div>` +
      `<div class="how"><div><b>1</b>Your Claude tab is the <em>lead</em>. It splits the work and starts agents.</div>` +
      `<div><b>2</b>Each <em>agent</em> works alone, with its own chat and tools. It can start agents too.</div>` +
      `<div><b>3</b>When an agent is done, it <em>hands back</em> a short result and the lead continues.</div></div>`;
    return;
  }
  const key = JSON.stringify(agents.map((a) => [a.id, a.status, a.tool, a.detail, a.parent])) + state.display;
  if (key === mapKey) { tickMap(); return; }
  mapKey = key;

  // Summary
  const live = agents.filter(isLive).length, done = agents.filter((a) => a.status === "done").length;
  const bad = agents.length - live - done;
  const t0 = Math.min(...agents.map((a) => a.start)), t1 = Math.max(...agents.map((a) => a.end));
  const steps = agents.reduce((n, a) => n + a.steps, 0);
  // The most agents that ran at the same moment.
  const ev = agents.flatMap((a) => [[a.start, 1], [a.end, -1]]).sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  let cur = 0, peak = 0;
  for (const [, d] of ev) { cur += d; peak = Math.max(peak, cur); }
  const chip = (n, label, cls) => `<div class="sm ${cls}"><b>${n}</b><span>${label}</span></div>`;
  $("am-summary").innerHTML = chip(live, "running", "c-run") + chip(done, "done", "c-done") +
    (bad ? chip(bad, "failed or stopped", "c-bad") : "") + chip(steps, "steps", "") +
    chip(peak, "at the same time, at most", "") + chip(dur(Math.round(t1 - t0)), "from first start", "");

  // Map: the lead on top, each agent under the one that started it.
  const ids = new Set(agents.map((a) => a.id));
  const kids = {};
  for (const a of agents) {
    const p = a.parent && ids.has(a.parent) ? a.parent : "";
    (kids[p] = kids[p] || []).push(a);
  }
  const branch = (a) => `<div class="tnode">${card(a)}${(kids[a.id] || []).length ? `<div class="tkids">${kids[a.id].map(branch).join("")}</div>` : ""}</div>`;
  $("am-map").innerHTML = `<div class="tnode root">${leadCard()}<div class="tkids">${(kids[""] || []).map(branch).join("")}</div></div>`;
  // Always the top-down tree. A tree bigger than the box is zoomed out or scrolled, never folded.
  applyZoom();

  // Timeline: one bar per agent, oldest first. "Recent" zooms to the agents active in the last
  // 30 minutes: the axis starts at the first of them, so short agents still get wide bars.
  const recentStarts = agents.filter((a) => a.end >= t1 - 1800).map((a) => a.start);
  const w0 = tlRange === "recent" && recentStarts.length ? Math.max(t0, Math.min(...recentStarts)) : t0;
  const span = Math.max(1, t1 - w0);
  const pct = (t) => Math.max(0, Math.min(100, ((t - w0) / span) * 100));
  // Seconds too when the whole span is short, or every label reads the same minute.
  const clock = (t) => new Date(t * 1000).toTimeString().slice(0, span < 600 ? 8 : 5);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => `<span data-style="left:${f * 100}%">${clock(w0 + f * span)}</span>`).join("");
  const older = agents.filter((a) => a.end < w0).length;
  const rangeBtn = (r, label) => `<button class="tl-btn${tlRange === r ? " on" : ""}" data-range="${r}">${label}</button>`;
  const rangeBar = `<div class="tl-range">${rangeBtn("recent", "Recent")}${rangeBtn("all", "All")}` +
    (older ? `<span class="tl-note">${older} older agent${older === 1 ? "" : "s"} shown at the left edge</span>` : "") + `</div>`;
  const rows = [...agents].sort((x, y) => x.start - y.start).map((a) =>
    `<div class="tl-row" data-agent="${esc(a.id)}" data-label="${esc(a.desc)}" title="${esc(a.desc)}">` +
    `<div class="tl-label"><span class="ac-type ${TYPE_CLASS(a.type)}">${esc(a.type)}</span><span class="tl-desc">${esc(a.desc)}</span></div>` +
    `<div class="tl-track">${a.end < w0
      ? `<div class="tl-bar older" title="Ended before this range"></div>`
      : `<div class="tl-bar st-${esc(a.status)}" data-style="left:${pct(a.start).toFixed(2)}%;width:${Math.max(0.8, pct(a.end) - pct(a.start)).toFixed(2)}%"></div>`}</div>` +
    `<div class="tl-dur" data-time="${esc(a.id)}">${dur(a.secs)}</div></div>`).join("");
  $("am-timeline").innerHTML = rangeBar + `<div class="tl-axis"><div></div><div class="tl-ticks">${ticks}</div><div></div></div>${rows}`;
  requestAnimationFrame(() => applyZoom());
  // Again once fonts and sizes have settled, in case the first draw came too early.
  setTimeout(() => applyZoom(), 120);
}

/// Only the clocks and step counts moved: change those numbers, no redraw.
function tickMap() {
  for (const a of agents) {
    document.querySelectorAll(`#agentsview [data-time="${CSS.escape(a.id)}"]`).forEach((el) => { el.textContent = dur(a.secs); });
    const st = document.querySelector(`#agentsview [data-steps="${CSS.escape(a.id)}"]`);
    if (st) st.textContent = `${a.steps} step${a.steps === 1 ? "" : "s"}`;
  }
}

// ---------- Map zoom ----------
// null: shrink the tree to fit the box, but not below ZREAD, so cards stay readable and you scroll.
// "fit": the whole tree in the box, however small (the Fit button). Both re-fit on every redraw.
// A number is a zoom you chose; it stays while the map updates live.
let mapZoom = null, zoomNow = 1;
// When the map opens, scroll a wide tree so the lead sits in the middle, not at the left edge.
// Kept for a moment, because the map is drawn again once sizes settle.
let centerUntil = 0;
const centerLeadSoon = () => { centerUntil = Date.now() + 1500; };
const ZMIN = 0.25, ZMAX = 2, ZREAD = 0.6;

/// Sets the zoom. `anchor` (a point in the window) stays in place, so zooming goes where you point.
/// A scale, not CSS zoom: in this web view CSS zoom shrank the cards but not their text.
function applyZoom(anchor) {
  const map = $("am-map"), sizer = $("am-sizer"), wrap = $("am-mapwrap");
  // Not on screen (the Chats tab is open): nothing to measure yet.
  if (!map || wrap.hidden || !wrap.clientWidth) return;
  const before = zoomNow;
  const box = wrap.getBoundingClientRect();
  const ax = anchor ? anchor.x - box.left : 0, ay = anchor ? anchor.y - box.top : 0;
  const px = wrap.scrollLeft + ax, py = wrap.scrollTop + ay;
  // The tree's size at 100%. offsetWidth ignores the scale, so no need to take it off.
  map.style.minWidth = "0";
  const w = map.offsetWidth, h = map.offsetHeight, room = wrap.clientWidth - 8;
  const fit = Math.min(1, room / w, (window.innerHeight * 0.62 - 30) / h);
  // By default shrink to fit, but not below what can be read; past that, scroll.
  let z = mapZoom === "fit" ? fit : mapZoom === null ? Math.max(ZREAD, fit) : mapZoom;
  zoomNow = Math.max(ZMIN, Math.min(ZMAX, z));
  // A tree narrower than the box is widened to it, so it sits in the middle.
  map.style.minWidth = room / zoomNow + "px";
  map.style.transform = `scale(${zoomNow})`;
  sizer.style.width = Math.max(w, room / zoomNow) * zoomNow + "px";
  sizer.style.height = h * zoomNow + "px";
  $("am-zoomval").textContent = Math.round(zoomNow * 100) + "%";
  if (anchor) {
    const k = zoomNow / before;
    wrap.scrollLeft = px * k - ax;
    wrap.scrollTop = py * k - ay;
  } else if (Date.now() < centerUntil && $("am-lead")) {
    const l = $("am-lead").getBoundingClientRect();
    wrap.scrollLeft += l.left + l.width / 2 - (box.left + wrap.clientWidth / 2);
  }
  drawEdges();
}

function zoomBy(f, anchor) {
  mapZoom = Math.max(ZMIN, Math.min(ZMAX, zoomNow * f));
  applyZoom(anchor);
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-zoom]");
  if (!b) return;
  if (b.dataset.zoom === "fit") { mapZoom = "fit"; centerLeadSoon(); applyZoom(); }
  else zoomBy(b.dataset.zoom === "in" ? 1.2 : 1 / 1.2);
});
// Ctrl + mouse wheel zooms, plain wheel scrolls.
$("am-mapwrap").addEventListener("wheel", (e) => {
  if (!e.ctrlKey) return;
  e.preventDefault();
  zoomBy(Math.exp(-e.deltaY * 0.01), { x: e.clientX, y: e.clientY });
}, { passive: false });
// Trackpad pinch arrives as WebKit gesture events.
let pinchFrom = 1;
$("am-mapwrap").addEventListener("gesturestart", (e) => { e.preventDefault(); pinchFrom = zoomNow; });
$("am-mapwrap").addEventListener("gesturechange", (e) => {
  e.preventDefault();
  mapZoom = Math.max(ZMIN, Math.min(ZMAX, pinchFrom * e.scale));
  applyZoom({ x: e.clientX, y: e.clientY });
});

/// Curved lines from each card to the cards it started. Running ones flow.
function drawEdges() {
  const wrap = $("am-mapwrap"), svg = $("am-edges");
  if (!wrap || wrap.hidden) return;
  const box = wrap.getBoundingClientRect();
  // Shrink the lines layer first, or its old size keeps the scroll area big after a zoom out.
  svg.setAttribute("width", 0);
  svg.setAttribute("height", 0);
  svg.setAttribute("width", wrap.scrollWidth);
  svg.setAttribute("height", wrap.scrollHeight);
  const pos = (el) => {
    const r = el.getBoundingClientRect();
    const left = r.left - box.left + wrap.scrollLeft;
    return { x: left + r.width / 2, left, top: r.top - box.top + wrap.scrollTop, bottom: r.bottom - box.top + wrap.scrollTop };
  };
  // Running lines go last, so they are drawn on top of the finished ones they share a trunk with.
  let paths = "", livePaths = "";
  wrap.querySelectorAll(".tnode").forEach((node) => {
    const from = node.querySelector(":scope > .acard");
    node.querySelectorAll(":scope > .tkids > .tnode > .acard").forEach((to) => {
      const a = pos(from), b = pos(to);
      const status = (to.className.match(/st-(\w+)/) || [])[1] || "done";
      const y1 = a.bottom, y2 = b.top, dy = (y2 - y1) / 2;
      const p = `<path class="edge e-${status}" d="M${a.x} ${y1} C${a.x} ${y1 + dy} ${b.x} ${y2 - dy} ${b.x} ${y2}"/>`;
      if (status === "running" || status === "stuck") livePaths += p; else paths += p;
    });
  });
  svg.innerHTML = paths + livePaths;
}
window.addEventListener("resize", () => { if (mode === "agents") requestAnimationFrame(() => applyZoom()); });

// mousedown, not click: the bar is redrawn every half second while agents run.
document.addEventListener("mousedown", (e) => {
  const rb = e.target.closest("[data-range]");
  if (rb) { e.preventDefault(); tlRange = rb.dataset.range; mapKey = ""; return drawMap(); }
  if (e.target.closest("[data-openmap]")) { e.preventDefault(); return post({ type: "tab", tab: "agents" }); }
  const t = e.target.closest("[data-toggle]");
  if (t) { agentsOpen = !agentsOpen; return drawAgents(); }
  const d = e.target.closest("[data-done]");
  if (d) { showDone = !showDone; return drawAgents(); }
  const a = e.target.closest("[data-agent]");
  if (a && a.dataset.agent) {
    e.preventDefault();
    post({ type: "openAgent", id: a.dataset.agent, label: a.dataset.label || "Agent", sid });
  }
});
$("back").onclick = () => post({ type: "closeAgent" });

// ---------- Needs you ----------
function stableJson(v) {
  if (Array.isArray(v)) return "[" + v.map(stableJson).join(",") + "]";
  if (v && typeof v === "object") return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + stableJson(v[k])).join(",") + "}";
  return JSON.stringify(v);
}

function renderPending(p) {
  const box = $("pending");
  // The app sends the same question again and again, with its fields in any order, so the
  // key sorts them. Otherwise every update redraws the card and loses the picks.
  const key = stableJson(p || null) + sid;
  if (key === lastPendingKey) return;
  lastPendingKey = key;
  if (!p) { box.hidden = true; box.innerHTML = ""; return; }
  box.hidden = false;
  box.innerHTML = "";
  const title = (t) => { const d = document.createElement("div"); d.className = "p-title"; d.textContent = t; box.appendChild(d); };
  const row = () => { const d = document.createElement("div"); d.className = "p-row"; box.appendChild(d); return d; };
  const button = (parent, label, cls, keys) => {
    const b = document.createElement("button");
    b.className = "btn " + cls;
    b.textContent = label;
    b.onclick = () => answer(keys, box);
    parent.appendChild(b);
    return b;
  };
  const openTab = (parent) => {
    const b = document.createElement("button");
    b.className = "btn ghost";
    b.textContent = "Open tab";
    b.onclick = () => post({ type: "focusTab" });
    parent.appendChild(b);
  };
  const note = (t) => { const d = document.createElement("div"); d.className = "p-note"; d.textContent = t; box.appendChild(d); };

  if (p.kind === "question") {
    const qs = p.questions || [];
    if (!qs.length) { title("Claude is asking you"); note("Claude asked a question in the tab."); openTab(row()); return; }
    renderQuestions(box, qs, { title, row, note, openTab });
  } else if (p.kind === "permission") {
    title("Claude wants permission");
    const d = document.createElement("div");
    d.className = "p-detail";
    d.textContent = (p.tool || "A tool") + (p.detail ? ": " + p.detail : "");
    box.appendChild(d);
    const r = row();
    button(r, "Allow once", "primary", ["enter"]);
    button(r, "Deny", "danger", ["escape"]);
    openTab(r);
    note("For \"always allow\" or to tell Claude something else, open the tab.");
  } else if (p.kind === "plan") {
    title("Plan ready for your approval");
    if (p.plan) {
      const d = document.createElement("div");
      d.className = "p-plan";
      d.appendChild(renderMd(p.plan));
      box.appendChild(d);
    }
    const r = row();
    button(r, "Approve, auto mode", "primary", ["enter"]);
    button(r, "Approve, I check edits", "ghost", ["down", "enter"]);
    button(r, "Keep planning", "ghost", ["escape"]);
    openTab(r);
  } else {
    title("Claude needs you in the tab");
    openTab(row());
  }
}

// One question at a time, with a stepper on top. The picks are sent as the keys Claude Code's
// question screen wants, checked on a real tab: Down moves, Enter picks one (and moves on) or
// ticks a box in a many-answer question, Right moves on from a many-answer question, and
// Enter on the review screen submits.
let qMemo = { key: "", picks: [], step: 0 };
function renderQuestions(box, qs, ui) {
  const key = stableJson(qs) + sid;
  if (qMemo.key !== key) qMemo = { key, picks: qs.map(() => []), step: 0 };
  const picks = qMemo.picks;
  let step = qMemo.step;
  const draw = () => {
    qMemo.step = step;
    box.innerHTML = "";
    ui.title("Claude is asking you");
    const q = qs[step];
    if (qs.length > 1) {
      const bar = document.createElement("div");
      bar.className = "p-steps";
      qs.forEach((x, i) => {
        const c = document.createElement("button");
        c.className = "p-step" + (i === step ? " on" : "") + (picks[i].length ? " done" : "");
        c.innerHTML = `<i>${picks[i].length && i !== step ? "✓" : i + 1}</i>${esc(x.header || "Question " + (i + 1))}`;
        c.onclick = () => { step = i; draw(); };
        bar.appendChild(c);
      });
      box.appendChild(bar);
      const n = document.createElement("div");
      n.className = "p-count";
      n.textContent = `Question ${step + 1} of ${qs.length}`;
      box.appendChild(n);
    }
    const d = document.createElement("div");
    d.className = "p-q";
    d.textContent = q.question || "";
    box.appendChild(d);
    const hint = document.createElement("div");
    hint.className = "p-hint";
    hint.textContent = q.multiSelect ? "Pick one or more" : "Pick one";
    box.appendChild(hint);
    const opts = document.createElement("div");
    opts.className = "p-options";
    (q.options || []).forEach((o, i) => {
      const b = document.createElement("button");
      const on = picks[step].includes(i);
      b.className = "opt pick" + (q.multiSelect ? " multi" : "") + (on ? " on" : "");
      b.innerHTML = `<i></i><div><b>${esc(o.label)}</b>${o.description ? `<span>${esc(o.description)}</span>` : ""}</div>`;
      b.onclick = () => {
        if (!q.multiSelect) picks[step] = [i];
        else picks[step] = on ? picks[step].filter((x) => x !== i) : picks[step].concat([i]).sort((a, c) => a - c);
        draw();
      };
      opts.appendChild(b);
    });
    box.appendChild(opts);
    const r = ui.row();
    if (step > 0) {
      const back = document.createElement("button");
      back.className = "btn ghost";
      back.textContent = "Back";
      back.onclick = () => { step--; draw(); };
      r.appendChild(back);
    }
    const last = step === qs.length - 1;
    const go = document.createElement("button");
    go.className = "btn primary";
    go.textContent = last ? "Submit" : "Next";
    go.disabled = !picks[step].length || (last && picks.some((x) => !x.length));
    go.onclick = () => {
      if (!last) { step++; draw(); return; }
      box.querySelectorAll("button").forEach((x) => { x.disabled = true; });
      post({ type: "keys", keys: questionKeys(qs, picks), expect: (qs[0].question || "").slice(0, 30), sid });
    };
    r.appendChild(go);
    ui.openTab(r);
    ui.note("To type your own answer, open the tab.");
  };
  draw();
}

function questionKeys(qs, picks) {
  const keys = [];
  const down = (n) => { for (let i = 0; i < n; i++) keys.push("down"); };
  qs.forEach((q, i) => {
    if (!q.multiSelect) { down(picks[i][0]); keys.push("enter"); return; }
    let at = 0;
    for (const p of picks[i]) { down(p - at); keys.push("enter"); at = p; }
    // One question alone: go to its Submit row, under the options and "Type something".
    if (qs.length === 1) { down((q.options || []).length + 1 - at); keys.push("enter"); }
    else keys.push("right");
  });
  // "Submit answers" on the review screen. Only one plain one-answer question has no review screen.
  if (qs.length > 1 || qs[0].multiSelect) keys.push("enter");
  return keys;
}

function answer(keys, box) {
  box.querySelectorAll("button").forEach((b) => { b.disabled = true; });
  post({ type: "keys", keys, sid });
}

// ---------- Composer ----------
function autosize() {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 220) + "px";
  // Every change to the box goes through here, so the Copy button follows the text.
  $("copy-input").disabled = !input.value.trim();
}
// The page can load before its window has a width, which makes the box measure far too tall.
window.addEventListener("resize", autosize);

function insertText(t) {
  const s = input.selectionStart, e = input.selectionEnd;
  input.setRangeText(t, s, e, "end");
  autosize();
  drafts[sid] = input.value;
  updateSlash();
}

let toastTimer = null;
function toast(msg, ok) {
  const t = $("toast");
  t.textContent = msg;
  t.className = "toast " + (ok ? "ok" : "err");
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ok ? 2500 : 6000);
}

function send() {
  const text = input.value.replace(/\s+$/, "");
  if (!text || sending) return;
  if (!state.canSend) return toast(state.block || "Cannot send to this session", false);
  if (state.pending) return toast("Claude is waiting for your answer above. Answer that first.", false);
  sending = true;
  $("send").disabled = true;
  post({ type: "send", text, sid });
}
$("send").onclick = send;
// Cut: the whole text goes to the clipboard and the box is emptied, ready to paste anywhere.
$("copy-input").onclick = () => {
  const text = input.value;
  if (!text.trim()) return;
  post({ type: "copy", text });
  input.value = "";
  drafts[sid] = "";
  autosize();
  closeSlash();
  toast("Cut to the clipboard", true);
  input.focus();
};
$("stop").onclick = () => post({ type: "keys", keys: ["escape"], sid });

// Slash command list
let slashItems = [], slashOn = 0;
function updateSlash() {
  const v = input.value;
  if (!/^\/\S*$/.test(v)) return closeSlash();
  const q = v.slice(1).toLowerCase();
  const starts = commands.filter((c) => c.name.slice(1).toLowerCase().startsWith(q));
  const has = commands.filter((c) => !starts.includes(c) && c.name.toLowerCase().includes(q));
  slashItems = starts.concat(has).slice(0, 60);
  if (!slashItems.length) return closeSlash();
  slashOn = 0;
  drawSlash();
}
function drawSlash() {
  const box = $("slash");
  box.innerHTML = slashItems.map((c, i) =>
    `<div class="sl${i === slashOn ? " on" : ""}" data-i="${i}"><span class="n">${esc(c.name)}</span><span class="d">${esc(c.desc)}</span></div>`).join("");
  box.hidden = false;
  const on = box.querySelector(".sl.on");
  if (on) on.scrollIntoView({ block: "nearest" });
}
function closeSlash() { $("slash").hidden = true; slashItems = []; }
function pickSlash(i) {
  const c = slashItems[i];
  if (!c) return;
  input.value = c.name + " ";
  drafts[sid] = input.value;
  closeSlash();
  autosize();
  input.focus();
}
$("slash").addEventListener("mousedown", (e) => {
  const d = e.target.closest(".sl");
  if (d) { e.preventDefault(); pickSlash(+d.dataset.i); }
});

// Hold space to talk. A short tap is a normal space.
let spaceTimer = null, voiceOn = false, voiceBase = null;
function flushSpace() {
  if (spaceTimer) { clearTimeout(spaceTimer); spaceTimer = null; insertText(" "); }
}
function startVoice() {
  // Spaces sent to a tab that shows a question or permission menu would pick an option there.
  if (!state.canSend) return toast(state.block || "Voice works only in Ghostty tabs.", false);
  if (state.pending) return toast("Claude is waiting for your answer above. Answer that first, then speak.", false);
  voiceOn = true;
  const s = input.selectionStart, e = input.selectionEnd;
  voiceBase = { before: input.value.slice(0, s), after: input.value.slice(e) };
  $("voice-text").textContent = "Starting Claude Code voice in the tab...";
  $("voice").hidden = false;
  post({ type: "voice", on: true, sid });
}
function stopVoice() {
  if (!voiceOn) return;
  $("voice-text").textContent = "Claude Code is writing your words...";
  post({ type: "voice", on: false, sid });
}

input.addEventListener("keydown", (e) => {
  if (e.isComposing) return;
  const plainSpace = e.key === " " && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;
  if (plainSpace) {
    e.preventDefault();
    if (e.repeat || voiceOn || spaceTimer) return;
    spaceTimer = setTimeout(() => { spaceTimer = null; startVoice(); }, 300);
    return;
  }
  flushSpace();
  if (!$("slash").hidden) {
    if (e.key === "ArrowDown") { e.preventDefault(); slashOn = (slashOn + 1) % slashItems.length; return drawSlash(); }
    if (e.key === "ArrowUp") { e.preventDefault(); slashOn = (slashOn - 1 + slashItems.length) % slashItems.length; return drawSlash(); }
    if (e.key === "Tab") { e.preventDefault(); return pickSlash(slashOn); }
    if (e.key === "Enter" && !e.shiftKey) {
      const c = slashItems[slashOn];
      if (c && c.name !== input.value.trim()) { e.preventDefault(); return pickSlash(slashOn); }
      closeSlash();
    }
    if (e.key === "Escape") { e.preventDefault(); return closeSlash(); }
  }
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); return send(); }
  if (e.key === "Escape") { e.preventDefault(); input.blur(); }
});
input.addEventListener("keyup", (e) => {
  if (e.key !== " ") return;
  if (spaceTimer) flushSpace();
  else if (voiceOn) stopVoice();
});
input.addEventListener("blur", () => { flushSpace(); stopVoice(); });
input.addEventListener("input", () => { drafts[sid] = input.value; autosize(); updateSlash(); });

// The panel has no Edit menu, so the usual shortcuts are handled here.
document.addEventListener("keydown", (e) => {
  if (!e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  const inInput = document.activeElement === input;
  if (k === "c" || k === "x") {
    const text = inInput ? input.value.slice(input.selectionStart, input.selectionEnd) : String(window.getSelection());
    if (text) post({ type: "copy", text });
    if (k === "x" && inInput && text) insertText("");
    e.preventDefault();
  } else if (k === "v" && inInput) {
    post({ type: "paste" });
    e.preventDefault();
  } else if (k === "a") {
    if (inInput) input.select();
    else { const r = document.createRange(); r.selectNodeContents(chat); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
    e.preventDefault();
  } else if (k === "z" && inInput) {
    document.execCommand(e.shiftKey ? "redo" : "undo");
    e.preventDefault();
  } else if (k === "enter" && inInput) {
    e.preventDefault();
    send();
  }
});

post({ type: "ready" });
