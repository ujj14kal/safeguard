"""Family live viewer: one self-contained page per share token.

Leaflet + OpenStreetMap from a pinned CDN; everything else inline. The
video is segment-based (8 s parts), so the page says "about 10-15 s
behind" and never "real-time". It always plays the newest parts and skips
ones it fell behind on, so a family member sees what is happening now, not
the beginning of the recording.
"""

import json

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
    <p class="behind">Segment-based recording, about 10-15 s behind. It always jumps to the newest part.</p>
  </div>
  <div class="card">
    <h2>Audio</h2>
    <audio id="audio" controls preload="none"></audio>
    <p class="behind">Audio parts, newest first when it falls behind.</p>
  </div>
  <div class="err" id="err"></div>
</main>
<script src="__LEAFLET_JS__"></script>
<script>
const TOKEN = __TOKEN__;
// The page lives at /live/<token> (no trailing slash), so relative URLs
// would resolve to /live/state. Build them from the page path instead.
const BASE = location.pathname.replace(/\/+$/, "");
let map = null, marker = null, circle = null, trailLine = null;
let seen = {}, videoQueue = [], audioQueue = [], lastFixAt = 0, lastOk = 0;

function showError(text) {
  const box = document.getElementById("err");
  box.style.display = "block";
  box.textContent = text;
}

// Live behaviour: keep only the newest parts so the viewer never plays the
// recording from its beginning while the wearer is somewhere else now.
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
  const ended = state.status === "ended";
  document.getElementById("statusText").textContent = ended ? "SOS ENDED" : "SOS ACTIVE";
  pill.className = "pill " + (ended ? "ended" : "active");
  document.getElementById("who").textContent =
    "Live view: " + (state.wearer_name || "wearer");
  const when = state.started_at
    ? new Date(state.started_at * 1000).toLocaleString() : "";
  document.getElementById("meta").textContent =
    "Started " + when + (ended ? " \u00b7 ended" : " \u00b7 updating every 2 s");
  if (state.latest) showLocation(state.latest, state.trail || []);
  for (const seg of state.segments || []) {
    if (seen[seg.name]) continue;
    seen[seg.name] = true;
    (seg.kind === "video" ? videoQueue : audioQueue).push(BASE + "/" + seg.url);
  }
  // Skip what we fell behind on: keep the two newest parts of each.
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
