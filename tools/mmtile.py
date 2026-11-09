"""Reads TrinityCore movement-map tiles (.mmtile: a small TrinityCore header + a Detour tile).

Layout follows Detour's dtMeshHeader / dtPoly / dtPolyDetail / dtBVNode / dtOffMeshConnection,
with TrinityCore's DT_VERTS_PER_POLYGON = 6 and polygon references packed for 64-bit builds.
Coordinates are Recast's (y up). TrinityCore feeds Recast (wowY, wowZ, wowX), so a vertex
(rx, ry, rz) is world x = rz, y = rx, z = ry in WoW's own axes; HereBeDragons uses x = wowY,
y = wowX, which makes it HBD x = rx, HBD y = rz. `load` returns HBD coordinates.
"""

import struct

DT_VERTS_PER_POLYGON = 6
MMAP_MAGIC = 0x4D4D4150  # 'MMAP'
DT_NAVMESH_MAGIC = ord("D") << 24 | ord("N") << 16 | ord("A") << 8 | ord("V")


def _align4(n):
	return (n + 3) & ~3


def load(path):
	data = open(path, "rb").read()
	magic, dt_version, mmap_version, size, uses_liquids = struct.unpack_from("<IIIIB", data, 0)
	if magic != MMAP_MAGIC:
		raise ValueError(f"{path}: not an mmtile (magic {magic:#x})")
	off = 20  # TrinityCore header: 4 x uint32 + uint8 usesLiquids + 3 padding
	tile = data[off:off + size]
	fmt = "<iiiiiI" + "i" * 9 + "f" * 10   # dtMeshHeader: 15 ints, then walkable height/radius/climb, bmin, bmax, bvQuantFactor
	h = struct.unpack_from(fmt, tile, 0)
	(magic2, version, tx, ty, layer, user_id, poly_count, vert_count, max_links, detail_mesh_count,
		detail_vert_count, detail_tri_count, bv_count, offmesh_count, offmesh_base) = h[:15]
	if magic2 != DT_NAVMESH_MAGIC:
		raise ValueError(f"{path}: bad Detour magic {magic2:#x}")
	walk_height, walk_radius, walk_climb = h[15:18]
	header_size = _align4(struct.calcsize(fmt))
	p = header_size
	verts = list(struct.iter_unpack("<fff", tile[p:p + vert_count * 12]))
	p += _align4(vert_count * 12)
	poly_size = 4 + 2 * DT_VERTS_PER_POLYGON * 2 + 2 + 1 + 1
	polys = []
	for k in range(poly_count):
		q = p + k * poly_size
		first_link = struct.unpack_from("<I", tile, q)[0]
		pv = struct.unpack_from(f"<{DT_VERTS_PER_POLYGON}H", tile, q + 4)
		neis = struct.unpack_from(f"<{DT_VERTS_PER_POLYGON}H", tile, q + 4 + 2 * DT_VERTS_PER_POLYGON)
		flags, nv, area_type = struct.unpack_from("<HBB", tile, q + 4 + 4 * DT_VERTS_PER_POLYGON)
		polys.append({"verts": pv[:nv], "neis": neis[:nv], "flags": flags, "area": area_type & 0x3F, "type": area_type >> 6})
	p += _align4(poly_count * poly_size)
	link_size = 8 + 4 + 1 + 1 + 1 + 1  # dtPolyRef (64-bit) + next + edge + side + bmin + bmax
	p += _align4(max_links * _align4(link_size))
	details = list(struct.iter_unpack("<IIBB2x", tile[p:p + detail_mesh_count * 12]))
	p += _align4(detail_mesh_count * 12)
	dverts = list(struct.iter_unpack("<fff", tile[p:p + detail_vert_count * 12]))
	p += _align4(detail_vert_count * 12)
	dtris = list(struct.iter_unpack("<BBBB", tile[p:p + detail_tri_count * 4]))
	return {
		"tile": (tx, ty), "verts": verts, "polys": polys, "details": details, "dverts": dverts, "dtris": dtris,
		"walk": (walk_height, walk_radius, walk_climb), "liquids": uses_liquids,
	}


def triangles(t):
	"""Yields (area, flags, triangle) for every detail triangle, triangle = three (rx, ry, rz)."""
	verts, dverts = t["verts"], t["dverts"]
	for k, poly in enumerate(t["polys"]):
		if poly["type"] == 1:  # off-mesh connection, not a surface
			continue
		vert_base, tri_base, vert_count, tri_count = t["details"][k]
		pv = poly["verts"]
		def vertex(i):
			return verts[pv[i]] if i < len(pv) else dverts[vert_base + i - len(pv)]
		for a, b, c, _flags in t["dtris"][tri_base:tri_base + tri_count]:
			yield poly["area"], poly["flags"], (vertex(a), vertex(b), vertex(c))
