"""Loads a continent's data addon plus Nav.lua in Lua 5.1 (lupa) and times routes.

Usage: python meshlong.py <pylibs dir> <addon dir> <map id> x1 y1 x2 y2 [x1 y1 x2 y2 ...]
Coordinates are HereBeDragons world coordinates (/sft probe prints them in game).
"""

import math
import os
import sys
import time

sys.path.insert(0, sys.argv[1])
from lupa import lua51  # noqa: E402

addon_dir, map_id = sys.argv[2], int(sys.argv[3])
coords = [float(v) for v in sys.argv[4:]] if sys.argv[4] != "random" else None

L = lua51.LuaRuntime(unpack_returned_tuples=True)
L.execute("debugprofilestop = function() return os.clock() * 1000 end")
ns = L.eval("{}")
mesh_file = os.path.join(addon_dir, "Mesh.lua")
t = time.time()
L.execute(open(mesh_file, encoding="utf-8").read())
print(f"mesh loaded in {time.time() - t:.2f}s, Lua memory {L.eval('collectgarbage(\"count\")') / 1024:.0f} MB")
L.execute("C_AddOns = { LoadAddOn = function() return true end }")
code = open(r"C:\repos\starfall-trail\StarfallTrail\Nav.lua", encoding="utf-8").read()
L.execute("local code, ns = ...; local fn = assert(loadstring(code)); fn('StarfallTrail', ns)", code, ns)
Nav = ns.Nav

if coords is None:
	# Random pairs of mesh vertices at a few straight-line distances.
	import random
	random.seed(int(sys.argv[5]) if len(sys.argv) > 5 else 1)
	B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	m = L.eval(f"StarfallTrailMeshes[{map_id}]")
	chunk = int(m.chunk)
	def vert(k):
		s_ = m.verts[k // chunk + 1]
		p = (k % chunk) * 9
		d = [B64.index(c) for c in s_[p:p + 9]]
		x = (d[0] * 64 + d[1]) * 64 + d[2]
		y = (d[3] * 64 + d[4]) * 64 + d[5]
		return m.x0 + x / m.quant, m.y0 + y / m.quant
	coords = []
	for lo, hi in ((300, 600), (1000, 2000), (2500, 4000), (5000, 8000)):
		found = 0
		while found < 3:
			a = vert(random.randrange(int(m.vertCount)))
			b = vert(random.randrange(int(m.vertCount)))
			if lo <= math.dist(a, b) <= hi:
				coords += [a[0], a[1], b[0], b[1]]
				found += 1

for k in range(0, len(coords), 4):
	px, py, tx, ty = coords[k:k + 4]
	t = time.time()
	ok = Nav.Request(px, py, tx, ty, map_id, None)
	frames = 0
	while Nav.Busy():
		Nav.Step()
		frames += 1
	r = Nav.route
	straight = math.dist((px, py), (tx, ty))
	if not ok or r is None:
		print(f"{straight:6.0f} yd straight: NO ROUTE ({Nav.lastError}, {Nav.lastExpansions} expanded, {frames} frames)")
		continue
	pts = [(r.points[i][1], r.points[i][2]) for i in range(1, len(r.points) + 1)]
	length = sum(math.dist(pts[i - 1], pts[i]) for i in range(1, len(pts)))
	print(f"{straight:6.0f} yd straight: route {length:.0f} yd, {len(pts)} points, {r.expansions} polygons expanded, "
		f"{frames} frames, {time.time() - t:.2f}s")
L.execute("collectgarbage()")
print(f"Lua memory after routing {L.eval('collectgarbage("count")') / 1024:.0f} MB")
