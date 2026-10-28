
import base64
import io
import logging
import os
import tempfile
import time

logger = logging.getLogger("safeguard.sam2")

try:
    import torch
    from PIL import Image
    from sam2.build_sam import build_sam2_video_predictor

    _IMPORTS_OK = True
    _IMPORT_ERROR = ""
except Exception as exc:  # noqa: BLE001 - optional dependency by design
    torch = None  # type: ignore[assignment]
    Image = None  # type: ignore[assignment]
    build_sam2_video_predictor = None  # type: ignore[assignment]
    _IMPORTS_OK = False
    _IMPORT_ERROR = str(exc)


class Sam2Unavailable(Exception):
    pass


class Sam2Runner:

    def __init__(
        self,
        checkpoint_path: str,
        model_cfg: str,
        max_latency_s: float = 3.0,
        retry_after_s: float = 600.0,
        corridor_half_width: float = 0.18,
        max_objects: int = 4,
    ):
        self.checkpoint_path = checkpoint_path
        self.model_cfg = model_cfg
        self.max_latency_s = max_latency_s
        self.retry_after_s = retry_after_s
        self.corridor_half_width = corridor_half_width
        self.max_objects = max_objects
        self._predictor = None
        self._skip_until = 0.0

    @property
    def available(self) -> bool:
        return (
            _IMPORTS_OK
            and bool(self.checkpoint_path)
            and os.path.exists(self.checkpoint_path)
        )

    def unavailable_reason(self) -> str:
        if not _IMPORTS_OK:
            return f"sam2/torch not importable: {_IMPORT_ERROR}"
        if not self.checkpoint_path:
            return "SAM2_CHECKPOINT_PATH is not set"
        return f"checkpoint not found: {self.checkpoint_path}"

    def _ensure_predictor(self):
        if self._predictor is not None:
            return self._predictor
        device = "cuda" if torch.cuda.is_available() else "cpu"
        self._predictor = build_sam2_video_predictor(
            self.model_cfg, self.checkpoint_path, device=device
        )
        return self._predictor

    def run(
        self, frames_b64: list[str], boxes_xyxy: list[list[float]]
    ) -> tuple[dict, float]:
        if not self.available:
            raise Sam2Unavailable(self.unavailable_reason())
        now = time.monotonic()
        if now < self._skip_until:
            raise Sam2Unavailable("sticky skip after a slow/failed attempt")
        started = time.monotonic()
        try:
            geometry = self._run_once(frames_b64, boxes_xyxy)
        except Exception as exc:
            self._skip_until = time.monotonic() + self.retry_after_s
            raise Sam2Unavailable(f"SAM 2 failed: {exc}") from exc
        latency = time.monotonic() - started
        if latency > self.max_latency_s:
            self._skip_until = time.monotonic() + self.retry_after_s
        return geometry, latency

    def _run_once(
        self, frames_b64: list[str], boxes_xyxy: list[list[float]]
    ) -> dict:
        predictor = self._ensure_predictor()
        with tempfile.TemporaryDirectory(prefix="sg_verify_") as frame_dir:
            width, height = write_frames(frames_b64, frame_dir)
            with torch.inference_mode():
                state = predictor.init_state(frame_dir)
                prompts = boxes_xyxy[: self.max_objects]
                for object_id, box in enumerate(prompts, start=1):
                    predictor.add_new_points_or_box(
                        inference_state=state,
                        frame_idx=0,
                        obj_id=object_id,
                        box=box,
                    )
                areas: dict[int, list[float]] = {i: [] for i in range(1, len(prompts) + 1)}
                centroids: dict[int, list[list[float]]] = {
                    i: [] for i in range(1, len(prompts) + 1)
                }
                corridor_hits: dict[int, int] = {
                    i: 0 for i in range(1, len(prompts) + 1)
                }
                frames_seen = 0
                for _, object_ids, masks in predictor.propagate_in_video(state):
                    frames_seen += 1
                    for object_id, mask in zip(object_ids, masks):
                        oid = int(object_id)
                        binary = (mask.detach().cpu().numpy() > 0).reshape(-1)
                        area, centroid, corridor = mask_stats(
                            binary, width, height, self.corridor_half_width
                        )
                        areas[oid].append(area)
                        centroids[oid].append(centroid)
                        corridor_hits[oid] += corridor
        objects = []
        for oid in areas:
            first = areas[oid][0] if areas[oid] else 0.0
            last = areas[oid][-1] if areas[oid] else 0.0
            growth = (last / first - 1.0) if first > 0 else 0.0
            overlap = corridor_hits[oid] / frames_seen if frames_seen else 0.0
            objects.append(
                {
                    "id": oid,
                    "mask_area_growth": growth,
                    "centroid_path": centroids[oid],
                    "corridor_overlap": overlap,
                    "blocks_corridor": bool(overlap > 0.3 and growth >= 0),
                }
            )
        return {"frames": frames_seen, "objects": objects}


def write_frames(frames_b64: list[str], frame_dir: str) -> tuple[int, int]:
    width = height = 0
    for index, blob in enumerate(frames_b64):
        image = Image.open(io.BytesIO(base64.b64decode(blob))).convert("RGB")
        width, height = image.size
        image.save(os.path.join(frame_dir, f"{index:05d}.jpg"), "JPEG")
    return width, height


def mask_stats(flat, width: int, height: int, corridor_half_width: float):
    total = flat.size
    area = float(flat.sum()) / total if total else 0.0
    if flat.sum() == 0:
        return 0.0, [0.5, 0.5], 0
    idx = flat.nonzero()[0]
    ys = (idx // width).astype(float) / max(height - 1, 1)
    xs = (idx % width).astype(float) / max(width - 1, 1)
    cx, cy = float(xs.mean()), float(ys.mean())
    in_corridor = (xs > 0.5 - corridor_half_width) & (xs < 0.5 + corridor_half_width)
    corridor = 1 if in_corridor.mean() > 0.5 else 0
    return area, [cx, cy], corridor
