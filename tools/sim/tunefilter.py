import numpy as np, math
d = np.load("solvelog.npy")
t, dt = d[:,0], d[:,1]
probe = d[:,2:4]; mark = d[:,4:6]; P = d[:,6:9]; zoom = d[:,9]
FOV, PIV, K, B = math.radians(52.98), 2.556, 0.8782, 1.889
F = 576 / math.tan(FOV / 2)
def project(x, y, z, h, p, px, py, pz, zm):
	dx, dy = math.sin(h), math.cos(h); cp, sp = math.cos(p), math.sin(p)
	dist = K * zm + B
	cx, cy, cz = px - dist*cp*dx, py - dist*cp*dy, pz + PIV + dist*sp
	vx, vy, vz = x-cx, y-cy, z-cz
	along = vx*dx + vy*dy; xc = -vx*dy + vy*dx
	yc = sp*along + cp*vz; zc = cp*along - sp*vz
	return 1024 + F*xc/zc, 576 + F*yc/zc
def solve(i, px, py, h, p):
	for _ in range(8):
		ex, ey = project(probe[i,0], probe[i,1], P[i,2], h, p, px, py, P[i,2], zoom[i])
		rx, ry = ex - mark[i,0], ey - mark[i,1]
		a1, b1 = project(probe[i,0], probe[i,1], P[i,2], h+1e-4, p, px, py, P[i,2], zoom[i])
		a2, b2 = project(probe[i,0], probe[i,1], P[i,2], h, p+1e-4, px, py, P[i,2], zoom[i])
		J = np.array([[(a1-ex)/1e-4, (a2-ex)/1e-4], [(b1-ey)/1e-4, (b2-ey)/1e-4]])
		dd = np.linalg.solve(J, [rx, ry]); h -= dd[0]; p -= dd[1]
		if abs(dd[0]) < 1e-9 and abs(dd[1]) < 1e-9: break
	return h, p
def ab_filter(alpha, beta):
	out = np.zeros((len(t), 2)); x = P[0,:2].copy(); v = np.zeros(2)
	for i in range(len(t)):
		x = x + v * dt[i]
		r = P[i,:2] - x
		if np.hypot(*r) > 1.0:  # teleport or big jump: snap
			x = P[i,:2].copy(); v[:] = 0
		else:
			x = x + alpha * r; v = v + (beta / max(dt[i], 1e-3)) * r
		out[i] = x
	return out
def evaluate(pos, lag):
	hs, ps = [], []
	h, p = d[0,11], d[0,12]
	for i in range(lag, len(t)):
		h, p = solve(i, pos[i-lag,0], pos[i-lag,1], h, p)
		hs.append(h); ps.append(p)
	hs, ps = np.array(hs), np.array(ps)
	# frame-to-frame jitter: second difference (rad)
	jh = np.abs(np.diff(hs, 2)); jp = np.abs(np.diff(ps, 2))
	return np.median(jh)*1e4, np.mean(jh)*1e4, np.median(jp)*1e4, np.mean(jp)*1e4
print("raw position:", ["%.2f" % v for v in evaluate(P[:,:2], 0)], "lag1", ["%.2f" % v for v in evaluate(P[:,:2], 1)])
for a, b in [(0.3, 0.05), (0.2, 0.02), (0.15, 0.01), (0.1, 0.005), (0.08, 0.004), (0.05, 0.0015)]:
	pos = ab_filter(a, b)
	print(f"alpha {a} beta {b}: lag0", ["%.2f" % v for v in evaluate(pos, 0)], "lag1", ["%.2f" % v for v in evaluate(pos, 1)])
pos = ab_filter(0.1, 0.005)
for lag in (0, 1, 2):
	print("lag", lag, ["%.2f" % v for v in evaluate(pos, lag)])
# Smoothness of the filtered position itself vs raw: per-frame jerk (yd)
for name, q in (("raw", P[:,:2]), ("filtered", pos)):
	j = np.hypot(*np.diff(q, 2, axis=0).T)
	print(name, "position jerk yd: mean %.4f p99 %.4f" % (j.mean(), np.percentile(j, 99)))
# lag of the filter vs raw while moving at constant speed: mean distance between filtered and raw
print("mean |filtered-raw| yd %.3f, p99 %.3f" % (np.hypot(*(pos-P[:,:2]).T).mean(), np.percentile(np.hypot(*(pos-P[:,:2]).T), 99)))
