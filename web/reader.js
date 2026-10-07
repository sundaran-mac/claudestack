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

let cards = [];

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
    agents = []; viewAgent = ""; showDone = false;
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
    if (first || atBottom) toBottom();
    else if (prepended && oldTop) scroller.scrollTop += oldTop.getBoundingClientRect().top - oldOffset;
    first = false;
  },

  setState(st) {
    if (st.sid !== sid) { sid = st.sid; }
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

  voice({ text, final, error }) {
    if (error) { voiceOn = false; $("voice").hidden = true; return toast(error, false); }
    if (voiceBase) {
      const join = voiceBase.before && !/\s$/.test(voiceBase.before) && text ? " " : "";
      input.value = voiceBase.before + join + text + voiceBase.after;
      const pos = (voiceBase.before + join + text).length;
      input.setSelectionRange(pos, pos);
      autosize();
      drafts[sid] = input.value;
    }
    if (final) { voiceOn = false; voiceBase = null; $("voice").hidden = true; }
  },

  paste(text) { insertText(text); },

  setAgents({ sid: id, agents: list }) {
    if (id !== sid) return;
    agents = list || [];
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

  view({ agent, label }) {
    viewAgent = agent || "";
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
  const pad = a.depth > 1 ? ` style="margin-left:${(a.depth - 1) * 18}px"` : "";
  return `<div class="agent st-${esc(a.status)}${a.id === viewAgent ? " on" : ""}" data-agent="${esc(a.id)}" data-label="${esc(a.desc)}"${pad} title="Click to read this agent's chat">` +
    `<span class="adot"></span><span class="atype">${esc(a.type)}</span><span class="adesc">${esc(a.desc)}</span>` +
    `<span class="ameta">${a.steps} step${a.steps === 1 ? "" : "s"} · ${dur(a.secs)}</span>` +
    `<span class="astep">${esc(step)}</span></div>`;
}

function drawAgents() {
  agentsKey = JSON.stringify(agents.map((a) => [a.id, a.status, a.tool, a.detail, a.steps])) + viewAgent + showDone + agentsOpen;
  const box = $("agents");
  if (!agents.length) { box.hidden = true; box.innerHTML = ""; return; }
  const live = agents.filter((a) => a.status === "running" || a.status === "stuck");
  const done = agents.filter((a) => !(a.status === "running" || a.status === "stuck"));
  let html = `<div class="ag-head${agentsOpen ? "" : " closed"}" data-toggle="1"><b>Agents</b>` +
    (live.length ? `<span class="run">${live.length} running</span>` : "") +
    (done.length ? `<span>${done.length} finished</span>` : "") + `</div>`;
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

// mousedown, not click: the bar is redrawn every half second while agents run.
document.addEventListener("mousedown", (e) => {
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
function renderPending(p) {
  const box = $("pending");
  const key = JSON.stringify(p || null) + sid;
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
    title("Claude is asking you");
    const qs = p.questions || [];
    const simple = qs.length === 1 && !qs[0].multiSelect;
    if (!qs.length) { note("Claude asked a question in the tab."); openTab(row()); return; }
    for (const q of qs) {
      const d = document.createElement("div");
      d.className = "p-q";
      d.textContent = q.question || "";
      box.appendChild(d);
      const opts = document.createElement("div");
      opts.className = "p-options";
      (q.options || []).forEach((o, i) => {
        const b = document.createElement("button");
        b.className = "opt";
        b.innerHTML = `<b>${esc(o.label)}</b>${o.description ? `<span>${esc(o.description)}</span>` : ""}`;
        if (simple) b.onclick = () => answer(Array(i).fill("down").concat(["enter"]), box);
        else b.disabled = true;
        opts.appendChild(b);
      });
      box.appendChild(opts);
    }
    if (!simple) note("This question has more than one part, or many answers. Please answer it in the tab.");
    else note("To type your own answer, open the tab.");
    openTab(row());
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

function answer(keys, box) {
  box.querySelectorAll("button").forEach((b) => { b.disabled = true; });
  post({ type: "keys", keys, sid });
}

// ---------- Composer ----------
function autosize() {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 220) + "px";
}

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
  voiceOn = true;
  const s = input.selectionStart, e = input.selectionEnd;
  voiceBase = { before: input.value.slice(0, s), after: input.value.slice(e) };
  $("voice-text").textContent = "Listening... let go of space to stop";
  $("voice").hidden = false;
  post({ type: "voice", on: true });
}
function stopVoice() {
  if (!voiceOn) return;
  $("voice-text").textContent = "Finishing...";
  post({ type: "voice", on: false });
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
  if (e.key === "Escape") { e.preventDefault(); input.blur(); post({ type: "blur" }); }
});
input.addEventListener("keyup", (e) => {
  if (e.key !== " ") return;
  if (spaceTimer) flushSpace();
  else if (voiceOn) stopVoice();
});
input.addEventListener("blur", () => { flushSpace(); stopVoice(); });
input.addEventListener("input", () => { drafts[sid] = input.value; autosize(); updateSlash(); });
$("composer").addEventListener("mousedown", () => post({ type: "wantKey" }));

// The panel has no Edit menu, so the usual shortcuts are handled here.
document.addEventListener("keydown", (e) => {
  if (!e.metaKey || e.ctrlKey || e.altKey) {
    if (e.key === "Escape" && document.activeElement !== input) post({ type: "blur" });
    return;
  }
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
