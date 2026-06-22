"use strict";

const CANDS = [
  { name: "Adora Xu",    color: "#e06c9f" },
  { name: "Lin CJ",      color: "#5ec5c5" },
  { name: "Galen Lin",   color: "#e0a458" },
  { name: "Hsiao Jimmy", color: "#8a8ad6" },
];
const colorOf = (n) => (CANDS.find((c) => c.name === n) || {}).color || "#888";

const $ = (id) => document.getElementById(id);
const state = { selected: null, scoring: null, mode: "auto", rotation: 0, spinning: false };

// ---- tasks list ----
async function loadTasks(q = "", refresh = false) {
  const list = $("task-list");
  list.innerHTML = '<li class="empty">載入中…（首次需掃描 Notion，約 10–20 秒）</li>';
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (refresh) params.set("refresh", "1");
  const r = await fetch("/api/tasks?" + params.toString());
  const data = await r.json();
  renderTasks(data.tasks || []);
}

function renderTasks(tasks) {
  const list = $("task-list");
  if (!tasks.length) { list.innerHTML = '<li class="empty">沒有待指派任務</li>'; return; }
  list.innerHTML = "";
  for (const t of tasks) {
    const li = document.createElement("li");
    li.dataset.id = t.id;
    const meta = [`<span class="chip">${t.status}</span>`];
    if (t.priority) meta.push(`<span class="chip prio">${t.priority}</span>`);
    if (t.type) meta.push(`<span class="chip">${t.type}</span>`);
    li.innerHTML = `<span class="t-title">${esc(t.title)}</span><span class="t-meta">${meta.join("")}</span>`;
    li.onclick = () => selectTask(t.id, li);
    list.appendChild(li);
  }
}

// ---- selection + scoring ----
function selectTask(id, li) {
  document.querySelectorAll("#task-list li").forEach((x) => x.classList.remove("active"));
  if (li) li.classList.add("active");
  state.selected = id;
  state.mode = "auto";
  $("placeholder").classList.add("hidden");
  $("task-summary").classList.remove("hidden");
  $("allocator").classList.remove("hidden");
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
  const r = await fetch("/api/score?" + params.toString());
  const data = await r.json();
  if (data.error) return;
  state.scoring = data.scoring;
  renderSummary(data.task);
  if (state.mode === "auto") setWeightSliders(data.scoring.weights);
  syncOutputs();
  renderCards();
  renderWheel();
  $("reveal").classList.add("hidden");
  $("spin").disabled = false;
}

function renderSummary(task) {
  const chips = [`<span class="chip">${task.status}</span>`];
  chips.push(`<span class="chip prio">${task.priority || "無優先級"}</span>`);
  if (task.type) chips.push(`<span class="chip">${task.type}</span>`);
  (task.domains || []).forEach((d) => chips.push(`<span class="chip">${esc(d)}</span>`));
  $("task-summary").innerHTML =
    `<div class="ts-title">${esc(task.title)}</div><div class="ts-chips">${chips.join("")}</div>`;
}

function byName() {
  const m = {};
  (state.scoring.results || []).forEach((r) => (m[r.name] = r));
  return m;
}

function renderCards() {
  const m = byName();
  const win = state.lastWinner;
  $("cards").innerHTML = CANDS.map((c) => {
    const r = m[c.name];
    if (!r) return "";
    const pct = Math.round(r.prob * 1000) / 10;
    return `<div class="card ${win === c.name ? "win" : ""}">
      <div class="c-name"><span class="dot" style="background:${c.color}"></span>${c.name}</div>
      <div class="c-prob">${pct}%</div>
      <div class="c-stat">可用 ${bar(r.a)}</div>
      <div class="c-stat">輪替 ${bar(r.fr)}</div>
      <div class="c-stat">契合 ${bar(r.ft)}</div>
      <div class="c-stat">負載 ${r.open_pts}pts · 近14天 ${r.recent}</div>
    </div>`;
  }).join("");
}

const bar = (v) => `<span class="bar"><span style="width:${Math.round(v * 100)}%"></span></span>`;

function renderWheel() {
  const m = byName();
  let cum = 0;
  const stops = CANDS.map((c) => {
    const r = m[c.name];
    const p = r ? r.prob : 0;
    const start = cum * 360;
    cum += p;
    return `${c.color} ${start}deg ${cum * 360}deg`;
  });
  $("wheel").style.background = `conic-gradient(${stops.join(",")})`;
}

// ---- spin ----
function spin() {
  if (state.spinning || !state.scoring) return;
  state.spinning = true;
  $("spin").disabled = true;

  const results = state.scoring.results;
  const winner = weightedPick(results);

  // mid-angle of winner's slice (slices laid out in fixed CANDS order)
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
  $("wheel").style.transform = `rotate(${target}deg)`;

  const onEnd = () => {
    $("wheel").removeEventListener("transitionend", onEnd);
    state.spinning = false;
    state.lastWinner = winner;
    reveal(winner);
    renderCards();
  };
  $("wheel").addEventListener("transitionend", onEnd);
}

function weightedPick(results) {
  const r = Math.random();
  let cum = 0;
  for (const x of results) { cum += x.prob; if (r <= cum) return x.name; }
  return results[results.length - 1].name;
}

function reveal(winner) {
  const r = byName()[winner];
  const pct = Math.round(r.prob * 1000) / 10;
  $("reveal").classList.remove("hidden");
  $("reveal").innerHTML = `
    <div class="r-name"><span class="dot" style="background:${colorOf(winner)}"></span> ${winner} <span style="color:var(--dim);font-size:14px">· ${pct}%</span></div>
    <div class="r-reason">${r.reason}</div>
    <button class="assign-btn" id="do-assign">✅ 指派給 ${winner}（dry-run）</button>
    <div class="r-dry" id="assign-msg"></div>`;
  $("do-assign").onclick = () => assign(r);
}

async function assign(r) {
  const resp = await fetch("/api/assign", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ task_id: state.selected, name: r.name, user_id: r.user_id }),
  });
  const data = await resp.json();
  $("assign-msg").textContent = data.message + ` → owner = ${data.would_set.owner}`;
  $("do-assign").disabled = true;
}

// ---- weight / temp controls ----
function setWeightSliders(w) { $("wa").value = w.a; $("wfr").value = w.fr; $("wft").value = w.ft; }
function syncOutputs() {
  $("wa-out").textContent = (+$("wa").value).toFixed(2);
  $("wfr-out").textContent = (+$("wfr").value).toFixed(2);
  $("wft-out").textContent = (+$("wft").value).toFixed(2);
  $("temp-out").textContent = (+$("temp").value).toFixed(2);
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
