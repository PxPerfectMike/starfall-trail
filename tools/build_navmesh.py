"""Builds a continent's navigation mesh from TrinityCore movement-map tiles (see tools/mmtile.py).

Steps: load every tile of the map, stitch polygons across tile borders, keep the walkable regions
that touch the ground (rooftops, treetops and canopies go; islands stay), give each polygon a
travel cost from its surface type (roads cheap, water dear), build a coarse spatial index, and
write a load-on-demand data addon (StarfallTrail_<Name>) the main addon loads when you enter the map.

The tiles come from TrinityCore's tools built with the Starfall Trail patches (Forever's Map.db2 layout,
road tagging): see tools/trinitycore/README.md.

Usage:
	python build_navmesh.py --map 1 --name Kalimdor --mmaps D:/wayfinder-tc/mmaps
		--ground D:/wayfinder-tc/ground_0001.npz --addon-dir ../StarfallTrail_Kalimdor
"""

import argparse
import glob
import heapq
import math
import os
import re
from collections import defaultdict, deque

import numpy as np

import mmtile

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
DT_EXT_LINK = 0x8000
AREA_WATER = 9          # TrinityCore NAV_AREA_WATER
BUCKET = 32.0           # yards per spatial index cell
QUANT = 8.0             # coordinates stored in 1/8 yards
TILE = 1600.0 / 3.0
CHUNK = 65536           # records per string chunk (no record straddles two chunks)
GROUND_NEAR = 6.0       # a polygon within this many yards of the ground surface counts as ground
SHORE = math.inf        # water polygons further than this from land are left out. Off: a band cut rivers and lakes
                        # you swim across, splitting whole areas off (about 48k polygons on Kalimdor)
CELL = 64.0             # yards per coarse routing cell (long routes search these first)
DIRS = ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1))

# Travel cost per polygon from its surface type. Roads (7) and dirt trails (6) were tagged by the
# patched generator from the fine road map (build_navgrid.py --roadmask); 11 is ground, 10 steep
# ground (55-70 degrees), 9 water.
AREA_COST = {7: 4, 6: 7, 11: 10, 10: 20, AREA_WATER: 30}


def enc(v, width):
	out = []
	for _ in range(width):
		out.append(B64[v & 63])
		v >>= 6
	if v:
		raise ValueError("value too large for width")
	return "".join(reversed(out))


def load_tiles(folder, map_id):
	tiles = {}
	for path in sorted(glob.glob(os.path.join(folder, f"{map_id:04d}_*.mmtile"))):
		m = re.search(r"_(\d+)_(\d+)\.mmtile$", path)
		tiles[(int(m.group(1)), int(m.group(2)))] = mmtile.load(path)
	return tiles


def load_ground(path):
	d = np.load(path)
	return d["ground"], float(d["x0"]), float(d["y0"]), float(d["step"])


def stitch(polys, index):
	"""Neighbors per edge: inside a tile from Detour's own links; across tile borders by matching
	edges that lie on the shared border and overlap (Detour stores those as external edges)."""
	neighbors = [[None] * len(p["verts"]) for p in polys]   # per edge: (neighbor id, t0, t1)
	border = defaultdict(list)   # (axis, border line, tile span along it) -> [(poly id, edge)]
	for gid, p in enumerate(polys):
		n = len(p["verts"])
		for e in range(n):
			nei = p["neis"][e]
			if nei == 0:
				continue
			if nei & DT_EXT_LINK:
				a, b = p["verts"][e], p["verts"][(e + 1) % n]
				if abs(a[0] - b[0]) < 1e-3:
					border[("x", round(a[0], 1), int((a[1] + b[1]) / 2 // TILE))].append((gid, e))
				elif abs(a[1] - b[1]) < 1e-3:
					border[("y", round(a[1], 1), int((a[0] + b[0]) / 2 // TILE))].append((gid, e))
			else:
				other = index.get((p["tile"], nei - 1))
				if other is not None:
					neighbors[gid][e] = (other, 0.0, 1.0)

	def z_at(u, v, w, along):
		span = v[along] - u[along]
		f = 0 if abs(span) < 1e-6 else (w - u[along]) / span
		return u[2] + (v[2] - u[2]) * f

	matched = unmatched = 0
	for (axis, _, _), edges in border.items():
		along = 1 if axis == "x" else 0     # the coordinate that varies along the border line
		for gid, e in edges:
			p = polys[gid]
			n = len(p["verts"])
			a, b = p["verts"][e], p["verts"][(e + 1) % n]
			lo, hi = sorted((a[along], b[along]))
			best = None
			for oid, oe in edges:
				if polys[oid]["tile"] == p["tile"]:
					continue
				q = polys[oid]
				m = len(q["verts"])
				c, d = q["verts"][oe], q["verts"][(oe + 1) % m]
				olo, ohi = sorted((c[along], d[along]))
				s, t_ = max(lo, olo), min(hi, ohi)
				if t_ - s < 0.2:
					continue
				# Heights must agree where the edges overlap (no linking a bridge to the ground below).
				mid = (s + t_) / 2
				if abs(z_at(a, b, mid, along) - z_at(c, d, mid, along)) > 3.0:
					continue
				if best is None or t_ - s > best[2] - best[1]:
					best = (oid, s, t_)
			if best:
				span = b[along] - a[along]
				f0, f1 = sorted(((best[1] - a[along]) / span, (best[2] - a[along]) / span))
				neighbors[gid][e] = (best[0], f0, f1)
				matched += 1
			else:
				unmatched += 1
	print(f"border edges matched {matched}, unmatched {unmatched}")
	return neighbors


def components(polys, neighbors):
	component = [-1] * len(polys)
	sizes = []
	for start in range(len(polys)):
		if component[start] >= 0:
			continue
		cid = len(sizes)
		count = 0
		queue = deque([start])
		component[start] = cid
		while queue:
			g = queue.popleft()
			count += 1
			for link in neighbors[g]:
				if link and component[link[0]] < 0:
					component[link[0]] = cid
					queue.append(link[0])
		sizes.append(count)
	return component, sizes


def coarse_cells(polys, kept, new_id, neighbors, x0, y0, x1, y1):
	"""A coarse grid over the mesh for long routes: per CELL-yard cell, the cheapest surface cost that
	covers a fair share of it, and which of its 8 neighbors you can walk to (from the polygons' own
	links, so walls, cliffs and water are respected)."""
	ncx = int((x1 - x0) // CELL) + 1
	ncy = int((y1 - y0) // CELL) + 1
	area = defaultdict(lambda: defaultdict(float))   # cell -> cost code -> square yards
	links = defaultdict(int)                          # cell -> neighbor bits

	def cell_of(x, y):
		return int((x - x0) // CELL), int((y - y0) // CELL)

	def link(a, b):
		dx, dy = b[0] - a[0], b[1] - a[1]
		if (dx, dy) == (0, 0) or max(abs(dx), abs(dy)) > 1:
			return
		links[a] |= 1 << DIRS.index((dx, dy))
		links[b] |= 1 << DIRS.index((-dx, -dy))

	covered = {}
	for g in kept:
		vs = polys[g]["verts"]
		n = len(vs)
		cx = sum(v[0] for v in vs) / n
		cy = sum(v[1] for v in vs) / n
		# Every cell the polygon touches: its corners, points along its edges, and cell centers inside it.
		cells = {cell_of(cx, cy)}
		for e in range(n):
			a, b = vs[e], vs[(e + 1) % n]
			steps = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) // 8))
			for s in range(steps + 1):
				t = s / steps
				cells.add(cell_of(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
		i0, j0 = cell_of(min(v[0] for v in vs), min(v[1] for v in vs))
		i1, j1 = cell_of(max(v[0] for v in vs), max(v[1] for v in vs))
		if (i0, j0) != (i1, j1):
			for i in range(i0, i1 + 1):
				for j in range(j0, j1 + 1):
					px, py = x0 + (i + 0.5) * CELL, y0 + (j + 0.5) * CELL
					sign = 0
					inside = True
					for e in range(n):
						a, b = vs[e], vs[(e + 1) % n]
						c = (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0])
						if c > 1e-9:
							if sign < 0:
								inside = False
								break
							sign = 1
						elif c < -1e-9:
							if sign > 0:
								inside = False
								break
							sign = -1
					if inside:
						cells.add((i, j))
		covered[g] = (cx, cy, cells)
		a2 = 0.0
		for e in range(n):
			a, b = vs[e], vs[(e + 1) % n]
			a2 += a[0] * b[1] - b[0] * a[1]
		code = AREA_COST.get(polys[g]["area"], 10)
		for c in cells:
			area[c][code] += abs(a2) / 2 / len(cells)
		cl = sorted(cells)
		for k in range(len(cl)):
			for m in range(k + 1, len(cl)):
				link(cl[k], cl[m])
	# Linked polygons share an edge, so the cells along it are in both polygons' sets already.
	rec = []
	for j in range(ncy):
		for i in range(ncx):
			shares = area.get((i, j))
			if not shares:
				rec.append("AAA")
				continue
			total = sum(shares.values())
			code = max(shares, key=lambda c: shares[c])
			for c in sorted(shares):
				if shares[c] >= 0.08 * total:
					code = c
					break
			rec.append(B64[code] + enc(links.get((i, j), 0), 2))
	print(f"coarse cells {ncx} x {ncy}, {len(area)} walkable")
	return rec, ncx, ncy


def build(args):
	tiles = load_tiles(args.mmaps, args.map)
	print(f"{len(tiles)} tiles")
	ground, gx0, gy0, gstep = load_ground(args.ground)
	gny, gnx = ground.shape

	def ground_at(x, y):
		i = int((gx0 - x) / gstep + 0.5)
		j = int((gy0 - y) / gstep + 0.5)
		if 0 <= i < gnx and 0 <= j < gny:
			z = ground[j, i]
			return None if np.isnan(z) else float(z)
		return None

	# Global polygon list in HereBeDragons coordinates (x = rx, y = rz, z = ry).
	polys = []
	index = {}         # (tile key, local poly) -> global id
	for key, t in tiles.items():
		for k, p in enumerate(t["polys"]):
			if p["type"] == 1:
				continue
			vs = [t["verts"][v] for v in p["verts"]]
			index[(key, k)] = len(polys)
			polys.append({"verts": [(v[0], v[2], v[1]) for v in vs], "area": p["area"], "tile": key, "neis": p["neis"]})
		t.clear()
	print(f"{len(polys)} polygons")

	neighbors = stitch(polys, index)

	# Keep regions that touch the ground: an island or a continent has many polygons on the ground
	# surface; a rooftop, a treetop or the upper levels of a tree house have none or few.
	component, sizes = components(polys, neighbors)
	on_ground = defaultdict(int)
	for g, p in enumerate(polys):
		vs = p["verts"]
		cx = sum(v[0] for v in vs) / len(vs)
		cy = sum(v[1] for v in vs) / len(vs)
		cz = sum(v[2] for v in vs) / len(vs)
		gz = ground_at(cx, cy)
		if gz is not None and abs(cz - gz) < GROUND_NEAR:
			on_ground[component[g]] += 1
	keep_components = {c for c in range(len(sizes)) if on_ground[c] >= args.min_ground and sizes[c] >= args.min_region}
	order = sorted(range(len(sizes)), key=lambda c: -sizes[c])
	print("largest regions (polygons, on ground):", [(sizes[c], on_ground[c]) for c in order[:10]])
	new_id = {}
	for g in range(len(polys)):
		if component[g] in keep_components:
			new_id[g] = len(new_id)
	print(f"kept {len(new_id)} of {len(polys)} polygons ({len(keep_components)} of {len(sizes)} regions)")

	# Water: keep a band along the shore (swimming across a river or a short stretch of coast), drop the
	# rest. Distances spread from land polygons through water polygons, centroid to centroid.
	cent = {}
	for g in new_id:
		vs = polys[g]["verts"]
		cent[g] = (sum(v[0] for v in vs) / len(vs), sum(v[1] for v in vs) / len(vs))
	dist = {}
	heap = []
	for g in new_id:
		if polys[g]["area"] != AREA_WATER:
			dist[g] = 0.0
			heap.append((0.0, g))
	heapq.heapify(heap)
	while heap:
		d, g = heapq.heappop(heap)
		if d > dist.get(g, math.inf):
			continue
		for link in neighbors[g]:
			if not link or link[0] not in new_id or polys[link[0]]["area"] != AREA_WATER:
				continue
			o = link[0]
			nd = d + math.dist(cent[g], cent[o])
			if nd <= SHORE and nd < dist.get(o, math.inf):
				dist[o] = nd
				heapq.heappush(heap, (nd, o))
	kept_ids = [g for g in sorted(new_id, key=lambda g: new_id[g]) if g in dist]
	new_id = {g: k for k, g in enumerate(kept_ids)}
	by_area = defaultdict(int)
	for g in new_id:
		by_area[polys[g]["area"]] += 1
	print(f"after the shore filter: {len(new_id)} polygons, by surface {dict(sorted(by_area.items()))}")
	if args.stats_only:
		return

	# Shared vertex pool for the kept polygons.
	kept = sorted(new_id, key=lambda g: new_id[g])
	xs = [v[0] for g in kept for v in polys[g]["verts"]]
	ys = [v[1] for g in kept for v in polys[g]["verts"]]
	zs = [v[2] for g in kept for v in polys[g]["verts"]]
	x0, y0, z0 = min(xs), min(ys), min(zs)
	if (max(xs) - x0) * QUANT >= 64 ** 3 or (max(ys) - y0) * QUANT >= 64 ** 3 or (max(zs) - z0) * QUANT >= 64 ** 3:
		raise ValueError("map too large for 3-character coordinates")
	vert_id = {}
	vert_list = []

	def vid(v):
		key = (round((v[0] - x0) * QUANT), round((v[1] - y0) * QUANT), round((v[2] - z0) * QUANT))
		if key not in vert_id:
			vert_id[key] = len(vert_list)
			vert_list.append(key)
		return vert_id[key]

	# Encoding: per polygon a fixed header in `polys` (offset into `edges`, edge count, cost), and
	# per edge in `edges`: vertex id (4 chars) + neighbor id (4 chars, 0 = wall, else id + 1).
	# Portal clips for partial border overlaps go in a small Lua table.
	poly_rec, edge_rec, clips = [], [], {}
	edge_offset = 0
	for g in kept:
		p = polys[g]
		n = len(p["verts"])
		poly_rec.append(enc(edge_offset, 5) + B64[n] + B64[AREA_COST.get(p["area"], 10)])
		for e in range(n):
			link = neighbors[g][e]
			nb = new_id.get(link[0]) if link else None
			edge_rec.append(enc(vid(p["verts"][e]), 4) + enc(0 if nb is None else nb + 1, 4))
			if nb is not None and (link[1] > 0.01 or link[2] < 0.99):
				clips[(new_id[g], e)] = (link[1], link[2])
		edge_offset += n
	print(f"{len(vert_list)} vertices, {edge_offset} edges, {len(clips)} clipped portals")
	vert_rec = [enc(x, 3) + enc(y, 3) + enc(z, 3) for x, y, z in vert_list]

	# Spatial index: polygons overlapping each BUCKET-yard cell.
	buckets = defaultdict(list)
	for g in kept:
		vs = polys[g]["verts"]
		bx0 = int((min(v[0] for v in vs) - x0) // BUCKET)
		bx1 = int((max(v[0] for v in vs) - x0) // BUCKET)
		by0 = int((min(v[1] for v in vs) - y0) // BUCKET)
		by1 = int((max(v[1] for v in vs) - y0) // BUCKET)
		for bx in range(bx0, bx1 + 1):
			for by in range(by0, by1 + 1):
				buckets[(bx, by)].append(new_id[g])
	nbx = int((max(xs) - x0) // BUCKET) + 1
	nby = int((max(ys) - y0) // BUCKET) + 1
	bucket_start, bucket_items = [], []
	count = 0
	ground_hint = []
	for by in range(nby):
		for bx in range(nbx):
			items = buckets.get((bx, by), [])
			bucket_start.append(enc(count, 4))
			bucket_items.extend(enc(v, 4) for v in items)
			count += len(items)
			# Ground-surface height at the bucket's middle: the guess for which level you stand on
			# before any height is known (not a tunnel below, not a walkway above). 1 yard steps.
			gz = ground_at(x0 + (bx + 0.5) * BUCKET, y0 + (by + 0.5) * BUCKET)
			ground_hint.append(enc(0 if gz is None else max(1, min(4095, round(gz - z0 + 100))), 2))
	bucket_start.append(enc(count, 4))

	# Connected pieces of the kept mesh, largest first: a route between two pieces cannot exist,
	# so the addon checks this before searching.
	comp = {}
	comp_sizes = []
	for g in kept:
		if g in comp:
			continue
		comp[g] = len(comp_sizes)
		queue = deque([g])
		count = 0
		while queue:
			h = queue.popleft()
			count += 1
			for link in neighbors[h]:
				if link and link[0] in new_id and link[0] not in comp:
					comp[link[0]] = comp[g]
					queue.append(link[0])
		comp_sizes.append(count)
	rank = {c: r for r, c in enumerate(sorted(range(len(comp_sizes)), key=lambda c: -comp_sizes[c]))}
	if len(rank) >= 64 ** 2:
		raise ValueError("too many separate pieces for 2-character ids")
	comp_rec = [enc(rank[comp[g]], 2) for g in kept]
	print(f"{len(comp_sizes)} connected pieces, largest {sorted(comp_sizes, reverse=True)[:6]}")

	cell_rec, ncx, ncy = coarse_cells(polys, kept, new_id, neighbors, x0, y0, max(xs), max(ys))

	def chunks(records):
		return "{\n" + "".join(f"\t\t\"{''.join(records[i:i + CHUNK])}\",\n" for i in range(0, len(records), CHUNK)) + "\t}"

	addon = os.path.basename(os.path.normpath(args.addon_dir))
	os.makedirs(args.addon_dir, exist_ok=True)
	out = os.path.join(args.addon_dir, "Mesh.lua")
	with open(out, "w", encoding="utf-8", newline="\n") as fh:
		fh.write("-- Generated by tools/build_navmesh.py from TrinityCore movement maps of the WoW Forever client. Do not edit.\n")
		fh.write("-- Every string list is split in chunks of 65536 records; record k is in chunk k // 65536 + 1.\n")
		fh.write("StarfallTrailMeshes = StarfallTrailMeshes or {}\n")
		fh.write(f"StarfallTrailMeshes[{args.map}] = {{\n")
		fh.write(f"\tname = \"{args.name}\", instance = {args.map}, x0 = {x0:.4f}, y0 = {y0:.4f}, z0 = {z0:.4f},\n")
		fh.write(f"\tquant = {QUANT}, bucket = {BUCKET}, nbx = {nbx}, nby = {nby}, chunk = {CHUNK},\n")
		fh.write(f"\tpolyCount = {len(new_id)}, vertCount = {len(vert_list)},\n")
		fh.write("\t-- verts: x, y, z (3 chars each, 1/8 yards from the origin above)\n")
		fh.write(f"\tverts = {chunks(vert_rec)},\n")
		fh.write("\t-- polys: first edge (5 chars), edge count (1), cost (1: 4 road, 7 trail, 10 ground, 30 water)\n")
		fh.write(f"\tpolys = {chunks(poly_rec)},\n")
		fh.write("\t-- edges: start vertex (4 chars), neighbor polygon + 1 across this edge (4 chars, 0 = wall)\n")
		fh.write(f"\tedges = {chunks(edge_rec)},\n")
		fh.write("\t-- spatial index: per bucket (row-major) start offset (4 chars) into items (4 chars per polygon)\n")
		fh.write(f"\tbucketStart = {chunks(bucket_start)},\n")
		fh.write(f"\tbucketItems = {chunks(bucket_items)},\n")
		fh.write("\t-- ground surface per bucket: 2 chars, z - z0 + 100 in yards (0 = unknown)\n")
		fh.write(f"\tground = {chunks(ground_hint)},\n")
		fh.write("\t-- connected piece per polygon (2 chars, 0 = the largest): no route between different pieces\n")
		fh.write(f"\tcomps = {chunks(comp_rec)},\n")
		fh.write(f"\t-- coarse routing cells ({CELL:.0f} yards, row-major from x0, y0): cheapest common cost (1 char, 0 = none),\n")
		fh.write("\t-- then links to the 8 neighbors (2 chars, bit k = direction k: E, NE, N, NW, W, SW, S, SE)\n")
		fh.write(f"\tcell = {CELL}, ncx = {ncx}, ncy = {ncy},\n")
		fh.write(f"\tcells = {chunks(cell_rec)},\n")
		fh.write("\t-- portals that only partly cover their edge: [poly * 8 + edge] = { from, to } (fractions)\n")
		fh.write("\tclips = {")
		fh.write(", ".join(f"[{p * 8 + e}] = {{ {a:.3f}, {b:.3f} }}" for (p, e), (a, b) in sorted(clips.items())))
		fh.write("},\n}\n")
	with open(os.path.join(args.addon_dir, addon + ".toc"), "w", encoding="utf-8", newline="\n") as fh:
		fh.write(f"## Interface: {args.interface}\n")
		fh.write(f"## Title: Starfall Trail |cff8fa3b8({args.title} paths)|r\n")
		fh.write(f"## Notes: Walkable-area map of {args.title} for Starfall Trail. Loads by itself when you are there.\n")
		fh.write("## Author: PxPerfectMike\n")
		fh.write(f"## Version: {args.version}\n")
		fh.write("## Dependencies: StarfallTrail\n")
		fh.write("## LoadOnDemand: 1\n")
		fh.write("\nMesh.lua\n")
	print(f"wrote {out}: {os.path.getsize(out) / 1e6:.2f} MB")


if __name__ == "__main__":
	ap = argparse.ArgumentParser()
	ap.add_argument("--map", type=int, required=True, help="map id (0 Eastern Kingdoms, 1 Kalimdor)")
	ap.add_argument("--name", required=True, help="short name, e.g. Kalimdor")
	ap.add_argument("--title", help="display name, e.g. \"Eastern Kingdoms\" (defaults to --name)")
	ap.add_argument("--mmaps", required=True)
	ap.add_argument("--ground", required=True, help="ground-surface hint from build_navgrid.py --ground")
	ap.add_argument("--addon-dir", required=True)
	ap.add_argument("--min-ground", type=int, default=30, help="keep regions with at least this many polygons on the ground")
	ap.add_argument("--min-region", type=int, default=60, help="and at least this many polygons in all")
	ap.add_argument("--interface", default="16001")
	ap.add_argument("--version", default=None, help="defaults to the main addon's ## Version")
	ap.add_argument("--stats-only", action="store_true", help="print polygon counts and stop before writing")
	a = ap.parse_args()
	a.title = a.title or a.name
	if not a.version:
		# One version for the whole release: the data addons follow the main addon.
		main_toc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "StarfallTrail", "StarfallTrail.toc")
		m = re.search(r"^## Version:\s*(\S+)", open(main_toc, encoding="utf-8").read(), re.M)
		a.version = m.group(1) if m else "0.0.0"
	build(a)
