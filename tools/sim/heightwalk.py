import math, numpy as np
exec(open("sparksim.py").read().split("status = lambda")[0])
L.execute("QUANT = true")
Nav = ns.Nav
OldNav = L.eval("{}")
# v1.0 height: plain bilinear (old nav file)
oldns = L.eval("{}")
for f in ("WayfinderData_Teldrassil.lua",):
	pass
code = open(r"oldtrail\Nav.lua", encoding="utf-8").read()
L.execute("local code, ns = ...; local fn = assert(loadstring(code)); fn('StarfallTrail', ns)", code, oldns)
oldns.Grids = ns.Grids
# Route to walk: bridge east of Darnassus.
px, py, tx, ty = 1700, 10130, 1420, 10100
Nav.Request(px, py, tx, ty, 1)
while Nav.Busy(): Nav.Step()
pts = [(Nav.route.points[k][1], Nav.route.points[k][2]) for k in range(1, len(Nav.route.points) + 1)]
target = L.eval("{ x = %f, y = %f, instance = 1 }" % (tx, ty))
L.execute("TRUE.px, TRUE.py = %f, %f" % pts[0])
dt = 1 / 100
speed = 7
pos = 0.0
seg = 0
gridH, trailH, oldH = [], [], []
def at(d):
	acc = 0
	for k in range(1, len(pts)):
		l = math.dist(pts[k-1], pts[k])
		if acc + l >= d:
			t = (d - acc) / l
			x = pts[k-1][0] + (pts[k][0]-pts[k-1][0]) * t
			y = pts[k-1][1] + (pts[k][1]-pts[k-1][1]) * t
			# one yard to the right of the route
			nx_, ny_ = -(pts[k][1]-pts[k-1][1]) / l, (pts[k][0]-pts[k-1][0]) / l
			return x + nx_ * 1.0, y + ny_ * 1.0, math.atan2(-(pts[k][0]-pts[k-1][0]), pts[k][1]-pts[k-1][1])
		acc += l
	return None
total = sum(math.dist(pts[k-1], pts[k]) for k in range(1, len(pts)))
d = 0
while d < total - 50:
	x, y, h = at(d)
	L.execute("PREV = { TRUE.px, TRUE.py }; TRUE.px, TRUE.py, TRUE.heading = %f, %f, %f" % (x, y, h))
	L.execute("local cx, cy = TRUE.px, TRUE.py; TRUE.px, TRUE.py = PREV[1], PREV[2]; RenderFrame(); TRUE.px, TRUE.py = cx, cy")
	ns.Trail.Update(dt, target, True)
	g, tp = ns.Trail.Heights()
	if tp is not None:
		gridH.append(g); trailH.append(tp); oldH.append(oldns.Nav.HeightAtWorld(x, y, 1))
	d += speed * dt
for name, arr in (("v1.0 grid height", oldH), ("surface-following grid height", gridH), ("trail-anchored height (new)", trailH)):
	a = np.array(arr)
	v = np.diff(a) / dt
	jump = np.abs(np.diff(a))
	print(f"{name:32s}: biggest single-frame jump {jump.max():.3f} yd, frames jumping > 0.1 yd: {(jump > 0.1).sum()}, vertical speed p99 {np.percentile(np.abs(v), 99):.1f} yd/s")
hs = np.array([Nav.route.heights[k] for k in range(1, len(Nav.route.points) + 1)])
dh = np.diff(hs)
print("route height steps per 2.5 yd: p50 %.2f p95 %.2f max %.2f" % (np.median(abs(dh)), np.percentile(abs(dh), 95), abs(dh).max()))
