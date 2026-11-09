"""Cleans a road map (build_navgrid.py --roadmask) before the walkable-area generator reads it.

Painted ground textures are speckled: single pixels of "road" in a meadow and grass tufts on a road
split the generator's regions into thousands of tiny polygons. This smooths each class with a
majority filter, then drops road patches too small to matter. Road texture painted at partial
strength (road edges, worn stretches) counts as road too, so the output has one class.

Usage: python clean_roadmask.py roadmask_0001.raw.bin roadmask_0001.bin
"""

import struct
import sys

import numpy as np
from scipy import ndimage

ROAD, TRAIL = 160, 90          # thresholds the patched generator uses (TileBuilder.cpp)
INPUT_ROAD = 100               # road texture strength (0..255) counted as road here
RADIUS = 2                     # majority filter radius in pixels (1.04 yards each)
MIN_ROAD = 60                  # smallest patch kept, in pixels (about 65 square yards)
BAND = 2048                    # rows per pass, to keep memory low


def clean(src, dst):
	with open(src, "rb") as fh:
		header = fh.read(20)
		x0, y0, step, nx, ny = struct.unpack("<fffII", header)
		data = np.frombuffer(fh.read(), dtype=np.uint8).reshape(ny, nx)
	print(f"{nx} x {ny}, road {np.mean(data >= ROAD):.2%}, trail {np.mean((data >= TRAIL) & (data < ROAD)):.2%}")
	size = 2 * RADIUS + 1
	cls = np.zeros((ny, nx), dtype=np.uint8)    # 0 ground, 1 trail, 2 road
	for r0 in range(0, ny, BAND):
		a, b = max(0, r0 - RADIUS), min(ny, r0 + BAND + RADIUS)
		band = data[a:b]
		road = ndimage.uniform_filter((band >= INPUT_ROAD).astype(np.float32), size) > 0.5
		out = np.where(road, 2, 0).astype(np.uint8)
		cls[r0:min(ny, r0 + BAND)] = out[r0 - a:r0 - a + min(BAND, ny - r0)]
	for value, minimum in ((2, MIN_ROAD),):
		mask = cls == value
		labels, count = ndimage.label(mask)
		sizes = np.bincount(labels.ravel())
		small = sizes < minimum
		small[0] = False
		drop = small[labels]
		cls[drop] = 0
		print(f"class {value}: {count} patches, {int(small.sum())} dropped")
	out = np.where(cls == 2, 255, np.where(cls == 1, 120, 0)).astype(np.uint8)
	print(f"cleaned: road {np.mean(out >= ROAD):.2%}, trail {np.mean((out >= TRAIL) & (out < ROAD)):.2%}")
	with open(dst, "wb") as fh:
		fh.write(header)
		fh.write(out.tobytes())


if __name__ == "__main__":
	clean(sys.argv[1], sys.argv[2])
