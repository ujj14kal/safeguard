"""Geometry math on synthetic masks (numpy only; no torch needed)."""

import numpy as np

from app.sam2_local import mask_stats


def rect_mask(width, height, x0, y0, x1, y1):
    flat = np.zeros(height * width, dtype=bool)
    grid = flat.reshape(height, width)
    grid[y0:y1, x0:x1] = True
    return flat


def test_full_mask():
    area, centroid, corridor = mask_stats(
        np.ones(100 * 100, dtype=bool), 100, 100, 0.18
    )
    assert area == 1.0
    assert centroid == [0.5, 0.5]
    assert corridor == 0  # spread everywhere: no corridor majority


def test_empty_mask():
    assert mask_stats(np.zeros(100 * 100, dtype=bool), 100, 100, 0.18) == (
        0.0,
        [0.5, 0.5],
        0,
    )


def test_centered_mask_blocks_corridor():
    area, centroid, corridor = mask_stats(
        rect_mask(100, 100, 40, 20, 60, 80), 100, 100, 0.18
    )
    assert area == 0.12
    assert abs(centroid[0] - 0.5) < 0.02
    assert corridor == 1


def test_side_mask_does_not_block():
    area, centroid, corridor = mask_stats(
        rect_mask(100, 100, 0, 20, 10, 80), 100, 100, 0.18
    )
    assert area == 0.06
    assert centroid[0] < 0.2
    assert corridor == 0
