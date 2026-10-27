"""One continuous recording from the phone's fragmented-MP4 pieces.

The phone writes a single stream (video and sound together) as an
initialisation segment (`init.mp4`) plus short media segments named
`seg-<seq>-<duration in ms>.m4s`. This module turns whatever has arrived into
an HLS playlist: an EVENT playlist while the stream is live (players follow
the live edge and can still seek back) and a VOD playlist once it is over, so
the same URL plays the whole thing as one video. Pure: no I/O.
"""

import math
import re

INIT_NAME = "init.mp4"
_SEG_RE = re.compile(r"^seg-(\d{5})-(\d{2,6})\.m4s$")

# No new piece for this long while the stream is "active" means the phone
# stopped (broken, no signal): the playlist is closed so players finish
# instead of waiting for ever.
STALL_SECONDS = 45


def parse_segment(name: str):
    """(sequence, duration in ms) for a media segment name, else None."""
    match = _SEG_RE.match(name)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def is_hls_name(name: str) -> bool:
    return name == INIT_NAME or parse_segment(name) is not None


def media_type(name: str) -> str | None:
    """Content type for a servable recording file, or None."""
    if is_hls_name(name):
        return "video/mp4"
    if re.match(r"^video-\d{5}\.mp4$", name):
        return "video/mp4"
    if re.match(r"^audio-\d{5}\.m4a$", name):
        return "audio/mp4"
    return None


def segment_name(seq: int, duration_ms: int) -> str:
    return f"seg-{seq:05d}-{duration_ms:04d}.m4s"


def collect(entries: list[dict]):
    """(has_init, ordered [(seq, duration_ms, name)]) from stored files."""
    has_init = any(e["name"] == INIT_NAME for e in entries)
    segments = []
    for entry in entries:
        parsed = parse_segment(entry["name"])
        if parsed:
            segments.append((parsed[0], parsed[1], entry["name"]))
    segments.sort()
    return has_init, segments


def last_activity(entries: list[dict]) -> float:
    return max((e.get("mtime") or 0 for e in entries if is_hls_name(e["name"])), default=0)


def is_over(incident_ended: bool, entries: list[dict], now: float) -> bool:
    """Finished for the viewer: the incident ended, or the phone went quiet."""
    if incident_ended:
        return True
    last = last_activity(entries)
    return bool(last) and now - last > STALL_SECONDS


def build_playlist(entries: list[dict], url_for, over: bool) -> str | None:
    """The HLS playlist text, or None when there is nothing playable yet.

    `url_for(name)` gives the URI to write for a file (relative for the
    family page, signed for the guardian page).
    """
    has_init, segments = collect(entries)
    if not has_init or not segments:
        return None
    target = max(1, math.ceil(max(d for _, d, _ in segments) / 1000))
    map_line = f'#EXT-X-MAP:URI="{url_for(INIT_NAME)}"'
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        f"#EXT-X-TARGETDURATION:{target}",
        f"#EXT-X-MEDIA-SEQUENCE:{segments[0][0]}",
        f"#EXT-X-PLAYLIST-TYPE:{'VOD' if over else 'EVENT'}",
        map_line,
    ]
    previous = segments[0][0] - 1
    for seq, duration_ms, name in segments:
        if seq != previous + 1:
            # A piece never arrived (upload still retrying): say so.
            lines.append("#EXT-X-DISCONTINUITY")
            lines.append(map_line)
        lines.append(f"#EXTINF:{duration_ms / 1000:.3f},")
        lines.append(url_for(name))
        previous = seq
    if over:
        lines.append("#EXT-X-ENDLIST")
    return "\n".join(lines) + "\n"
