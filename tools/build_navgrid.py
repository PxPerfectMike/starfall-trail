"""Builds Starfall Trail's navigation grid for a zone from WoW Forever's terrain files.

For every terrain vertex (about 4.17 yards apart) it records the height and a travel cost
derived from the painted ground texture (roads are cheap), water depth and slope. The result
is packed into a Lua data file the addon reads lazily with string.byte, so loading is instant.

Grid coordinates use HereBeDragons' world convention (x grows west, y grows north):
	world x of column i = X0 - i * STEP, world y of row j = Y0 - j * STEP.
"""

import argparse
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from casc import CascError, CascStore, iter_chunks  # noqa: E402

TILE = 1600.0 / 3.0            # 533.333 yards
CHUNK = TILE / 16.0            # 33.333 yards
STEP = CHUNK / 8.0             # 4.1667 yards between outer vertices
VERTS = 128                    # vertices per tile edge (the 129th is the next tile's first)
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

ZONES = {
	# name: (wdt FileDataID, instance id, tile column range, tile row range, minimum height kept)
	"Teldrassil": (782779, 1, (23, 33), (8, 19), 300.0),
	# Whole continents (used with --roadmask-only for the walkable-area generator).
	"Kalimdor": (782779, 1, (0, 49), (0, 56), None),
	"EasternKingdoms": (775971, 0, (23, 46), (20, 62), None),
}


def load_listfile(path):
	names = {}
	with open(path, encoding="utf-8", errors="replace") as fh:
		for line in fh:
			fid, _, name = line.rstrip("\n").partition(";")
			if fid.isdigit():
				names[int(fid)] = name
	return names


def decode_alpha(raw, offset, layer_flags, big_alpha):
	"""Returns a 64x64 float array (0..1) for one texture layer's blend map."""
	if layer_flags & 0x200:  # run-length compressed, always 8-bit
		out = bytearray()
		pos = offset
		while len(out) < 4096 and pos < len(raw):
			b = raw[pos]
			pos += 1
			count = b & 0x7F
			if b & 0x80:
				out += bytes([raw[pos]]) * count
				pos += 1
			else:
				out += raw[pos:pos + count]
				pos += count
		arr = np.frombuffer(bytes(out[:4096]).ljust(4096, b"\0"), dtype=np.uint8)
		return arr.reshape(64, 64) / 255.0
	if big_alpha:
		arr = np.frombuffer(raw[offset:offset + 4096].ljust(4096, b"\0"), dtype=np.uint8)
		return arr.reshape(64, 64) / 255.0
	packed = np.frombuffer(raw[offset:offset + 2048].ljust(2048, b"\0"), dtype=np.uint8)
	lo = packed & 0x0F
	hi = packed >> 4
	arr = np.empty(4096, dtype=np.uint8)
	arr[0::2] = lo
	arr[1::2] = hi
	return arr.reshape(64, 64) / 15.0


def road_weight(name):
	"""1 for roads and paths, 0 for everything else.

	Plain dirt is not counted: across Kalimdor and the Eastern Kingdoms it is ordinary ground (a
	quarter of the Barrens and Westfall), not a trail.
	"""
	n = name.lower().rsplit("/", 1)[-1]
	if any(word in n for word in ("road", "path", "cobble", "brick", "pavement", "street")):
		return 1.0
	return 0.0


def parse_tile(store, ids, names, big_alpha, full=None):
	"""Returns per-tile arrays sized 129x129: height, road weight, water surface height (nan if none)."""
	height = np.zeros((129, 129), dtype=np.float64)
	road = np.zeros((129, 129), dtype=np.float64)
	water = np.full((129, 129), np.nan)

	root = store.read_fdid(ids[0])
	chunks = [p for m, p in iter_chunks(root) if m == "MCNK"]
	mh2o = next((p for m, p in iter_chunks(root) if m == "MH2O"), None)
	for payload in chunks:
		ix, iy = struct.unpack("<II", payload[4:12])
		base_z = struct.unpack("<f", payload[112:116])[0]
		sub = dict(iter_chunks(payload[128:]))
		vals = struct.unpack("<145f", sub["MCVT"][:580])
		k = 0
		for r in range(17):
			if r % 2 == 0:
				for c in range(9):
					height[iy * 8 + r // 2, ix * 8 + c] = base_z + vals[k]
					k += 1
			else:
				k += 8  # inner vertices are skipped; the outer grid is enough at 4 yards

	if mh2o:
		for n in range(256):
			off_inst, layer_count, _off_attr = struct.unpack("<III", mh2o[n * 12:n * 12 + 12])
			if not layer_count:
				continue
			cy, cx = divmod(n, 16)
			for layer in range(layer_count):
				p = off_inst + layer * 24
				_ltype, _fmt, min_h, max_h, xo, yo, w, h = struct.unpack("<HHffBBBB", mh2o[p:p + 16])
				level = max_h if abs(max_h) < 1e6 else min_h
				for yy in range(yo, yo + h + 1):
					for xx in range(xo, xo + w + 1):
						r, c = cy * 8 + yy, cx * 8 + xx
						if r < 129 and c < 129:
							cur = water[r, c]
							water[r, c] = level if np.isnan(cur) else max(cur, level)

	tex = store.read_fdid(ids[3])
	tex_chunks = dict()
	tex_ids = []
	tex_list = [(m, p) for m, p in iter_chunks(tex)]
	for m, p in tex_list:
		if m == "MDID":
			tex_ids = list(struct.unpack(f"<{len(p) // 4}I", p))
	road_tex = {i: road_weight(names.get(fid, "")) for i, fid in enumerate(tex_ids)}
	road_tex = {i: w for i, w in road_tex.items() if w > 0}
	mcnk_tex = [p for m, p in tex_list if m == "MCNK"]
	if road_tex:
		for n, payload in enumerate(mcnk_tex):
			cy, cx = divmod(n, 16)
			sub = dict(iter_chunks(payload))
			mcly = sub.get("MCLY", b"")
			mcal = sub.get("MCAL", b"")
			layers = [struct.unpack("<IIII", mcly[i:i + 16]) for i in range(0, len(mcly), 16)]
			if not layers:
				continue
			alphas = []
			for li, (tid, flags, offset, _effect) in enumerate(layers):
				if li == 0:
					alphas.append(None)
				else:
					alphas.append(decode_alpha(mcal, offset, flags, big_alpha) if flags & 0x100 else np.zeros((64, 64)))
			# The base layer shows wherever the layers above it do not.
			others = sum(a for a in alphas[1:]) if len(alphas) > 1 else np.zeros((64, 64))
			base = np.clip(1.0 - others, 0, 1)
			weight = np.zeros((64, 64))
			for li, (tid, _f, _o, _e) in enumerate(layers):
				if tid in road_tex:
					weight += road_tex[tid] * (base if li == 0 else alphas[li])
			weight = np.clip(weight, 0, 1)
			if full is not None:
				full[cy * 64:(cy + 1) * 64, cx * 64:(cx + 1) * 64] = weight
			# Sample a 3x3 texel neighbourhood around each of the chunk's 9x9 outer vertices.
			padded = np.pad(weight, 1, mode="edge")
			for r in range(9):
				for c in range(9):
					ty, tx = min(r * 8, 63) + 1, min(c * 8, 63) + 1
					road[cy * 8 + r, cx * 8 + c] = padded[ty - 1:ty + 2, tx - 1:tx + 2].mean()
	return height, road, water, len(road_tex) > 0


def apply_wmos(store, maid, cols, rows, x_origin, y_origin, Hf, keep, depth, names, with_walls=True):
	"""Rasterizes every WMO placed on the zone's tiles into the grid.

	Returns (surface heights, paved mask, walled mask). A cell takes a WMO floor when that floor
	sits at ground level (paved ground) or when the ground is unusable (blocked, wet, missing)
	and a floor spans it (bridge decks). Walls block a cell when they cross body height above
	its chosen surface; low railings do not.
	"""
	import wmo  # local import keeps casc-only users free of the dependency

	ny, nx = Hf.shape
	floors = {}
	walls = {}
	seen = set()
	placements = 0

	def cell_range(lo, hi, origin, n):
		a = int(np.floor((origin - hi) / STEP + 0.5))
		b = int(np.floor((origin - lo) / STEP + 0.5))
		return max(a, 0), min(b, n - 1)

	for row in range(*rows):
		for col in range(*cols):
			ids = struct.unpack("<8I", maid[(row * 64 + col) * 32:(row * 64 + col) * 32 + 32])
			if not ids[1]:
				continue
			for magic, payload in iter_chunks(store.read_fdid(ids[1])):
				if magic != "MODF":
					continue
				for e in wmo.parse_modf(payload):
					if e["uid"] in seen:
						continue
					seen.add(e["uid"])
					tris, _flags, _fit, err = wmo.placed_triangles(store, e["fid"], e["pos"], e["rot"], e["scale"], e["extents"])
					if tris is None or len(tris) == 0 or err > 5:
						continue
					placements += 1
					a, b = tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]
					n = np.cross(a, b)
					length = np.linalg.norm(n, axis=1)
					ok = length > 1e-9
					nz = np.zeros(len(tris))
					nz[ok] = np.abs(n[ok, 2]) / length[ok]
					for t in np.nonzero(ok & (nz > 0.72))[0]:
						_raster_floor(tris[t], x_origin, y_origin, nx, ny, floors)
					if with_walls:
						for t in np.nonzero(ok & (nz < 0.35))[0]:
							_raster_wall(tris[t], x_origin, y_origin, nx, ny, walls)

	surface = Hf.copy()
	paved = np.zeros_like(keep)
	walled = np.zeros_like(keep)
	for k, zs in floors.items():
		j, i = divmod(k, nx)
		t = Hf[j, i]
		ground_ok = keep[j, i] and depth[j, i] < 0.3
		at_ground = [z for z in zs if t - 1.5 <= z <= t + 2.5]
		above = sorted(z for z in zs if z > t - 1.5)
		if at_ground:
			surface[j, i] = max(at_ground)
			paved[j, i] = True
		elif not ground_ok and above:
			surface[j, i] = above[0]
			paved[j, i] = True
	for k, spans in walls.items():
		j, i = divmod(k, nx)
		s = surface[j, i]
		# A real wall rises from near the floor to above head height; railings and knee walls do not.
		if any(lo < s + 0.8 and hi > s + 2.6 for lo, hi in spans):
			walled[j, i] = True
	print(f"WMOs: {placements} placements, {len(floors)} floor cells, {int(paved.sum())} paved, {int(walled.sum())} walled")
	return surface, paved, walled


def _raster_floor(tri, x0, y0, nx, ny, floors):
	"""Records the triangle's height at every grid cell centre it covers."""
	ci = (x0 - tri[:, 0]) / STEP
	cj = (y0 - tri[:, 1]) / STEP
	i0, i1 = int(np.floor(ci.min())), int(np.ceil(ci.max()))
	j0, j1 = int(np.floor(cj.min())), int(np.ceil(cj.max()))
	i0, j0, i1, j1 = max(i0, 0), max(j0, 0), min(i1, nx - 1), min(j1, ny - 1)
	if i0 > i1 or j0 > j1:
		return
	den = (cj[1] - cj[2]) * (ci[0] - ci[2]) + (ci[2] - ci[1]) * (cj[0] - cj[2])
	if abs(den) < 1e-12:
		return
	jj, ii = np.mgrid[j0:j1 + 1, i0:i1 + 1]
	w0 = ((cj[1] - cj[2]) * (ii - ci[2]) + (ci[2] - ci[1]) * (jj - cj[2])) / den
	w1 = ((cj[2] - cj[0]) * (ii - ci[2]) + (ci[0] - ci[2]) * (jj - cj[2])) / den
	w2 = 1 - w0 - w1
	inside = (w0 >= -0.05) & (w1 >= -0.05) & (w2 >= -0.05)
	if not inside.any():
		return
	z = w0 * tri[0, 2] + w1 * tri[1, 2] + w2 * tri[2, 2]
	for j, i, zz in zip(jj[inside], ii[inside], z[inside]):
		floors.setdefault(int(j) * nx + int(i), []).append(float(zz))


def _raster_wall(tri, x0, y0, nx, ny, walls):
	"""Records, per cell, the height span of the part of a steep triangle that lies in that cell."""
	edge = max(np.linalg.norm(tri[1] - tri[0]), np.linalg.norm(tri[2] - tri[0]), np.linalg.norm(tri[2] - tri[1]))
	steps = max(2, int(edge / 0.75) + 1)  # sample about every 0.75 yards so per-cell spans are accurate
	spans = {}
	for a in range(steps + 1):
		for b in range(steps + 1 - a):
			u, v = a / steps, b / steps
			p = tri[0] + (tri[1] - tri[0]) * u + (tri[2] - tri[0]) * v
			i = int(np.floor((x0 - p[0]) / STEP + 0.5))
			j = int(np.floor((y0 - p[1]) / STEP + 0.5))
			if 0 <= i < nx and 0 <= j < ny:
				k = j * nx + i
				z = float(p[2])
				cur = spans.get(k)
				spans[k] = (z, z) if cur is None else (min(cur[0], z), max(cur[1], z))
	for k, span in spans.items():
		walls.setdefault(k, []).append(span)


def build(zone, listfile, out_path, wow_root, roadmask=None, roadmask_only=False, ground_path=None):
	wdt_id, instance, (c0, c1), (r0, r1), min_keep = ZONES[zone]
	store = CascStore(wow_root, "wowf")
	names = load_listfile(listfile)
	wdt = dict(iter_chunks(store.read_fdid(wdt_id)))
	mphd_flags = struct.unpack("<I", wdt["MPHD"][:4])[0]
	big_alpha = bool(mphd_flags & 0x4 or mphd_flags & 0x80)
	maid = wdt["MAID"]

	cols, rows = c1 - c0, r1 - r0
	size_x, size_y = cols * VERTS + 1, rows * VERTS + 1
	H = np.full((size_y, size_x), np.nan, dtype=np.float32)
	R = np.zeros((size_y, size_x), dtype=np.float32)
	W = np.full((size_y, size_x), np.nan, dtype=np.float32)
	# Optional fine road map (for the walkable-area generator): 512 x 512 per tile (1.04 yards).
	MASK = 512
	F = np.zeros((rows * MASK, cols * MASK), dtype=np.uint8) if roadmask else None
	tiles = 0
	for row in range(r0, r1):
		for col in range(c0, c1):
			ids = struct.unpack("<8I", maid[(row * 64 + col) * 32:(row * 64 + col) * 32 + 32])
			if not ids[0]:
				continue
			try:
				full = np.zeros((1024, 1024)) if roadmask else None
				h, rd, wt, has_road = parse_tile(store, ids, names, big_alpha, full)
				if roadmask:
					small = full.reshape(MASK, 2, MASK, 2).mean(axis=(1, 3))
					F[(row - r0) * MASK:(row - r0 + 1) * MASK, (col - c0) * MASK:(col - c0 + 1) * MASK] = np.round(small * 255).astype(np.uint8)
			except CascError as err:
				print(f"  tile {col},{row}: skipped ({err})")
				continue
			y0, x0 = (row - r0) * VERTS, (col - c0) * VERTS
			H[y0:y0 + 129, x0:x0 + 129] = h
			R[y0:y0 + 129, x0:x0 + 129] = np.maximum(R[y0:y0 + 129, x0:x0 + 129], rd)
			W[y0:y0 + 129, x0:x0 + 129] = wt
			tiles += 1
			print(f"  tile {col},{row}: z {np.nanmin(h):.0f}..{np.nanmax(h):.0f}, road textures: {'yes' if has_road else 'no'}")
	print(f"{tiles} tiles, big alpha: {big_alpha}")

	keep = ~np.isnan(H) if min_keep is None else np.nan_to_num(H, nan=-1e9) > min_keep
	ys, xs = np.nonzero(keep)
	ya, yb, xa, xb = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
	H, R, W, keep = H[ya:yb, xa:xb], R[ya:yb, xa:xb], W[ya:yb, xa:xb], keep[ya:yb, xa:xb]
	ny, nx = H.shape
	Hf = np.nan_to_num(H, nan=-10000.0)
	depth = np.nan_to_num(W - Hf, nan=0.0)

	# World origin of grid cell (0, 0) in HereBeDragons coordinates.
	x_origin = (32 - c0) * TILE - xa * STEP
	y_origin = (32 - r0) * TILE - ya * STEP

	# Buildings, bridges and walkways (WMOs): decks over ravines and water become paved cells at
	# deck height; walls at body height block cells.
	surface, paved, walled = apply_wmos(store, maid, (c0, c1), (r0, r1), x_origin, y_origin, Hf, keep, depth, names,
		with_walls=not roadmask_only)
	Hf = surface
	keep = keep | paved
	depth = np.where(paved, 0.0, depth)
	R = np.where(paved, 1.0, R)

	if roadmask:
		# City pavement (WMO floors at ground level) counts as road too.
		per = MASK * STEP / TILE   # mask pixels per grid step (4)
		for j, i in zip(*np.nonzero(paved)):
			cy, cx = (ya + j) * per, (xa + i) * per
			F[max(0, int(cy - per / 2)):int(cy + per / 2), max(0, int(cx - per / 2)):int(cx + per / 2)] = 255
		with open(roadmask, "wb") as fh:
			fh.write(struct.pack("<fffII", (32 - c0) * TILE, (32 - r0) * TILE, TILE / MASK, F.shape[1], F.shape[0]))
			fh.write(F.tobytes())
		print(f"road map {F.shape[1]} x {F.shape[0]} written to {roadmask}")

	if ground_path:
		# Ground-surface heights every other grid vertex (8.3 yards), for build_navmesh.py's hint.
		g = np.where(keep, Hf, np.nan)[::2, ::2].astype(np.float32)
		np.savez_compressed(ground_path, ground=g, x0=x_origin, y0=y_origin, step=STEP * 2)
		print(f"ground hint {g.shape[1]} x {g.shape[0]} written to {ground_path}")
	if roadmask_only:
		return H, R, None

	# Slope in the gentlest axis: a bridge deck is flat along its length even with a drop beside it.
	# Steps that are too steep to walk are refused per move by the router instead.
	gy, gx = np.gradient(Hf, STEP)
	slope = np.degrees(np.arctan(np.minimum(np.abs(gx), np.abs(gy))))

	cost = 10.0 - 6.5 * np.clip(R, 0, 1)           # road 3.5, plain ground 10
	cost += np.clip((slope - 15.0) / 30.0, 0, None) ** 2 * 25.0
	cost += np.where(depth > 1.6, 30.0, np.where(depth > 0.3, 6.0, 0.0))
	blocked = (~keep) | (slope > 60.0) | (depth > 25.0) | walled
	code = np.where(blocked, 0, np.clip(np.round(cost), 1, 63)).astype(np.int64)

	zmin = float(np.min(Hf[keep]))
	hq = np.where(keep, np.clip(np.round((Hf - zmin) * 8.0), 0, 2 ** 18 - 1), 0).astype(np.int64)

	cost_str = "".join(B64[v] for v in code.ravel())
	h_flat = hq.ravel()
	height_str = "".join(B64[(v >> 12) & 63] + B64[(v >> 6) & 63] + B64[v & 63] for v in h_flat)

	road_share = float(np.mean(R[keep] > 0.5))
	walk_share = float(np.mean(code[keep] > 0))
	with open(out_path, "w", newline="\n", encoding="ascii") as fh:
		fh.write("-- Generated by tools/build_navgrid.py from WoW Forever terrain. Do not edit by hand.\n")
		fh.write("local _, ns = ...\n")
		fh.write("ns.Grids = ns.Grids or {}\n")
		fh.write(f"ns.Grids[\"{zone}\"] = {{\n")
		fh.write(f"\tinstance = {instance},\n\tx0 = {x_origin:.4f},\n\ty0 = {y_origin:.4f},\n\tstep = {STEP:.6f},\n")
		fh.write(f"\tnx = {nx},\n\tny = {ny},\n\tzmin = {zmin:.3f},\n")
		fh.write("\t-- cost: one base64 char per cell (0 = blocked); height: three chars per cell, (z - zmin) * 8\n")
		fh.write(f"\tcost = \"{cost_str}\",\n")
		fh.write(f"\theight = \"{height_str}\",\n")
		fh.write("}\n")
	print(f"grid {nx}x{ny} = {nx * ny} cells, kept {int(keep.sum())}, walkable {walk_share:.1%}, road {road_share:.1%}")
	print(f"origin x {x_origin:.1f} y {y_origin:.1f}, zmin {zmin:.1f}, file {os.path.getsize(out_path) / 1e6:.2f} MB")
	return H, R, code


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--zone", default="Teldrassil")
	ap.add_argument("--listfile", required=True)
	ap.add_argument("--out")
	ap.add_argument("--wow", default=r"D:\World of Warcraft")
	ap.add_argument("--roadmask-only", action="store_true", help="whole-continent mode: only the road map and ground hint")
	ap.add_argument("--ground", help="write the ground-surface hint (.npz) for build_navmesh.py")
	ap.add_argument("--preview")
	ap.add_argument("--roadmask", help="also write a fine road map for the walkable-area generator")
	args = ap.parse_args()
	H, R, code = build(args.zone, args.listfile, args.out, args.wow, args.roadmask, args.roadmask_only, args.ground)
	if args.preview and code is not None:
		from PIL import Image
		img = np.zeros(code.shape + (3,), dtype=np.uint8)
		hn = np.nan_to_num(H, nan=np.nanmin(H))
		hn = (hn - hn.min()) / max(np.ptp(hn), 1e-6)
		img[..., 0] = img[..., 1] = img[..., 2] = (hn * 160 + 40).astype(np.uint8)
		img[R > 0.5] = (230, 190, 70)
		img[code == 0] = (120, 20, 20)
		Image.fromarray(img).save(args.preview)


if __name__ == "__main__":
	main()
