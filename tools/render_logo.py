"""Renders the CurseForge logo (400x400): the addon's own 3D arrow over a night sky, with a curving
trail of the addon's sparkles leading up to it. Everything is drawn here or by render_arrow.py;
no game art is used.

	python tools/render_logo.py [angle_degrees]     -> branding/logo.png
"""

import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy.ndimage import gaussian_filter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_arrow as ra  # noqa: E402

SIZE = 400
SS = 3
OUT = os.path.join(ra.ROOT, "branding", "logo.png")


def sky(size):
	"""Deep indigo at the top fading to violet near the bottom, with a soft glow behind the arrow."""
	y = np.linspace(0, 1, size)[:, None]
	x = np.linspace(0, 1, size)[None, :]
	top = np.array([0.04, 0.03, 0.12])
	bottom = np.array([0.20, 0.09, 0.30])
	rgb = top + (bottom - top) * (y[..., None] ** 1.3)
	rgb = np.broadcast_to(rgb, (size, size, 3)).copy()
	glow = np.exp(-(((x - 0.58) ** 2) + ((y - 0.40) ** 2)) / 0.06)
	rgb += glow[..., None] * np.array([0.30, 0.22, 0.10])
	rng = random.Random(7)
	for _ in range(70):
		sx, sy = rng.randrange(size), rng.randrange(int(size * 0.7))
		b = rng.uniform(0.25, 0.8)
		rgb[sy, sx] = np.maximum(rgb[sy, sx], b)
	return np.clip(rgb, 0, 1)


def arrow(size, angle):
	tris, _ = ra.build_mesh()
	mesh = [(v, k, ra.face_normal(v, k)) for v, k in tris]
	cam = ra.Camera()
	big = size * SS
	scale = ra.find_scale(mesh, cam, big, margin=20 * SS)
	rot = [(ra.rotate_z(v, angle), kind, ra.rotate_z(n[None, :], angle)[0]) for v, kind, n in mesh]
	cover, normal, world, side = ra.rasterize(rot, cam, big, scale)
	color = ra.shade(cover, normal, world, side, cam)
	alpha = cover.astype(float)
	outline = np.clip(gaussian_filter(alpha, sigma=1.6 * SS) * 3.0, 0, 1) * 0.9
	outline_rgb = np.array([0.16, 0.08, 0.02])
	out_a = alpha + outline * (1 - alpha)
	out_rgb = np.where(out_a[..., None] > 0,
		(color * alpha[..., None] + outline_rgb * (outline * (1 - alpha))[..., None]) / np.maximum(out_a[..., None], 1e-6), 0)
	halo = np.clip(gaussian_filter(alpha, sigma=10 * SS) * 1.4, 0, 1) * 0.55
	return ra.downsample(np.dstack([out_rgb, out_a]), SS), ra.downsample(halo[..., None], SS)[..., 0]


def paste_sparkles(rgb, size):
	"""A curved dotted trail of sparkles from the lower left up toward the arrow, growing as it nears."""
	spark = np.asarray(Image.open(os.path.join(ra.MEDIA, "sparkle.png")).convert("RGBA"), dtype=float) / 255
	rng = random.Random(3)
	n = 26
	for i in range(n):
		t = i / (n - 1)
		# Quadratic curve: lower left -> sweep right -> up under the arrow.
		p0, p1, p2 = (0.10, 0.95), (0.55, 0.92), (0.52, 0.62)
		x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
		y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
		x += rng.uniform(-0.025, 0.025)
		y += rng.uniform(-0.02, 0.02)
		s = int(10 + 26 * t ** 1.2 * rng.uniform(0.7, 1.1))
		img = np.asarray(Image.fromarray((spark * 255).astype(np.uint8)).resize((s, s), Image.LANCZOS), dtype=float) / 255
		warm = rng.random()
		tint = np.array([1.0, 0.8 + 0.18 * warm, 0.42 + 0.45 * warm])
		a = img[..., 3] * (0.55 + 0.45 * t)
		cx, cy = int(x * size) - s // 2, int(y * size) - s // 2
		x0, y0 = max(cx, 0), max(cy, 0)
		x1, y1 = min(cx + s, size), min(cy + s, size)
		if x1 <= x0 or y1 <= y0:
			continue
		sub = a[y0 - cy:y1 - cy, x0 - cx:x1 - cx, None]
		col = img[y0 - cy:y1 - cy, x0 - cx:x1 - cx, :3] * tint
		# Additive glow, like the addon's sparkles.
		rgb[y0:y1, x0:x1] = np.clip(rgb[y0:y1, x0:x1] + col * sub, 0, 1)
	return rgb


def main():
	angle = math.radians(float(sys.argv[1])) if len(sys.argv) > 1 else math.radians(-35)
	rgb = sky(SIZE)
	rgb = paste_sparkles(rgb, SIZE)
	body, halo = arrow(int(SIZE * 0.78), angle)
	h, w = body.shape[:2]
	ox, oy = int(SIZE * 0.60 - w / 2), int(SIZE * 0.40 - h / 2)
	region = (slice(max(oy, 0), oy + h), slice(max(ox, 0), ox + w))
	rgb[region] = np.clip(rgb[region] + halo[..., None] * np.array([1.0, 0.78, 0.35]), 0, 1)
	a = body[..., 3:4]
	rgb[region] = rgb[region] * (1 - a) + body[..., :3] * a
	os.makedirs(os.path.dirname(OUT), exist_ok=True)
	img = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8), "RGB")
	img = img.filter(ImageFilter.UnsharpMask(radius=1, percent=40, threshold=2))
	img.save(OUT)
	print("wrote", OUT, img.size)


if __name__ == "__main__":
	main()
