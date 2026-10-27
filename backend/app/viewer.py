"""Family live viewer: one self-contained page per share token.

Leaflet + OpenStreetMap from a pinned CDN; everything else inline. The
video is segment-based (8 s parts), so the page says "about 10-15 s
behind" and never "real-time".
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
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Safeguard live view</title>
<link rel="stylesheet" href="{LEAFLET_CSS}">
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin: 0; padding: 12px; background: #0d0a12; color: #e8e2f0;
         font-family: -apple-system, system-ui, sans-serif; }}
  main {{ max-width: 640px; margin: 0 auto; }}
  .pill {{ display: inline-block; padding: 4px 14px; border-radius: 999px;
          font-weight: 700; }}
  .active {{ background: #ff4d4d; color: #fff; }}
  .ended {{ background: #3a3344; color: #cfc8dc; }}
  h1 {{ font-size: 20px; margin: 10px 0 2px; }}
  .sub {{ color: #9d94ad; font-size: 13px; margin: 0 0 12px; }}
  #map {{ height: 300px; border-radius: 12px; background: #1a1422; }}
  .card {{ background: #1a1422; border-radius: 12px; padding: 12px;
          margin-top: 12px; }}
  .card h2 {{ font-size: 15px; margin: 0 0 8px; color: #b98dd1; }}
  video, audio {{ width: 100%; border-radius: 8px; }}
  .behind {{ color: #9d94ad; font-size: 13px; }}
  .err {{ display: none; background: #3a1a1a; border-radius: 12px;
         padding: 12px; margin-top: 12px; }}
</style>
</head>
<body>
<main>
  <span id="status" class="pill active">SOS ACTIVE</span>
  <h1 id="who">Live view</h1>
  <p class="sub" id="meta">connecting&hellip;</p>
  <div id="map"></div>
  <div class="card">
    <h2>Video</h2>
    <video id="video" controls playsinline></video>
    <p class="behind">Segment-based recording, about 10-15 s behind. Newest parts play in order.</p>
  </div>
  <div class="card">
    <h2>Audio</h2>
    <audio id="audio" controls preload="none"></audio>
    <p class="behind">Audio parts, oldest first.</p>
  </div>
  <div class="err" id="err"></div>
</main>
<script src="{LEAFLET_JS}"></script>
<script>
const TOKEN = {token_json};
let map = null, marker = null, trailLine = null;
let seen = {{}}, videoQueue = [], audioQueue = [];

function showError(text) {{
  const box = document.getElementById("err");
  box.style.display = "block";
  box.textContent = text;
}}

function playNext(player, queue) {{
  if (queue.length === 0 || !player.paused) return;
  player.src = queue.shift();
  player.play().catch(() => {{}});
}}

function setupPlayer(id, kind) {{
  const player = document.getElementById(id);
  player.addEventListener("ended", () => {{
    playNext(player, kind === "video" ? videoQueue : audioQueue);
  }});
  return player;
}}
const videoEl = setupPlayer("video", "video");
const audioEl = setupPlayer("audio", "audio");

async function refresh() {{
  let state;
  try {{
    const res = await fetch("state", {{cache: "no-store"}});
    if (!res.ok) throw new Error("page link is no longer valid");
    state = await res.json();
  }} catch (err) {{
    showError("Lost connection to the backend. Retrying&hellip;");
    return;
  }}
  document.getElementById("err").style.display = "none";
  const pill = document.getElementById("status");
  const ended = state.status === "ended";
  pill.textContent = ended ? "SOS ENDED" : "SOS ACTIVE";
  pill.className = "pill " + (ended ? "ended" : "active");
  document.getElementById("who").textContent =
    "Live view: " + (state.wearer_name || "wearer");
  const when = state.started_at
    ? new Date(state.started_at * 1000).toLocaleString() : "";
  document.getElementById("meta").textContent =
    "Started " + when + (ended ? " · ended" : " · updating every 2 s");
  if (state.latest) {{
    const at = [state.latest.lat, state.latest.lon];
    if (!map) {{
      map = L.map("map").setView(at, 16);
      L.tileLayer("https://tile.openstreetmap.org/{{z}}/{{x}}/{{y}}.png", {{
        maxZoom: 19, attribution: "&copy; OpenStreetMap contributors"
      }}).addTo(map);
    }} else {{
      map.setView(at);
    }}
    if (marker) marker.setLatLng(at); else marker = L.marker(at).addTo(map);
    const line = (state.trail || []).map(p => [p.lat, p.lon]);
    if (trailLine) trailLine.setLatLngs(line);
    else if (line.length > 1) trailLine = L.polyline(line, {{color: "#ff4d4d"}}).addTo(map);
  }}
  for (const seg of state.segments || []) {{
    if (seen[seg.name]) continue;
    seen[seg.name] = true;
    (seg.kind === "video" ? videoQueue : audioQueue).push(seg.url);
  }}
  playNext(videoEl, videoQueue);
  playNext(audioEl, audioQueue);
}}
setInterval(refresh, 2000);
refresh();
</script>
</body>
</html>
"""
