import sys, time, math
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, r"C:\repos\starfall-trail\tools")
from lupa import lua51
from PIL import Image, ImageDraw
import mmtile
L = lua51.LuaRuntime(unpack_returned_tuples=True)
ns = L.eval("{}")
L.execute("debugprofilestop = function() return os.clock() * 1000 end")
for f in (r"WayfinderMesh_Teldrassil.lua", r"C:\repos\starfall-trail\StarfallTrail\Nav.lua"):
	code = open(f, encoding="utf-8").read()
	t = time.time()
	L.execute("local code, ns = ...; local fn = assert(loadstring(code)); fn('StarfallTrail', ns)", code, ns)
	print("loaded", f.split("\\")[-1], "%.2fs" % (time.time() - t))
Nav = ns.Nav
def route(px, py, tx, ty, pz=None):
	t = time.time()
	ok = Nav.Request(px, py, tx, ty, 1, pz)
	frames = 0
	while Nav.Busy():
		Nav.Step(); frames += 1
	r = Nav.route
	if not ok or r is None:
		print("NO ROUTE", ok, Nav.lastError, Nav.lastExpansions); return None
	pts = [(r.points[k][1], r.points[k][2], r.heights[k]) for k in range(1, len(r.points) + 1)]
	length = sum(math.dist(pts[k-1][:2], pts[k][:2]) for k in range(1, len(pts)))
	print(f"route {len(pts)} points, {length:.0f} yd (straight {math.dist((px,py),(tx,ty)):.0f}), {r.expansions} polys expanded, corridor {r.polys}, {frames} frames, {time.time()-t:.2f}s")
	return pts
