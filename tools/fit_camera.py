"""Fits WoW's third-person camera model to samples recorded by `/sft rec`.

Each sample: ground point (world x west, y north, z up), where it appeared on screen (UIParent
units, origin bottom-left), player position and ground height, facing, camera zoom.

Model: the camera orbits a pivot `h` yards above the player's feet at distance `k * zoom + b`,
looking along heading `a` (radians, 0 = north, counterclockwise toward west like GetPlayerFacing)
and pitched down by `p`. Screen = perspective projection with vertical field of view `fov`.
Global: fov, h, k, b. Per 50 ms window: heading offset from facing and pitch.
"""

import argparse
import math
import re

import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix

UI_W, UI_H = 2048.0, 1152.0


def load(path):
	rows = []
	with open(path, encoding="utf-8") as fh:
		for line in fh:
			m = re.match(r'\s*"([0-9.;\-]+)"', line)
			if m and m.group(1).count(";") == 13:
				rows.append([float(v) for v in m.group(1).split(";")])
	return np.array(rows)


def project(params_global, heading, pitch, data):
	fov, h, k, b, dz, ox, oy = params_global
	t, gx, gy, gz, sx, sy, px, py, pz, facing, zoom = (data[:, i] for i in range(11))
	dist = k * zoom + b
	dx, dy = np.sin(heading), np.cos(heading)
	cp, sp = np.cos(pitch), np.sin(pitch)
	# Pivot and camera position.
	tx, ty, tz = px, py, pz + h
	cx, cy, cz = tx - dist * cp * dx, ty - dist * cp * dy, tz + dist * sp
	# Camera basis: forward F, right R (east of the heading), up U.
	fx, fy, fz = cp * dx, cp * dy, -sp
	rx, ry, rz = -dy, dx, 0.0 * dx
	ux = ry * fz - rz * fy
	uy = rz * fx - rx * fz
	uz = rx * fy - ry * fx
	# Make U point upward.
	flip = np.where(uz < 0, -1.0, 1.0)
	ux, uy, uz = ux * flip, uy * flip, uz * flip
	vx, vy, vz = gx - cx, gy - cy, gz + dz - cz
	xc = vx * rx + vy * ry + vz * rz
	yc = vx * ux + vy * uy + vz * uz
	zc = vx * fx + vy * fy + vz * fz
	f = (UI_H / 2.0) / math.tan(fov / 2.0)
	return UI_W / 2.0 + f * xc / zc + ox, UI_H / 2.0 + f * yc / zc + oy, zc


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("savedvariables")
	ap.add_argument("--window", type=float, default=0.05)
	ap.add_argument("--mirror", action="store_true", help="flip the screen x axis")
	ap.add_argument("--dump", help="write per-sample residuals as CSV")
	ap.add_argument("--height-mode", default="grid", choices=["grid", "player"], help="where the marker height comes from")
	args = ap.parse_args()

	data = load(args.savedvariables)
	print(f"{len(data)} samples")
	if args.mirror:
		data[:, 4] = UI_W - data[:, 4]
	if args.height_mode == "player":
		data[:, 3] = data[:, 8]

	# Group into time windows where the camera is treated as fixed.
	t = data[:, 0]
	win = np.floor((t - t.min()) / args.window).astype(int)
	uniq, inverse, counts = np.unique(win, return_inverse=True, return_counts=True)
	keep = counts[inverse] >= 3
	data, inverse = data[keep], np.unique(inverse[keep], return_inverse=True)[1]
	nwin = inverse.max() + 1
	print(f"{len(data)} samples in {nwin} windows")

	facing = data[:, 9]
	n_global = 7

	def unpack(x):
		g = x[:n_global]
		yaw_off = x[n_global:n_global + nwin]
		pitch = x[n_global + nwin:]
		return g, facing + yaw_off[inverse], pitch[inverse]

	def residuals(x):
		g, heading, pitch = unpack(x)
		sx, sy, zc = project(g, heading, pitch, data)
		bad = zc <= 0.5
		rx = np.where(bad, 200.0, sx - data[:, 4])
		ry = np.where(bad, 200.0, sy - data[:, 5])
		return np.concatenate([rx, ry])

	n = len(data)
	sparsity = lil_matrix((2 * n, n_global + 2 * nwin), dtype=int)
	rows = np.arange(n)
	sparsity[:, :n_global] = 1
	for r, w in zip(rows, inverse):
		for base in (r, r + n):
			sparsity[base, n_global + w] = 1
			sparsity[base, n_global + nwin + w] = 1

	best = None
	for fov0 in (math.radians(50), math.radians(60), math.radians(75)):
		for pitch0 in (0.2, 0.5):
			x0 = np.concatenate([[fov0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0], np.zeros(nwin), np.full(nwin, pitch0)])
			lo = np.concatenate([[math.radians(20), -5, 0.3, -10, -10, -200, -200], np.full(nwin, -math.pi), np.full(nwin, -1.4)])
			hi = np.concatenate([[math.radians(120), 10, 3.0, 10, 10, 200, 200], np.full(nwin, math.pi), np.full(nwin, 1.5)])
			res = least_squares(residuals, x0, bounds=(lo, hi), jac_sparsity=sparsity, loss="soft_l1", f_scale=8.0, max_nfev=300)
			if best is None or res.cost < best.cost:
				best = res
	g, heading, pitch = unpack(best.x)
	r = residuals(best.x).reshape(2, -1)
	err = np.hypot(r[0], r[1])
	print(f"fov {math.degrees(g[0]):.2f} deg (vertical), pivot height {g[1]:.3f} yd, distance = {g[2]:.4f} * zoom + {g[3]:.3f}")
	print(f"marker height offset {g[4]:.3f} yd, screen offset {g[5]:.1f}, {g[6]:.1f}")
	print(f"pixel error (UIParent units): median {np.median(err):.2f}, 90% {np.percentile(err, 90):.2f}, 99% {np.percentile(err, 99):.2f}")
	yaw_off = best.x[n_global:n_global + nwin]
	print(f"heading offset from facing: median {math.degrees(np.median(yaw_off)):.2f} deg, range {math.degrees(yaw_off.min()):.1f}..{math.degrees(yaw_off.max()):.1f}")
	pw = best.x[n_global + nwin:]
	print(f"pitch range {math.degrees(pw.min()):.1f}..{math.degrees(pw.max()):.1f} deg")
	if args.dump:
		sx_, sy_, zc_ = project(g, heading, pitch, data)
		dist = np.hypot(data[:, 1] - data[:, 6], data[:, 2] - data[:, 7])
		np.savetxt(args.dump, np.column_stack([data[:, 0], inverse, dist, data[:, 3] - data[:, 8], data[:, 4], data[:, 5], sx_, sy_, err, np.degrees(pitch), zc_]),
			delimiter=",", header="t,win,dist,dz,sx,sy,px,py,err,pitch,zc", comments="")
	zoom = data[:, 10]
	for z in sorted(set(np.round(zoom, 1))):
		sel = np.round(zoom, 1) == z
		print(f"  zoom {z:5.1f}: {sel.sum():4d} samples, median err {np.median(err[sel]):.2f}")


if __name__ == "__main__":
	main()
