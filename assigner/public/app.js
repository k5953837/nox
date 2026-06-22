"use strict";

const CANDS = [
  { name: "Adora Xu",    short: "Adora",  color: "#d98aa6" },
  { name: "Lin CJ",      short: "Lin CJ", color: "#4fb8a8" },
  { name: "Galen Lin",   short: "Galen",  color: "#cf7e54" },
  { name: "Hsiao Jimmy", short: "Jimmy",  color: "#7e86c9" },
];
const colorOf = (n) => (CANDS.find((c) => c.name === n) || {}).color || "#888";
const shortOf = (n) => (CANDS.find((c) => c.name === n) || {}).short || n;

const $ = (id) => document.getElementById(id);
const REDUCED = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const NOISE = /^\[(測試|會議)\]/;
const state = { selected: null, scoring: null, mode: "auto", rotation: 0, spinning: false, winner: null };

// ---------- queue ----------
async function loadTasks(q = "", refresh = false) {
  $("task-list").innerHTML = '<li class="empty">載入中…（首次掃描 Notion，約 10–20 秒）</li>';
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (refresh) params.set("refresh", "1");
  try {
    const r = await fetch("/api/tasks?" + params);
    const data = await r.json();
    renderTasks((data.tasks || []).filter((t) => !NOISE.test(t.title)));
  } catch (e) {
    $("task-list").innerHTML = '<li class="empty">載入失敗，確認 server 是否在執行</li>';
  }
}

function prioChip(p) {
  if (!p) return "";
  const cls = /^P0/.test(p) ? "chip prio p0" : "chip prio";
  return `<span class="${cls}">${esc(p)}</span>`;
}

function renderTasks(tasks) {
  const list = $("task-list");
  if (!tasks.length) { list.innerHTML = '<li class="empty">沒有待指派任務</li>'; return; }
  list.innerHTML = "";
  tasks.forEach((t) => {
    const li = document.createElement("li");
    if (state.selected === t.id) li.className = "active";
    const meta = [`<span class="chip">${esc(t.status)}</span>`, prioChip(t.priority)];
    if (t.type) meta.push(`<span class="chip">${esc(t.type)}</span>`);
    li.innerHTML = `<span class="t-title">${esc(t.title)}</span><span class="t-meta">${meta.join("")}</span>`;
    li.onclick = () => selectTask(t.id, li);
    list.appendChild(li);
  });
}

// ---------- selection + scoring ----------
function selectTask(id, li) {
  document.querySelectorAll("#task-list li").forEach((x) => x.classList.remove("active"));
  if (li) li.classList.add("active");
  state.selected = id;
  state.mode = "auto";
  state.winner = null;
  $("placeholder").classList.add("hidden");
  $("decide-head").classList.remove("hidden");
  $("board").classList.remove("hidden");
  $("hub").querySelector("span").textContent = "SPIN";
  fetchScore();
}

async function fetchScore() {
  if (!state.selected) return;
  const params = new URLSearchParams({ task_id: state.selected, temp: $("temp").value });
  if (state.mode === "manual") {
    params.set("wa", $("wa").value);
    params.set("wfr", $("wfr").value);
    params.set("wft", $("wft").value);
  }
  const r = await fetch("/api/score?" + params);
  const data = await r.json();
  if (data.error) return;
  state.scoring = data.scoring;
  renderDecideHead(data.task);
  if (state.mode === "auto") setWeightSliders(data.scoring.weights);
  syncOutputs();
  renderForm();
  renderWheel();
  $("reveal").classList.add("hidden");
  $("spin").disabled = false;
}

function renderDecideHead(task) {
  $("decide-title").textContent = task.title;
  const chips = [`<span class="chip">${esc(task.status)}</span>`, prioChip(task.priority) || `<span class="chip">無優先級</span>`];
  if (task.type) chips.push(`<span class="chip">${esc(task.type)}</span>`);
  (task.domains || []).forEach((d) => chips.push(`<span class="chip">${esc(d)}</span>`));
  $("decide-chips").innerHTML = chips.join("");
}

function byName() {
  const m = {};
  (state.scoring.results || []).forEach((r) => (m[r.name] = r));
  return m;
}

// ---------- form board ----------
function metric(label, v) {
  return `<span class="metric">${label}<span class="mbar"><i style="width:${Math.round(v * 100)}%"></i></span></span>`;
}

function renderForm() {
  const m = byName();
  $("cards").innerHTML = CANDS.map((c) => {
    const r = m[c.name];
    if (!r) return "";
    const pct = (r.prob * 100).toFixed(1);
    const win = state.winner === c.name ? " win" : "";
    return `<div class="frow${win}">
      <span class="frow-rank" style="--c:${c.color}"></span>
      <div class="frow-main">
        <div class="frow-name">${c.short}</div>
        <div class="frow-reason">${esc(r.reason)}</div>
        <div class="frow-bars">${metric("可用", r.a)}${metric("輪替", r.fr)}${metric("契合", r.ft)}</div>
      </div>
      <div class="frow-odds">${pct}<i>%</i></div>
    </div>`;
  }).join("");
}

// ---------- wheel (signature) ----------
function polar(cx, cy, r, deg) { const a = (deg * Math.PI) / 180; return [cx + r * Math.sin(a), cy - r * Math.cos(a)]; }
function arc(cx, cy, r, a0, a1) {
  const [x0, y0] = polar(cx, cy, r, a0);
  const [x1, y1] = polar(cx, cy, r, a1);
  const large = a1 - a0 > 180 ? 1 : 0;
  return `M${cx},${cy} L${x0.toFixed(2)},${y0.toFixed(2)} A${r},${r} 0 ${large} 1 ${x1.toFixed(2)},${y1.toFixed(2)} Z`;
}

function renderWheel() {
  const m = byName();
  const cx = 150, cy = 150, r = 130;
  let cum = 0, seg = "";
  for (const c of CANDS) {
    const p = (m[c.name] || {}).prob || 0;
    if (p > 0.0005) seg += `<path d="${arc(cx, cy, r, cum * 360, (cum + p) * 360)}" fill="${c.color}" stroke="#121620" stroke-width="2"/>`;
    cum += p;
  }
  let ticks = "";
  for (let i = 0; i < 20; i++) {
    const d = i * 18, len = i % 2 === 0 ? 9 : 5;
    const [x0, y0] = polar(cx, cy, r + 2, d), [x1, y1] = polar(cx, cy, r + 2 + len, d);
    ticks += `<line x1="${x0.toFixed(1)}" y1="${y0.toFixed(1)}" x2="${x1.toFixed(1)}" y2="${y1.toFixed(1)}" stroke="#c9a24b" stroke-width="${i % 2 === 0 ? 1.5 : 0.8}" opacity=".75"/>`;
  }
  $("wheel").innerHTML =
    `<g>${seg}</g><circle cx="150" cy="150" r="130" fill="none" stroke="#c9a24b" stroke-width="2.5"/>${ticks}`;
}

// ---------- spin ----------
function spin() {
  if (state.spinning || !state.scoring) return;
  state.spinning = true;
  $("spin").disabled = true;

  const winner = weightedPick(state.scoring.results);
  const m = byName();
  let cum = 0, mid = 0;
  for (const c of CANDS) {
    const p = (m[c.name] || {}).prob || 0;
    if (c.name === winner) { mid = (cum + p / 2) * 360; break; }
    cum += p;
  }
  const want = (360 - (mid % 360)) % 360;
  let target = state.rotation - (state.rotation % 360) + want;
  if (target <= state.rotation) target += 360;
  target += 360 * 4;
  state.rotation = target;

  const finish = () => {
    state.spinning = false;
    state.winner = winner;
    $("spin").disabled = false;
    $("hub").querySelector("span").textContent = shortOf(winner).slice(0, 6);
    reveal(winner);
    renderForm();
  };

  if (REDUCED) { $("wheel").style.transform = `rotate(${target}deg)`; finish(); return; }
  const onEnd = () => { $("wheel").removeEventListener("transitionend", onEnd); finish(); };
  $("wheel").addEventListener("transitionend", onEnd);
  requestAnimationFrame(() => { $("wheel").style.transform = `rotate(${target}deg)`; });
}

function weightedPick(results) {
  const r = Math.random();
  let cum = 0;
  for (const x of results) { cum += x.prob; if (r <= cum) return x.name; }
  return results[results.length - 1].name;
}

// ---------- reveal ----------
function reveal(winner) {
  const r = byName()[winner];
  const pct = (r.prob * 100).toFixed(1);
  const el = $("reveal");
  el.classList.remove("hidden");
  el.innerHTML = `
    <div class="r-top">
      <span class="r-flag">中選 · WINNER</span>
      <span class="r-name"><span class="dot" style="background:${colorOf(winner)}"></span>${shortOf(winner)}</span>
      <span class="r-odds">${pct}%</span>
    </div>
    <div class="r-reason">${esc(r.reason)}</div>
    <button class="assign-btn" id="do-assign">指派給 ${shortOf(winner)}</button>
    <div class="r-dry" id="assign-msg"></div>`;
  el.style.animation = "none"; void el.offsetWidth; el.style.animation = "";
  $("do-assign").onclick = () => assign(r);
}

async function assign(r) {
  const resp = await fetch("/api/assign", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ task_id: state.selected, name: r.name, user_id: r.user_id }),
  });
  const data = await resp.json();
  $("assign-msg").textContent = `${data.message} → owner = ${data.would_set.owner}`;
  $("do-assign").disabled = true;
}

// ---------- controls ----------
function setWeightSliders(w) { $("wa").value = w.a; $("wfr").value = w.fr; $("wft").value = w.ft; }
function syncOutputs() {
  ["wa", "wfr", "wft", "temp"].forEach((k) => ($(k + "-out").textContent = (+$(k).value).toFixed(2)));
}
const debounce = (fn, ms) => { let t; return () => { clearTimeout(t); t = setTimeout(fn, ms); }; };
const debouncedScore = debounce(fetchScore, 180);

function init() {
  loadTasks();
  $("search").addEventListener("input", debounce(() => loadTasks($("search").value), 250));
  $("refresh").onclick = () => { state.selected = null; loadTasks($("search").value, true); };
  document.querySelectorAll("input.weight").forEach((el) =>
    el.addEventListener("input", () => { state.mode = "manual"; syncOutputs(); debouncedScore(); }));
  $("temp").addEventListener("input", () => { syncOutputs(); debouncedScore(); });
  $("auto").onclick = () => { state.mode = "auto"; fetchScore(); };
  $("spin").onclick = spin;
  syncOutputs();
}

function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

init();
