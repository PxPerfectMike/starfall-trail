"""Reads WMO (building) geometry from CASC and places it in the world.

Placement space (ADT MODF/MDDF) is y-up; HereBeDragons world space is x = west, y = north:
	hbd_x = 17066.666 - placement[0], hbd_y = 17066.666 - placement[2], z = placement[1].
The local-to-placement rotation convention is chosen empirically per model by matching the
transformed bounding box against the extents stored in the MODF entry.
"""

import math
import struct

import numpy as np

from casc import CascError, iter_chunks

MAP_HALF = 17066.666666

_cache = {}


def load_wmo(store, fdid):
	"""Returns (vertices Nx3 float, triangles Mx3 int, group flags per triangle) in WMO local space."""
	if fdid in _cache:
		return _cache[fdid]
	root = dict(iter_chunks(store.read_fdid(fdid)))
	n_groups = struct.unpack("<I", root["MOHD"][4:8])[0]
	group_ids = []
	if "GFID" in root:
		gfid = root["GFID"]
		group_ids = list(struct.unpack(f"<{len(gfid) // 4}I", gfid))[:n_groups]
	verts, tris, flags = [], [], []
	base = 0
	for gid in group_ids:
		if not gid:
			continue
		try:
			data = store.read_fdid(gid)
		except CascError:
			continue
		mogp = next((p for m, p in iter_chunks(data) if m == "MOGP"), None)
		if mogp is None:
			continue
		gflags = struct.unpack("<I", mogp[8:12])[0]
		sub = {}
		for m, p in iter_chunks(mogp[68:]):
			sub.setdefault(m, p)
		if "MOVT" not in sub or "MOVI" not in sub:
			continue
		v = np.frombuffer(sub["MOVT"], dtype="<f4").reshape(-1, 3).astype(np.float64)
		idx = np.frombuffer(sub["MOVI"], dtype="<u2").reshape(-1, 3).astype(np.int64)
		verts.append(v)
		tris.append(idx + base)
		flags.append(np.full(len(idx), gflags, dtype=np.int64))
		base += len(v)
	if not verts:
		result = (np.zeros((0, 3)), np.zeros((0, 3), dtype=np.int64), np.zeros(0, dtype=np.int64))
	else:
		result = (np.vstack(verts), np.vstack(tris), np.concatenate(flags))
	_cache[fdid] = result
	return result


def _rot_y(deg):
	a = math.radians(deg)
	c, s = math.cos(a), math.sin(a)
	return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def _rot_x(deg):
	a = math.radians(deg)
	c, s = math.cos(a), math.sin(a)
	return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def _rot_z(deg):
	a = math.radians(deg)
	c, s = math.cos(a), math.sin(a)
	return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


# Candidate axis swaps from WMO local (z up) into placement space (y up).
SWAPS = {
	"x,z,-y": np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]]),
	"x,z,y": np.array([[1, 0, 0], [0, 0, 1], [0, 1, 0]]),
	"-x,z,y": np.array([[-1, 0, 0], [0, 0, 1], [0, 1, 0]]),
	"y,z,x": np.array([[0, 1, 0], [0, 0, 1], [1, 0, 0]]),
	"-y,z,x": np.array([[0, -1, 0], [0, 0, 1], [1, 0, 0]]),
	"y,z,-x": np.array([[0, 1, 0], [0, 0, 1], [-1, 0, 0]]),
}


def candidate_matrices(rot):
	rx, ry, rz = rot
	for name, swap in SWAPS.items():
		for sign in (1, -1):
			for offset in (0, 90, 180, 270):
				r = _rot_y(sign * ry + offset) @ _rot_z(rz) @ _rot_x(rx)
				yield f"{name} sign{sign:+d} off{offset}", r @ swap


def fit_transform(verts, pos, rot, scale, extents):
	"""Picks the candidate whose transformed bounding box best matches the MODF extents."""
	if len(verts) == 0:
		return None, None, math.inf
	# The box corners are enough to compare bounding boxes, and much cheaper than every vertex.
	lo, hi = verts.min(axis=0), verts.max(axis=0)
	corners = np.array([[x, y, z] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
	want = np.array(extents)
	best = (None, None, math.inf)
	for name, m in candidate_matrices(rot):
		placed = corners @ m.T * scale + pos
		got = np.concatenate([placed.min(axis=0), placed.max(axis=0)])
		err = float(np.abs(got - want).sum())
		if err < best[2]:
			best = (name, m, err)
	return best


def placed_triangles(store, fdid, pos, rot, scale, extents):
	"""World triangles (HBD x, y, z) for one MODF placement, plus the fit name and error."""
	verts, tris, flags = load_wmo(store, fdid)
	name, m, err = fit_transform(verts, np.array(pos), rot, scale, extents)
	if m is None:
		return None, None, name, err
	placed = verts @ m.T * scale + np.array(pos)
	world = np.empty_like(placed)
	world[:, 0] = MAP_HALF - placed[:, 0]
	world[:, 1] = MAP_HALF - placed[:, 2]
	world[:, 2] = placed[:, 1]
	return world[tris], flags, name, err


def parse_modf(payload):
	"""Yields dicts for MODF entries (positions and extents in placement space)."""
	for i in range(0, len(payload), 64):
		e = payload[i:i + 64]
		fid, uid = struct.unpack("<II", e[0:8])
		pos = struct.unpack("<3f", e[8:20])
		rot = struct.unpack("<3f", e[20:32])
		ext = struct.unpack("<6f", e[32:56])
		flags, doodad_set, name_set, scale = struct.unpack("<HHHH", e[56:64])
		yield {
			"fid": fid, "uid": uid, "pos": pos, "rot": rot, "extents": ext, "flags": flags,
			"scale": (scale / 1024.0) if (flags & 0x4 and scale) else 1.0,
		}
