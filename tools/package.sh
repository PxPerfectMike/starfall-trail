#!/usr/bin/env bash
# Packages a release: checks the three addons agree on the version, compiles every Lua file with
# real Lua 5.1, and zips StarfallTrail + both data addons into dist/StarfallTrail-<version>.zip.
#   tools/package.sh
# Needs Python with lupa (PYLIBS may point to a folder that has it).
set -euo pipefail

PY=${PY:-"/c/Program Files/Python313/python.exe"}
TOOLS=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$TOOLS")
ADDONS=(StarfallTrail StarfallTrail_Kalimdor StarfallTrail_EasternKingdoms)
cd "$REPO"

version=$(sed -n 's/^## Version: *\([^ \r]*\).*/\1/p' StarfallTrail/StarfallTrail.toc)
[ -n "$version" ] || { echo "no ## Version in StarfallTrail.toc"; exit 1; }
for a in "${ADDONS[@]}"; do
	v=$(sed -n 's/^## Version: *\([^ \r]*\).*/\1/p' "$a/$a.toc")
	[ "$v" = "$version" ] || { echo "$a.toc has version '$v', expected $version"; exit 1; }
done
for d in Kalimdor EasternKingdoms; do
	[ -s "StarfallTrail_$d/Mesh.lua" ] || { echo "StarfallTrail_$d/Mesh.lua is missing: run tools/build_world.sh"; exit 1; }
done
grep -q "^## Version: $version\b" CHANGELOG.md 2>/dev/null || grep -q "^## $version\b" CHANGELOG.md \
	|| { echo "CHANGELOG.md has no entry for $version"; exit 1; }

"$PY" - "$REPO" "$version" "${PYLIBS:-}" "${ADDONS[@]}" <<'PYEOF'
import glob, os, sys, zipfile
repo, version, pylibs, addons = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
if pylibs:
	sys.path.insert(0, pylibs)
from lupa import lua51
check = lua51.LuaRuntime().eval("function(src, name) local f, err = loadstring(src, name) return err end")
bad = False
for a in addons:
	for path in glob.glob(os.path.join(repo, a, "*.lua")):
		err = check(open(path, encoding="utf-8").read(), "@" + os.path.relpath(path, repo))
		if err:
			print("FAIL", err)
			bad = True
if bad:
	sys.exit(1)
out = os.path.join(repo, "dist", f"StarfallTrail-{version}.zip")
os.makedirs(os.path.dirname(out), exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
	for a in addons:
		for root, _, files in os.walk(os.path.join(repo, a)):
			for f in sorted(files):
				full = os.path.join(root, f)
				# Folders at the top of the zip, forward slashes, as WoW addon managers expect.
				z.write(full, os.path.relpath(full, repo).replace(os.sep, "/"))
print(f"wrote {out}: {os.path.getsize(out) / 1e6:.1f} MB")
PYEOF
