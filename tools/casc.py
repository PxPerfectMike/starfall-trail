"""Minimal read-only reader for WoW's local CASC storage (TACT), enough to pull files by FileDataID.

Usage as a library:
	store = CascStore(r"D:\\World of Warcraft", product="wowf")
	data = store.read_fdid(782779)

Format notes follow the public wowdev.wiki documentation (CASC, BLTE, Encoding, Root).
"""

import glob
import hashlib
import os
import struct
import zlib


class CascError(Exception):
	pass


def _read_build_info(root, product):
	path = os.path.join(root, ".build.info")
	with open(path, encoding="utf-8") as fh:
		lines = [line.rstrip("\n") for line in fh if line.strip()]
	header = [col.split("!")[0] for col in lines[0].split("|")]
	for line in lines[1:]:
		row = dict(zip(header, line.split("|")))
		if row.get("Product") == product:
			return row
	raise CascError(f"product {product!r} not in .build.info")


def _read_config(root, key):
	path = os.path.join(root, "Data", "config", key[0:2], key[2:4], key)
	out = {}
	with open(path, encoding="utf-8") as fh:
		for line in fh:
			if " = " in line:
				k, v = line.strip().split(" = ", 1)
				out[k] = v.split()
	return out


def blte_decode(data, allow_encrypted=False):
	if data[:4] != b"BLTE":
		raise CascError("not BLTE")
	header_size = struct.unpack(">I", data[4:8])[0]
	chunks = []
	if header_size == 0:
		chunks.append((len(data) - 8, None))
		pos = 8
	else:
		flags = data[8]
		count = int.from_bytes(data[9:12], "big")
		pos = 12
		for _ in range(count):
			comp, decomp = struct.unpack(">II", data[pos:pos + 8])
			chunks.append((comp, decomp))
			pos += 24
		pos = header_size
	out = bytearray()
	for comp, _decomp in chunks:
		block = data[pos:pos + comp]
		pos += comp
		mode = block[:1]
		if mode == b"N":
			out += block[1:]
		elif mode == b"Z":
			out += zlib.decompress(block[1:])
		elif mode == b"E":
			if not allow_encrypted:
				raise CascError("encrypted BLTE chunk (needs a TACT key)")
		elif mode == b"F":
			out += blte_decode(block[1:], allow_encrypted)
		else:
			raise CascError(f"unknown BLTE mode {mode!r}")
	return bytes(out)


class CascStore:
	def __init__(self, root, product="wowf"):
		self.root = root
		self.data_dir = os.path.join(root, "Data", "data")
		info = _read_build_info(root, product)
		self.version = info.get("Version")
		self.build = _read_config(root, info["Build Key"])
		self.index = {}
		self._load_indices()
		self.ckey_to_ekey = {}
		self._load_encoding()
		self.fdid_to_ckey = {}
		self._load_root()

	# ---------------------------------------------------------------- indices
	def _load_indices(self):
		latest = {}
		for path in glob.glob(os.path.join(self.data_dir, "*.idx")):
			name = os.path.basename(path)
			bucket, version = int(name[0:2], 16), int(name[2:10], 16)
			if bucket not in latest or version > latest[bucket][0]:
				latest[bucket] = (version, path)
		for _, path in latest.values():
			with open(path, "rb") as fh:
				raw = fh.read()
			header_len = struct.unpack("<I", raw[0:4])[0]
			hdr = raw[8:8 + header_len]
			_version, _bucket, _extra, size_bytes, offset_bytes, key_bytes, _file_header = struct.unpack("<HBBBBBB", hdr[:8])
			pos = (8 + header_len + 0x0F) & ~0x0F
			entries_size = struct.unpack("<I", raw[pos:pos + 4])[0]
			pos += 8
			entry_len = key_bytes + offset_bytes + size_bytes
			end = pos + entries_size
			while pos + entry_len <= end:
				ekey = raw[pos:pos + key_bytes]
				off = int.from_bytes(raw[pos + key_bytes:pos + key_bytes + offset_bytes], "big")
				size = int.from_bytes(raw[pos + key_bytes + offset_bytes:pos + entry_len], "little")
				pos += entry_len
				archive = off >> 30
				offset = off & 0x3FFFFFFF
				if ekey not in self.index:
					self.index[ekey] = (archive, offset, size)

	def read_ekey(self, ekey, allow_encrypted=False):
		loc = self.index.get(ekey[:9])
		if not loc:
			raise CascError("ekey not in local storage: " + ekey.hex())
		archive, offset, size = loc
		with open(os.path.join(self.data_dir, f"data.{archive:03d}"), "rb") as fh:
			fh.seek(offset)
			blob = fh.read(size)
		return blte_decode(blob[30:], allow_encrypted)

	# --------------------------------------------------------------- encoding
	def _load_encoding(self):
		ekey = bytes.fromhex(self.build["encoding"][1])
		data = self.read_ekey(ekey)
		if data[:2] != b"EN":
			raise CascError("bad encoding magic")
		ckey_size, ekey_size = data[3], data[4]
		ce_page_kb = struct.unpack(">H", data[5:7])[0]
		ce_pages = struct.unpack(">I", data[9:13])[0]
		espec_size = struct.unpack(">I", data[18:22])[0]
		pos = 22 + espec_size + ce_pages * 32
		page_size = ce_page_kb * 1024
		for _ in range(ce_pages):
			page = data[pos:pos + page_size]
			p = 0
			while p + 6 + ckey_size <= len(page):
				count = page[p]
				if count == 0:
					break
				ckey = page[p + 6:p + 6 + ckey_size]
				first = page[p + 6 + ckey_size:p + 6 + ckey_size + ekey_size]
				self.ckey_to_ekey[ckey] = first
				p += 6 + ckey_size + ekey_size * count
			pos += page_size

	def read_ckey(self, ckey, allow_encrypted=False):
		ekey = self.ckey_to_ekey.get(ckey)
		if not ekey:
			raise CascError("ckey not in encoding: " + ckey.hex())
		return self.read_ekey(ekey, allow_encrypted)

	# ------------------------------------------------------------------- root
	def _load_root(self):
		data = self.read_ckey(bytes.fromhex(self.build["root"][0]))
		if data[:4] != b"TSFM":
			raise CascError("unsupported root format (no TSFM header)")
		header_size, version = struct.unpack("<II", data[4:12])
		if header_size > 1000:  # version-1 layout: totals directly after the magic
			version, pos = 1, 12
		else:
			pos = header_size
		self.root_version = version
		while pos < len(data):
			if version >= 2:
				count, locale, f1, f2, f3 = struct.unpack("<IIIIB", data[pos:pos + 17])
				content = f1 | f2 | (f3 << 17)
				pos += 17
			else:
				count, content, locale = struct.unpack("<III", data[pos:pos + 12])
				pos += 12
			deltas = struct.unpack(f"<{count}i", data[pos:pos + 4 * count])
			pos += 4 * count
			ckeys = data[pos:pos + 16 * count]
			pos += 16 * count
			if not content & 0x10000000:
				pos += 8 * count
			fdid = -1
			english = locale & 0x2 or locale == 0xFFFFFFFF
			for i, delta in enumerate(deltas):
				fdid += delta + 1
				if fdid not in self.fdid_to_ckey or english:
					self.fdid_to_ckey[fdid] = ckeys[16 * i:16 * i + 16]

	def read_fdid(self, fdid, allow_encrypted=False):
		ckey = self.fdid_to_ckey.get(fdid)
		if not ckey:
			raise CascError(f"FileDataID {fdid} not in root")
		data = self.read_ckey(ckey, allow_encrypted)
		if hashlib.md5(data).digest() != ckey:
			raise CascError(f"FileDataID {fdid}: checksum mismatch")
		return data


def iter_chunks(data):
	"""Yields (magic, payload) for WoW's chunked formats (WDT/ADT); magics are stored reversed."""
	pos = 0
	while pos + 8 <= len(data):
		magic = data[pos:pos + 4][::-1].decode("ascii", "replace")
		size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
		yield magic, data[pos + 8:pos + 8 + size]
		pos += 8 + size
