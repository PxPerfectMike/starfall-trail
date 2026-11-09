"""Renders the Starfall Trail 3D arrow into rotation sprite sheets.

A faceted, hovering arrow is rasterized with perspective at FRAME_COUNT
rotations around the vertical axis. Frame k is rotated k * 360 / FRAME_COUNT
degrees counterclockwise (seen from above), which matches WoW's facing
convention: frame 0 points straight ahead (into the screen), and a positive
relative angle means the target is to the left.

Outputs (in StarfallTrail/Media):
	arrow.png  lit gold body with a soft ground shadow (normal blend)
	glow.png   white halo whose alpha is the glow (ADD blend, tinted in-game)
	spark.png  small soft sparkle for particles
	ring.png   soft ring for the arrival marker
and Starfall Trail/Frames.lua with the arrow tip position per frame.
"""

import math
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

FRAME_COUNT = 200          # 1.8 degrees apart; frames are never blended, so this sets the smoothness
FRAMES_PER_SHEET = 100
GRID = 10
CELL = 204
SHEET = 2048
GLOW_STEP = 2              # the blurry glow only needs every second angle
GLOW_CELL = CELL // 2
GLOW_SHEET = 1024
SS = 3  # supersampling factor
HOVER = 0.30

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "StarfallTrail", "Media")


def normalize(v):
	return v / np.linalg.norm(v, axis=-1, keepdims=True)


def build_mesh():
	"""Returns a list of (triangle vertices 3x3, kind) with kind 'top' or 'side'."""
	half = {
		"T": (0.0, 1.00),
		"B": (0.60, 0.08),
		"N": (0.19, 0.27),
		"S": (0.19, -0.48),
		"E": (0.36, -0.95),
		"C": (0.0, -0.64),
	}
	edge_z = HOVER + 0.05
	z_of = {"T": HOVER + 0.07, "C": HOVER + 0.09}

	def pt(name, mirror=False):
		x, y = half[name]
		if mirror:
			x = -x
		return np.array([x, y, z_of.get(name, edge_z)])

	p1 = np.array([0.0, 0.30, HOVER + 0.21])
	p2 = np.array([0.0, -0.46, HOVER + 0.17])

	tris = []
	for mirror in (False, True):
		t, b, n, s, e, c = (pt(k, mirror) for k in "TBNSEC")
		for tri in ((t, b, p1), (b, n, p1), (n, s, p2), (n, p2, p1), (s, e, p2), (e, c, p2)):
			tris.append((np.array(tri), "top"))

	outline_names = ["T", "B", "N", "S", "E", "C"]
	outline = [pt(k) for k in outline_names] + [pt(k, True) for k in reversed(outline_names[1:5])]
	area = 0.0
	for i in range(len(outline)):
		a, b = outline[i], outline[(i + 1) % len(outline)]
		area += a[0] * b[1] - b[0] * a[1]
	if area < 0:
		outline.reverse()  # make it counterclockwise seen from above

	bottom_z = HOVER - 0.04
	for i in range(len(outline)):
		a, b = outline[i], outline[(i + 1) % len(outline)]
		a_bot = np.array([a[0], a[1], bottom_z])
		b_bot = np.array([b[0], b[1], bottom_z])
		tris.append((np.array([a, b, b_bot]), "side"))
		tris.append((np.array([a, b_bot, a_bot]), "side"))
	return tris, outline


def face_normal(tri, kind, outline_ccw=True):
	n = np.cross(tri[1] - tri[0], tri[2] - tri[0])
	n = n / np.linalg.norm(n)
	if kind == "top" and n[2] < 0:
		n = -n
	if kind == "side":
		# Outward for a counterclockwise outline: the edge direction rotated clockwise.
		edge = tri[1] - tri[0]
		out = np.array([edge[1], -edge[0], 0.0])
		if np.dot(n, out) < 0:
			n = -n
	return n


class Camera:
	def __init__(self, pitch_deg=36.0, dist=3.1, fov_deg=44.0, target=(0.0, 0.0, HOVER)):
		p = math.radians(pitch_deg)
		self.target = np.array(target)
		self.pos = self.target + np.array([0.0, -dist * math.cos(p), dist * math.sin(p)])
		f = normalize(self.target - self.pos)
		r = normalize(np.cross(f, np.array([0.0, 0.0, 1.0])))
		u = np.cross(r, f)
		self.f, self.r, self.u = f, r, u
		self.tan = math.tan(math.radians(fov_deg) / 2)

	def project(self, pts):
		v = pts - self.pos
		xc = v @ self.r
		yc = v @ self.u
		zc = v @ self.f
		return xc / zc / self.tan, yc / zc / self.tan, zc


def rotate_z(pts, ang):
	c, s = math.cos(ang), math.sin(ang)
	m = np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])
	return pts @ m.T


def light_dir():
	return normalize(np.array([-0.45, -0.35, 0.82]))


def rasterize(tris, cam, size, scale):
	"""Z-buffered rasterization. Returns coverage, normals and world positions per pixel."""
	depth = np.full((size, size), np.inf)
	normal = np.zeros((size, size, 3))
	world = np.zeros((size, size, 3))
	kind_side = np.zeros((size, size), dtype=bool)
	ys, xs = np.mgrid[0:size, 0:size]
	px = xs + 0.5
	py = ys + 0.5
	for verts, kind, n in tris:
		sx, sy, zc = cam.project(verts)
		X = size / 2 + sx * scale
		Y = size / 2 - sy * scale
		x0 = max(int(math.floor(X.min())), 0)
		x1 = min(int(math.ceil(X.max())) + 1, size)
		y0 = max(int(math.floor(Y.min())), 0)
		y1 = min(int(math.ceil(Y.max())) + 1, size)
		if x0 >= x1 or y0 >= y1:
			continue
		gx = px[y0:y1, x0:x1]
		gy = py[y0:y1, x0:x1]
		den = (Y[1] - Y[2]) * (X[0] - X[2]) + (X[2] - X[1]) * (Y[0] - Y[2])
		if abs(den) < 1e-9:
			continue
		w0 = ((Y[1] - Y[2]) * (gx - X[2]) + (X[2] - X[1]) * (gy - Y[2])) / den
		w1 = ((Y[2] - Y[0]) * (gx - X[2]) + (X[0] - X[2]) * (gy - Y[2])) / den
		w2 = 1.0 - w0 - w1
		inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
		if not inside.any():
			continue
		# Perspective-correct interpolation.
		iw = w0 / zc[0] + w1 / zc[1] + w2 / zc[2]
		z = 1.0 / iw
		pw0 = w0 / zc[0] * z
		pw1 = w1 / zc[1] * z
		pw2 = w2 / zc[2] * z
		region = depth[y0:y1, x0:x1]
		closer = inside & (z < region)
		if not closer.any():
			continue
		region[closer] = z[closer]
		normal[y0:y1, x0:x1][closer] = n
		wp = pw0[..., None] * verts[0] + pw1[..., None] * verts[1] + pw2[..., None] * verts[2]
		world[y0:y1, x0:x1][closer] = wp[closer]
		kind_side[y0:y1, x0:x1][closer] = kind == "side"
	cover = np.isfinite(depth)
	return cover, normal, world, kind_side


def shade(cover, normal, world, kind_side, cam):
	gold = np.array([1.00, 0.70, 0.16])
	gold_dark = np.array([0.48, 0.24, 0.05])
	L = light_dir()
	V = normalize(cam.pos - world)
	H = normalize(L + V)
	ndl = np.clip(normal @ L, 0.0, 1.0)
	ndh = np.clip(np.sum(normal * H, axis=-1), 0.0, 1.0)
	ndv = np.clip(np.sum(normal * V, axis=-1), 0.0, 1.0)
	sky = np.clip(normal[..., 2], 0.0, 1.0)

	albedo = np.where(kind_side[..., None], gold_dark, gold)
	diffuse = albedo * (0.10 + 0.22 * sky[..., None] + 1.05 * ndl[..., None] ** 1.4)
	spec = (ndh ** 90)[..., None] * np.array([1.0, 0.97, 0.88]) * 1.8
	broad = (ndh ** 14)[..., None] * gold * 0.45
	rim = ((1.0 - ndv) ** 3)[..., None] * np.array([1.0, 0.86, 0.55]) * 0.55
	color = diffuse + spec + broad + rim
	# Gentle filmic shoulder so highlights roll off instead of clipping.
	color = 1.0 - np.exp(-color * 1.35)
	color[~cover] = 0.0
	return color


def downsample(img, factor):
	h, w = img.shape[:2]
	return img.reshape(h // factor, factor, w // factor, factor, *img.shape[2:]).mean(axis=(1, 3))


def shadow_mask(tris, cam, size, scale):
	"""Footprint of the top surface cast along the light onto the ground plane z = 0."""
	L = light_dir()
	flat = []
	for verts, kind, n in tris:
		if kind != "top":
			continue
		t = verts[:, 2] / L[2]
		ground = verts - t[:, None] * L
		ground[:, 2] = 0.0
		flat.append((ground, "top", np.array([0.0, 0.0, 1.0])))
	cover, _, _, _ = rasterize(flat, cam, size, scale)
	return cover.astype(float)


def find_scale(mesh, cam, size, margin):
	"""Pixels per projected unit so every rotation, its shadow and glow fit in the cell."""
	extent = 0.0
	L = light_dir()
	for k in range(FRAME_COUNT):
		ang = 2 * math.pi * k / FRAME_COUNT
		for verts, kind, _ in mesh:
			rv = rotate_z(verts, ang)
			sx, sy, _ = cam.project(rv)
			extent = max(extent, np.abs(sx).max(), np.abs(sy).max())
			if kind == "top":
				t = rv[:, 2] / L[2]
				g = rv - t[:, None] * L
				g[:, 2] = 0.0
				gx, gy, _ = cam.project(g)
				extent = max(extent, np.abs(gx).max(), np.abs(gy).max())
	return (size / 2 - margin) / extent


def render_frames():
	tris, _ = build_mesh()
	mesh = [(v, k, face_normal(v, k)) for v, k in tris]
	cam = Camera()
	size = CELL * SS
	scale = find_scale(mesh, cam, size, margin=26 * SS)

	body_sheets = [np.zeros((SHEET, SHEET, 4)) for _ in range(FRAME_COUNT // FRAMES_PER_SHEET)]
	glow_sheet = np.zeros((GLOW_SHEET, GLOW_SHEET, 4))

	for k in range(FRAME_COUNT):
		ang = 2 * math.pi * k / FRAME_COUNT
		rot = [(rotate_z(v, ang), kind, rotate_z(n[None, :], ang)[0]) for v, kind, n in mesh]
		cover, normal, world, side = rasterize(rot, cam, size, scale)
		color = shade(cover, normal, world, side, cam)

		shadow = shadow_mask(rot, cam, size, scale)
		shadow = gaussian_filter(shadow, sigma=5 * SS) * 0.55

		alpha = cover.astype(float)
		rgb = color
		# Thin dark outline keeps the arrow readable over bright scenery.
		outline = np.clip(gaussian_filter(alpha, sigma=1.4 * SS) * 3.0, 0, 1) * 0.85
		outline_rgb = np.array([0.16, 0.08, 0.02])
		# Layers back to front: shadow (black), outline (dark brown), body.
		under_a = outline + shadow * (1 - outline)
		under_rgb = np.where(under_a[..., None] > 0, outline[..., None] * outline_rgb / np.maximum(under_a[..., None], 1e-6), 0)
		out_a = alpha + under_a * (1 - alpha)
		out_rgb = np.where(
			out_a[..., None] > 0,
			(rgb * alpha[..., None] + under_rgb * under_a[..., None] * (1 - alpha[..., None])) / np.maximum(out_a[..., None], 1e-6),
			0,
		)

		# A tight halo with one fixed gain for every angle. Normalizing per frame boosted the
		# compact end-on angles (pointing straight up or down) into a blob around the arrow.
		glow = np.clip(gaussian_filter(alpha, sigma=4 * SS) * 1.5, 0, 1) * 0.8

		cell_rgba = downsample(np.dstack([out_rgb, out_a]), SS)
		sheet = body_sheets[k // FRAMES_PER_SHEET]
		local = k % FRAMES_PER_SHEET
		gx, gy = (local % GRID) * CELL, (local // GRID) * CELL
		sheet[gy:gy + CELL, gx:gx + CELL] = cell_rgba

		if k % GLOW_STEP == 0:
			g = k // GLOW_STEP
			gx, gy = (g % GRID) * GLOW_CELL, (g // GRID) * GLOW_CELL
			glow_sheet[gy:gy + GLOW_CELL, gx:gx + GLOW_CELL, :3] = 1.0
			glow_sheet[gy:gy + GLOW_CELL, gx:gx + GLOW_CELL, 3] = downsample(glow, SS * 2)
		sys.stdout.write(f"\rframe {k + 1}/{FRAME_COUNT}")
		sys.stdout.flush()
	print()
	return body_sheets, glow_sheet


def save_rgba(arr, path):
	img = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
	Image.fromarray(img, "RGBA").save(path, optimize=True)


def make_mote(size=64):
	"""Soft glowing mote for the ground trail: a bright core inside a gentle halo."""
	y, x = np.mgrid[0:size, 0:size] + 0.5
	r = np.hypot(x - size / 2, y - size / 2) / (size / 2)
	a = np.clip(np.exp(-(r / 0.16) ** 2) + np.exp(-(r / 0.45) ** 2) * 0.45, 0, 1)
	a[r > 1] = 0
	return np.dstack([np.ones_like(a), np.ones_like(a), np.ones_like(a), a])


def make_sparkle(size=64):
	"""Four-point star with soft flares, for twinkling trail particles."""
	y, x = np.mgrid[0:size, 0:size] + 0.5
	dx, dy = (x - size / 2) / (size / 2), (y - size / 2) / (size / 2)
	r = np.hypot(dx, dy)
	core = np.exp(-(r / 0.12) ** 2)
	halo = np.exp(-(r / 0.35) ** 2) * 0.35
	flare_h = np.exp(-(dy / 0.045) ** 2) * np.exp(-(np.abs(dx) / 0.75) ** 1.5)
	flare_v = np.exp(-(dx / 0.045) ** 2) * np.exp(-(np.abs(dy) / 0.75) ** 1.5)
	a = np.clip(core + halo + 0.85 * (flare_h + flare_v), 0, 1)
	a[r > 1] = 0
	return np.dstack([np.ones_like(a), np.ones_like(a), np.ones_like(a), a])


def make_ring(size=256):
	y, x = np.mgrid[0:size, 0:size] + 0.5
	r = np.hypot(x - size / 2, y - size / 2) / (size / 2)
	ring = np.exp(-((r - 0.78) / 0.07) ** 2)
	inner = np.exp(-((r - 0.78) / 0.22) ** 2) * 0.35
	a = np.clip(ring + inner, 0, 1)
	return np.dstack([np.ones_like(a), np.ones_like(a), np.ones_like(a), a])


def write_lua(path, sheet_count):
	lines = [
		"-- Generated by tools/render_arrow.py. Do not edit by hand.",
		"local _, ns = ...",
		f"ns.FRAME_COUNT = {FRAME_COUNT}",
		f"ns.FRAMES_PER_SHEET = {FRAMES_PER_SHEET}",
		f"ns.SHEET_COUNT = {sheet_count}",
		f"ns.GRID = {GRID}",
		f"ns.CELL = {CELL}",
		f"ns.SHEET = {SHEET}",
		f"ns.GLOW_STEP = {GLOW_STEP}",
		f"ns.GLOW_CELL = {GLOW_CELL}",
		f"ns.GLOW_SHEET = {GLOW_SHEET}",
	]
	with open(path, "w", newline="\n", encoding="utf-8") as fh:
		fh.write("\n".join(lines) + "\n")


def main():
	os.makedirs(MEDIA, exist_ok=True)
	for stale in ("arrow.png", "spark.png"):
		path = os.path.join(MEDIA, stale)
		if os.path.exists(path):
			os.remove(path)
	bodies, glow = render_frames()
	for i, body in enumerate(bodies, start=1):
		save_rgba(body, os.path.join(MEDIA, f"arrow{i}.png"))
	save_rgba(glow, os.path.join(MEDIA, "glow.png"))
	save_rgba(make_ring(), os.path.join(MEDIA, "ring.png"))
	save_rgba(make_mote(), os.path.join(MEDIA, "mote.png"))
	save_rgba(make_sparkle(), os.path.join(MEDIA, "sparkle.png"))
	write_lua(os.path.join(ROOT, "StarfallTrail", "Frames.lua"), len(bodies))
	print("wrote", MEDIA)


if __name__ == "__main__":
	main()
