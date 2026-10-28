
import json

HLS_JS = "https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js"
LEAFLET_VERSION = "1.9.4"
LEAFLET_CSS = (
    f"https://unpkg.com/leaflet@{LEAFLET_VERSION}/dist/leaflet.css"
)
LEAFLET_JS = (
    f"https://unpkg.com/leaflet@{LEAFLET_VERSION}/dist/leaflet.js"
)


def render_viewer_page(share_token: str) -> str:
    token_json = json.dumps(share_token)
    return (
        _PAGE.replace("__TOKEN__", token_json)
        .replace("__LEAFLET_CSS__", LEAFLET_CSS)
        .replace("__LEAFLET_JS__", LEAFLET_JS)
        .replace("__HLS_JS__", HLS_JS)
    )


_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Safeguard live view</title>
<link rel="stylesheet" href="__LEAFLET_CSS__">
<style>
  :root { color-scheme: dark; --bg:#0d0a12; --card:#1a1422; --text:#e8e2f0;
          --muted:#9d94ad; --accent:#b98dd1; --danger:#ff4d4d; --ok:#3ddbc4; }
  * { box-sizing: border-box; }
  body { margin:0; padding:16px; background:var(--bg); color:var(--text);
         font-family:-apple-system,system-ui,"SF Pro Text",sans-serif; }
  main { max-width:640px; margin:0 auto; }
  header { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .pill { display:inline-flex; align-items:center; gap:8px; padding:6px 14px;
          border-radius:999px; font-weight:700; font-size:14px; }
  .active { background:var(--danger); color:#fff; }
  .ended { background:#3a3344; color:#cfc8dc; }
  .dot { width:9px; height:9px; border-radius:50%; background:#fff;
         animation:pulse 1.4s ease-out infinite; }
  .ended .dot { animation:none; opacity:.5; }
  @keyframes pulse { 0%{box-shadow:0 0 0 0 rgba(255,255,255,.7)}
                     100%{box-shadow:0 0 0 10px rgba(255,255,255,0)} }
  h1 { font-size:24px; margin:14px 0 2px; letter-spacing:-.2px; }
  .sub { color:var(--muted); font-size:13px; margin:0 0 14px; }
  #map { height:300px; border-radius:20px; background:var(--card); }
  .card { background:var(--card); border-radius:20px; padding:14px;
          margin-top:14px; border:1px solid rgba(255,255,255,.06); }
  .card h2 { font-size:15px; margin:0 0 10px; color:var(--accent); }
  video, audio { width:100%; border-radius:14px; background:#000; }
  .behind { color:var(--muted); font-size:12.5px; margin:8px 0 0; }
  .row { display:flex; gap:10px; margin-top:12px; flex-wrap:wrap; }
  a.btn { flex:1; text-align:center; padding:13px 14px; border-radius:14px;
          background:#8e52a3; color:#fff; text-decoration:none; font-weight:600;
          font-size:15px; min-width:140px; }
  a.btn.alt { background:transparent; border:1px solid rgba(255,255,255,.2); }
  .err { display:none; background:#3a1a1a; border-radius:14px; padding:12px;
         margin-top:14px; }
  .chip { display:inline-block; font-size:12px; padding:3px 9px; margin-left:6px;
          border-radius:999px; background:rgba(61,219,196,.15); color:var(--ok); }
  .chip.warn { background:rgba(255,210,63,.15); color:#ffd23f; }
</style>
</head>
<body>
<main>
  <header>
    <span id="status" class="pill active"><i class="dot"></i><span id="statusText">SOS ACTIVE</span></span>
    <span id="age" class="sub" style="margin:0"></span>
  </header>
  <h1 id="who">Live view</h1>
  <p class="sub" id="meta">connecting&hellip;</p>
  <div id="map"></div>
  <p class="sub" style="margin-top:8px" id="where"></p>
  <div class="row" id="mapLinks" style="display:none">
    <a class="btn" id="gDir" target="_blank" rel="noopener">Directions in Google Maps</a>
    <a class="btn alt" id="gPin" target="_blank" rel="noopener">Open pin</a>
  </div>
  <div class="card">
    <h2>Video <span class="chip" id="liveChip">catching up</span></h2>
    <video id="video" controls playsinline muted></video>
    <p class="behind" id="videoNote">Segment-based recording, about 10-15 s behind. It always jumps to the newest part.</p>
  </div>
  <div class="card" id="audioCard">
    <h2>Audio</h2>
    <audio id="audio" controls preload="none"></audio>
    <p class="behind">Audio parts, newest first when it falls behind.</p>
  </div>
  <div class="err" id="err"></div>
</main>
<script src="__LEAFLET_JS__"></script>
<script src="__HLS_JS__"></script>
<script>
const TOKEN = __TOKEN__;
const BASE = location.pathname.replace(/\\/+$/, "");
let map = null, marker = null, circle = null, trailLine = null;
let seen = {}, videoQueue = [], audioQueue = [], lastFixAt = 0, lastOk = 0;

function showError(text) {
  const box = document.getElementById("err");
  box.style.display = "block";
  box.textContent = text;
}

function trim(queue, keep) {
  while (queue.length > keep) queue.shift();
}

function playNext(player, queue) {
  if (queue.length === 0 || !player.paused) return;
  player.src = queue.shift();
  player.play().catch(() => {});
}

function setupPlayer(id, queue) {
  const player = document.getElementById(id);
  player.addEventListener("ended", () => playNext(player, queue));
  player.addEventListener("error", () => playNext(player, queue));
  return player;
}
const videoEl = setupPlayer("video", videoQueue);
const audioEl = setupPlayer("audio", audioQueue);

let usingHls = false, hlsPlayer = null;
function startContinuous() {
  if (usingHls) return true;
  const url = BASE + "/stream.m3u8";
  if (videoEl.canPlayType("application/vnd.apple.mpegurl")) {
    videoEl.src = url;
  } else if (window.Hls && Hls.isSupported()) {
    hlsPlayer = new Hls({liveSyncDurationCount: 3, maxBufferLength: 20});
    hlsPlayer.loadSource(url);
    hlsPlayer.attachMedia(videoEl);
  } else {
    return false;
  }
  usingHls = true;
  document.getElementById("audioCard").style.display = "none";
  document.getElementById("videoNote").textContent =
    "One continuous recording with sound, about 6-10 s behind. Tap the speaker to hear it.";
  videoEl.play().catch(() => {});
  return true;
}

function ago(seconds) {
  if (seconds < 5) return "just now";
  if (seconds < 60) return Math.round(seconds) + " s ago";
  return Math.round(seconds / 60) + " min ago";
}

function showLocation(latest, trail) {
  const at = [latest.lat, latest.lon];
  if (!map) {
    map = L.map("map", {zoomControl: true}).setView(at, 17);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: "&copy; OpenStreetMap contributors"
    }).addTo(map);
  } else {
    map.panTo(at);
  }
  if (marker) marker.setLatLng(at); else marker = L.marker(at).addTo(map);
  if (latest.accuracy && latest.accuracy > 8) {
    if (circle) { circle.setLatLng(at); circle.setRadius(latest.accuracy); }
    else circle = L.circle(at, {radius: latest.accuracy, color: "#4d8dff",
                                fillOpacity: .12, weight: 1}).addTo(map);
  }
  const line = trail.map(p => [p.lat, p.lon]);
  if (trailLine) trailLine.setLatLngs(line);
  else if (line.length > 1) trailLine = L.polyline(line, {color: "#ff4d4d", weight: 4}).addTo(map);
  const accText = latest.accuracy
    ? (latest.accuracy < 10 ? "exact" : "about " + Math.round(latest.accuracy) + " m") : "";
  document.getElementById("where").innerHTML =
    "Location " + accText + (latest.accuracy > 250 ? ' <span class="chip warn">rough</span>' : "");
  const q = at[0] + "," + at[1];
  document.getElementById("gDir").href =
    "https://www.google.com/maps/dir/?api=1&destination=" + q + "&travelmode=driving";
  document.getElementById("gPin").href =
    "https://www.google.com/maps/search/?api=1&query=" + q;
  document.getElementById("mapLinks").style.display = "flex";
  lastFixAt = latest.ts || 0;
}

async function refresh() {
  let state;
  try {
    const res = await fetch(BASE + "/state", {cache: "no-store"});
    if (!res.ok) throw new Error("page link is no longer valid");
    state = await res.json();
  } catch (err) {
    showError("Lost connection to the backend. Retrying\u2026");
    return;
  }
  lastOk = Date.now();
  document.getElementById("err").style.display = "none";
  const pill = document.getElementById("status");
  const idle = state.status === "idle";
  const ended = state.status === "ended";
  const isLive = state.mode === "live";
  document.getElementById("statusText").textContent = idle ? "NOT LIVE RIGHT NOW"
    : ended ? (isLive ? "STREAM ENDED" : "SOS ENDED")
    : (isLive ? "LIVE" : "SOS ACTIVE");
  pill.className = "pill " + (ended || idle ? "ended" : "active");
  document.getElementById("who").textContent =
    "Live view: " + (state.wearer_name || "wearer");
  const when = state.started_at
    ? new Date(state.started_at * 1000).toLocaleString() : "";
  document.getElementById("meta").textContent = idle
    ? "Waiting for the stream to start. This page updates by itself."
    : "Started " + when + (ended ? " \u00b7 ended" : " \u00b7 updating every 2 s");
  if (state.latest) showLocation(state.latest, state.trail || []);
  if (state.hls && startContinuous()) {
    const chipEl = document.getElementById("liveChip");
    chipEl.textContent = state.hls.over ? "ended" : "live";
    chipEl.className = "chip";
    return;
  }
  for (const seg of state.segments || []) {
    if (seen[seg.name]) continue;
    seen[seg.name] = true;
    (seg.kind === "video" ? videoQueue : audioQueue).push(BASE + "/" + seg.url);
  }
  trim(videoQueue, 2);
  trim(audioQueue, 2);
  playNext(videoEl, videoQueue);
  playNext(audioEl, audioQueue);
  const chip = document.getElementById("liveChip");
  const behind = videoQueue.length;
  chip.textContent = ended ? "ended" : (behind > 1 ? "catching up" : "live");
  chip.className = "chip" + (behind > 1 ? " warn" : "");
}

function tickAge() {
  const el = document.getElementById("age");
  if (lastFixAt) el.textContent = "Position updated " + ago(Date.now() / 1000 - lastFixAt);
}
setInterval(refresh, 2000);
setInterval(tickAge, 1000);
refresh();
</script>
</body>
</html>
"""


def render_guardian_page() -> str:
    return (
        _GUARDIAN_PAGE.replace("__LEAFLET_CSS__", LEAFLET_CSS)
        .replace("__LEAFLET_JS__", LEAFLET_JS)
        .replace("__HLS_JS__", HLS_JS)
    )


_GUARDIAN_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Safeguard guardian</title>
<link rel="stylesheet" href="__LEAFLET_CSS__">
<style>
  :root { color-scheme: dark; --bg:#0d0a12; --card:#1a1422; --text:#e8e2f0;
          --muted:#9d94ad; --accent:#b98dd1; --danger:#ff4d4d; --ok:#3ddbc4; }
  * { box-sizing: border-box; }
  body { margin:0; padding:16px; background:var(--bg); color:var(--text);
         font-family:-apple-system,system-ui,"SF Pro Text",sans-serif; }
  main { max-width:720px; margin:0 auto; }
  h1 { font-size:26px; margin:12px 0 4px; letter-spacing:-.3px; }
  h2 { font-size:16px; margin:0 0 10px; color:var(--accent); }
  .sub { color:var(--muted); font-size:13px; margin:0 0 14px; }
  .card { background:var(--card); border-radius:20px; padding:16px; margin-top:14px;
          border:1px solid rgba(255,255,255,.06); }
  input { width:100%; padding:14px; border-radius:14px; border:1px solid rgba(255,255,255,.15);
          background:#120d18; color:var(--text); font-size:18px; letter-spacing:2px;
          text-transform:uppercase; }
  button, .btn { padding:13px 16px; border-radius:14px; border:0; background:#8e52a3; color:#fff;
                 font-size:15px; font-weight:600; cursor:pointer; margin-top:10px; }
  button.alt { background:transparent; border:1px solid rgba(255,255,255,.2); }
  .row { display:flex; gap:10px; flex-wrap:wrap; }
  .err { color:#ff8a8a; font-size:13px; margin-top:8px; min-height:1em; }
  .item { display:flex; flex-wrap:wrap; justify-content:space-between; gap:6px 12px; padding:14px 0;
          border-top:1px solid rgba(255,255,255,.07); cursor:pointer; }
  .item:first-of-type { border-top:0; }
  .item b { display:block; font-size:15px; }
  .item span { color:var(--muted); font-size:13px; }
  .pill { display:inline-block; padding:3px 10px; border-radius:999px; font-size:12px;
          font-weight:700; background:#3a3344; color:#cfc8dc; }
  .pill.live { background:var(--danger); color:#fff; }
  #map { height:260px; border-radius:16px; background:#120d18; }
  video, audio { width:100%; border-radius:14px; background:#000; margin-top:8px; }
  .code { font-size:28px; letter-spacing:4px; font-weight:800; text-align:center; padding:14px;
          background:#120d18; border-radius:14px; margin:10px 0; }
  .seg { display:flex; justify-content:space-between; font-size:13px; color:var(--muted);
         padding:6px 0; border-top:1px solid rgba(255,255,255,.06); }
  .log { width:100%; border-collapse:collapse; font-size:13px; }
  .log th { text-align:left; color:var(--muted); font-weight:600; padding:6px 6px 8px 0;
            border-bottom:1px solid rgba(255,255,255,.1); }
  .log td { padding:10px 6px 10px 0; vertical-align:top; border-bottom:1px solid rgba(255,255,255,.05); }
  .log td:last-child, .log th:last-child { padding-right:0; text-align:right; }
  .tag { display:inline-block; padding:2px 9px; border-radius:999px; font-size:11px; font-weight:700;
         background:#2c2536; color:#cfc8dc; }
  .tag.plate { background:#1f3a4d; color:#a9d6f5; }
  .tag.name { background:#3b2b4d; color:#d9b8f2; }
  .tag.gesture { background:#4d2b2b; color:#f5b8b8; }
  .strong { background:#3d2a14; color:#ffcf8a; }
  .thumb { width:110px; border-radius:10px; display:block; }
  .shotbox { display:flex; gap:12px; align-items:flex-start; }
  .shotside { flex:1; min-width:0; }
  .src { color:var(--muted); font-size:12px; margin-top:3px; }
  .ask { margin-top:8px; padding:10px; border-radius:12px; background:#120d18; }
  .ask textarea { width:100%; min-height:52px; padding:10px; border-radius:10px; font-size:14px;
                  border:1px solid rgba(255,255,255,.15); background:#0c0911; color:var(--text);
                  font-family:inherit; }
  .chips { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:8px; }
  .chip { padding:6px 10px; border-radius:999px; font-size:12px; margin:0; font-weight:600;
          background:transparent; border:1px solid rgba(255,255,255,.2); }
  .answer { font-size:14px; line-height:1.4; margin:8px 0 0; }
  .muted { color:var(--muted); font-size:12px; }
  a { color:var(--accent); }
  .hidden { display:none; }
</style>
</head>
<body>
<main>
  <h1>Safeguard guardian</h1>
  <p class="sub">Read-only access to the recordings of the person you protect. Nothing here can be changed or deleted.</p>

  <section id="login">
    <div class="card">
      <h2>I have a guardian code</h2>
      <input id="code" placeholder="XXXX-XXXX-XXXX" autocomplete="off" autocapitalize="characters" spellcheck="false">
      <button id="open">Open recordings</button>
      <div class="err" id="loginErr"></div>
    </div>
    <div class="card">
      <h2>I am a guardian and need a code</h2>
      <p class="sub">Get a code, then give it to the person you protect. She enters it when she signs up (or later in Settings), and her recordings appear here when you enter the same code.</p>
      <button class="alt" id="mint">Get my guardian code</button>
      <div id="minted" class="hidden">
        <div class="code" id="mintedCode"></div>
        <p class="sub">Write it down: it is shown only once and anyone with it can see the recordings.</p>
      </div>
      <div class="err" id="mintErr"></div>
    </div>
  </section>

  <section id="list" class="hidden">
    <div class="row"><button class="alt" id="signout">Sign out</button><button class="alt" id="reload">Refresh</button></div>
    <div class="card hidden" id="alertCard"><h2>SOS alerts on Telegram</h2>
      <p class="sub" id="alertText"></p>
      <a class="btn" id="alertLink" target="_blank" rel="noopener">Get alerts on Telegram</a></div>
    <div class="card"><h2>Incidents</h2><div id="items"></div></div>
  </section>

  <section id="detail" class="hidden">
    <button class="alt" id="back">&larr; All incidents</button>
    <div class="card">
      <h2 id="dTitle"></h2>
      <p class="sub" id="dMeta"></p>
      <div id="map"></div>
    </div>
    <div class="card">
      <h2>Video</h2>
      <video id="player" controls playsinline></video>
      <p class="sub" id="playing"></p>
      <div class="row"><button id="playAll">Play all in order</button></div>
      <div id="videos"></div>
    </div>
    <div class="card" id="logCard">
      <h2>Evidence log</h2>
      <p class="sub">Names heard, vehicle number plates and gesture moments during this incident. Every entry is rated &ldquo;possible&rdquo; or &ldquo;strongly possible&rdquo;, never certain.</p>
      <div id="logBody"></div>
    </div>
    <div class="card" id="audioCard">
      <h2>Audio</h2>
      <audio id="audioPlayer" controls></audio>
      <div id="audios"></div>
    </div>
  </section>
</main>
<script src="__LEAFLET_JS__"></script>
<script src="__HLS_JS__"></script>
<script>
const $ = (id) => document.getElementById(id);
let guardianHls = null;
let CODE = sessionStorage.getItem("guardianCode") || "";
let map = null, layer = null, queue = [], current = 0;

function show(which) {
  for (const id of ["login", "list", "detail"]) $(id).classList.toggle("hidden", id !== which);
}
function fmtDate(ts) { return ts ? new Date(ts * 1000).toLocaleString() : "—"; }
function fmtDur(a, b) {
  if (!a) return "";
  const secs = Math.max(0, Math.round((b || Date.now() / 1000) - a));
  return secs < 60 ? secs + " s" : Math.floor(secs / 60) + " min " + (secs % 60) + " s";
}
function fmtSize(n) { return n > 1e6 ? (n / 1e6).toFixed(1) + " MB" : Math.round(n / 1e3) + " kB"; }

async function api(path) {
  const res = await fetch(path, {headers: {"X-Guardian-Code": CODE}, cache: "no-store"});
  if (res.status === 403) throw new Error("That code is not valid.");
  if (res.status === 429) throw new Error("Too many tries. Wait a minute.");
  if (!res.ok) throw new Error("Something went wrong (" + res.status + ").");
  return res.json();
}

const CHIPS = ["What is happening here?", "Is this aimed at the wearer?", "What is in the hands?"];

function fmtClock(ts) { return new Date(ts * 1000).toLocaleTimeString(); }
function label(type) { return type === "plate" ? "Plate" : type === "name" ? "Name" : "Gesture"; }

function renderLog(items, incidentId) {
  const box = $("logBody");
  if (!items || !items.length) {
    box.innerHTML = '<p class="sub">Nothing captured yet. Names, plates and gesture moments appear here during an SOS.</p>';
    return;
  }
  let html = '<table class="log"><tr><th>Time</th><th>Type</th><th>Detail</th><th>Confidence</th></tr>';
  items.forEach((item, index) => {
    html += '<tr><td>' + fmtClock(item.t) + '</td><td><span class="tag ' + item.type + '">' + label(item.type) + '</span></td><td>' +
      '<b>' + escapeHtml(item.text) + '</b>' +
      (item.count > 1 ? ' <span class="muted">seen ' + item.count + ' times</span>' : '') +
      (item.source ? '<div class="src">&ldquo;' + escapeHtml(item.source) + '&rdquo;</div>' : '') +
      '</td><td><span class="tag ' + (item.rating === "strongly possible" ? "strong" : "") + '">' + escapeHtml(item.rating) + '</span></td></tr>';
    if (item.shot_url) {
      html += '<tr class="shotrow"><td colspan="4" style="text-align:left"><div class="shotbox">' +
        '<a href="' + item.shot_url + '" target="_blank"><img class="thumb" src="' + item.shot_url + '" alt="Captured moment"></a>' +
        '<div class="shotside"><button class="alt chip" data-ask="' + index + '">Ask Muse about this moment</button>' +
        '<div id="ask' + index + '"></div></div></div></td></tr>';
    }
  });
  box.innerHTML = html + '</table>';
  box.querySelectorAll("button[data-ask]").forEach((btn) => {
    btn.onclick = () => openAsk(items[Number(btn.dataset.ask)], btn.dataset.ask, incidentId);
  });
}

function openAsk(item, index, incidentId) {
  const holder = $("ask" + index);
  if (holder.innerHTML) { holder.innerHTML = ""; return; }
  holder.innerHTML = '<div class="ask"><div class="chips">' +
    CHIPS.map((q) => '<button class="chip" data-q="' + escapeHtml(q) + '">' + escapeHtml(q) + '</button>').join("") +
    '</div><textarea maxlength="300" placeholder="Ask Muse about this moment"></textarea>' +
    '<button class="send">Ask</button><p class="answer muted"></p></div>';
  const area = holder.querySelector("textarea");
  const answer = holder.querySelector(".answer");
  holder.querySelectorAll(".chip").forEach((chip) => { chip.onclick = () => { area.value = chip.dataset.q; }; });
  holder.querySelector(".send").onclick = async () => {
    const question = area.value.trim();
    if (question.length < 3) { answer.textContent = "Type a question first."; return; }
    answer.textContent = "Muse is looking at the moment...";
    try {
      const res = await fetch("/guardian/api/incidents/" + encodeURIComponent(incidentId) + "/ask", {
        method: "POST",
        headers: {"X-Guardian-Code": CODE, "Content-Type": "application/json"},
        body: JSON.stringify({shot: item.shot, question: question}),
      });
      if (res.status === 429) throw new Error("Too many questions. Wait a minute.");
      if (!res.ok) throw new Error("Muse could not answer right now.");
      const data = await res.json();
      answer.className = "answer";
      answer.textContent = data.answer;
    } catch (e) { answer.className = "answer muted"; answer.textContent = e.message; }
  };
}

async function loadAlerts() {
  try {
    const a = await api("/guardian/api/alerts");
    $("alertCard").classList.toggle("hidden", !a.available);
    if (!a.available) return;
    $("alertText").textContent = a.linked
      ? "You will get a Telegram message with the live link the moment an SOS starts."
      : "Open Telegram once and press Start. After that you are messaged the moment an SOS starts.";
    $("alertLink").href = a.link;
    $("alertLink").classList.toggle("hidden", a.linked);
  } catch (e) { $("alertCard").classList.add("hidden"); }
}

async function loadList() {
  loadAlerts();
  const data = await api("/guardian/api/incidents");
  const box = $("items");
  box.innerHTML = "";
  if (!data.incidents.length) {
    box.innerHTML = '<p class="sub">No recordings yet. When the person you protect starts a stream or an SOS, it appears here.</p>';
  }
  for (const i of data.incidents) {
    const row = document.createElement("div");
    row.className = "item";
    const live = i.status === "active";
    row.innerHTML = '<div><b>' + (i.mode === "live" ? "Live stream" : "SOS") + ' · ' + escapeHtml(i.wearer_name) +
      '</b><span>' + fmtDate(i.started_at) + ' · ' + fmtDur(i.started_at, i.ended_at) + '</span></div>' +
      '<div style="text-align:right"><span class="pill ' + (live ? "live" : "") + '">' + (live ? "LIVE NOW" : "ended") +
      '</span><br><span>' + (i.continuous ? 'continuous recording · ' : i.videos + ' video · ' + i.audios + ' audio · ') + fmtSize(i.bytes) + '</span></div>';
    row.onclick = () => openIncident(i.id);
    box.appendChild(row);
  }
  show("list");
}

function escapeHtml(t) { return String(t).replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

async function openIncident(id) {
  const d = await api("/guardian/api/incidents/" + encodeURIComponent(id));
  $("dTitle").textContent = (d.mode === "live" ? "Live stream" : "SOS") + " · " + d.wearer_name;
  $("dMeta").textContent = fmtDate(d.started_at) + " · " + fmtDur(d.started_at, d.ended_at) +
    (d.status === "active" ? " · still live" : "");
  show("detail");
  const at = d.latest ? [d.latest.lat, d.latest.lon] : null;
  if (!map) {
    map = L.map("map").setView(at || [20, 78], at ? 16 : 4);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {maxZoom: 19,
      attribution: "&copy; OpenStreetMap contributors"}).addTo(map);
  }
  if (layer) layer.remove();
  layer = L.layerGroup().addTo(map);
  if (at) {
    L.marker(at).addTo(layer);
    const line = (d.trail || []).map((p) => [p.lat, p.lon]);
    if (line.length > 1) {
      const path = L.polyline(line, {color: "#ff4d4d", weight: 4}).addTo(layer);
      map.fitBounds(path.getBounds(), {padding: [28, 28], maxZoom: 17});
    } else {
      map.setView(at, 16);
    }
  }
  setTimeout(() => map.invalidateSize(), 50);
  renderLog(d.items, d.id);
  if (guardianHls) { guardianHls.destroy(); guardianHls = null; }
  if (d.hls && playContinuous(d.hls)) return;
  $("audioCard").classList.remove("hidden");
  $("playAll").classList.remove("hidden");
  const videos = d.segments.filter((s) => s.kind === "video");
  const audios = d.segments.filter((s) => s.kind === "audio");
  renderSegs("videos", videos, (s) => { queue = [s]; current = 0; playIndex(); });
  renderSegs("audios", audios, (s) => { $("audioPlayer").src = s.url; $("audioPlayer").play(); });
  queue = videos; current = 0;
  $("player").src = videos.length ? videos[0].url : "";
  $("playing").textContent = videos.length ? "Part 1 of " + videos.length : "No video was saved for this incident.";
  $("playAll").onclick = () => { current = 0; playIndex(); };
}

function playContinuous(info) {
  const video = $("player");
  if (video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = info.url;
  } else if (window.Hls && Hls.isSupported()) {
    guardianHls = new Hls({maxBufferLength: 30});
    guardianHls.loadSource(info.url);
    guardianHls.attachMedia(video);
  } else {
    return false;
  }
  $("audioCard").classList.add("hidden");
  $("playAll").classList.add("hidden");
  $("videos").innerHTML = "";
  $("playing").textContent = info.over
    ? "One continuous recording, with sound, from start to finish."
    : "Live now: one continuous recording with sound, a few seconds behind.";
  return true;
}

function renderSegs(boxId, list, onPick) {
  const box = $(boxId);
  box.innerHTML = "";
  for (const s of list) {
    const row = document.createElement("div");
    row.className = "seg";
    row.innerHTML = "<a href='#'>Part " + (s.seq + 1) + "</a><span>" + fmtSize(s.bytes) + "</span>";
    row.querySelector("a").onclick = (e) => { e.preventDefault(); onPick(s); };
    box.appendChild(row);
  }
}

function playIndex() {
  if (current >= queue.length) return;
  $("player").src = queue[current].url;
  $("playing").textContent = "Part " + (queue[current].seq + 1) + " of " + queue.length;
  $("player").play().catch(() => {});
}
$("player").addEventListener("ended", () => { current += 1; playIndex(); });

async function enter(code) {
  CODE = code;
  try {
    await loadList();
    sessionStorage.setItem("guardianCode", CODE);
  } catch (err) {
    sessionStorage.removeItem("guardianCode");
    CODE = "";
    $("loginErr").textContent = err.message;
    show("login");
  }
}

$("open").onclick = () => enter($("code").value.trim());
$("code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("open").click(); });
$("reload").onclick = () => loadList().catch((e) => alert(e.message));
$("back").onclick = () => loadList();
$("signout").onclick = () => { sessionStorage.removeItem("guardianCode"); CODE = ""; $("code").value = ""; show("login"); };
$("mint").onclick = async () => {
  $("mintErr").textContent = "";
  try {
    const res = await fetch("/guardian/register", {method: "POST"});
    if (res.status === 429) throw new Error("Too many codes requested. Try again later.");
    if (!res.ok) throw new Error("Could not make a code.");
    const data = await res.json();
    $("mintedCode").textContent = data.code;
    $("minted").classList.remove("hidden");
    $("code").value = data.code;
  } catch (err) { $("mintErr").textContent = err.message; }
};

if (CODE) enter(CODE); else show("login");
</script>
</body>
</html>
"""
