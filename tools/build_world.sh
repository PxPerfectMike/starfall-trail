#!/usr/bin/env bash
# Builds Starfall Trail's walkable-area data for every continent, start to finish (see trinitycore/README.md).
# Run from Git Bash on the PC with the game installed. Steps per map: road map from the terrain
# textures, cleaned; walkable-area tiles from the patched TrinityCore generator; the data addon.
#   tools/build_world.sh [map ...]     (default: 1 0)
set -euo pipefail

WORK=${WORK:-D:/wayfinder-tc}
LISTFILE=${LISTFILE:?set LISTFILE to the community listfile.csv}
PY=${PY:-"/c/Program Files/Python313/python.exe"}
TOOLS=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$TOOLS")

# Generator settings: 0.67-yard voxels (coarser ones close narrow ramps and split whole zones off,
# like Azshara), whole-tile Recast tiles, coarse outlines, small doodads (trees, rocks, fences) left
# out. See trinitycore/wayfinder-forever.patch.
export WAYFINDER_VOXELS_PER_TILE=800 WAYFINDER_SUBTILE=800 WAYFINDER_RADIUS=1 WAYFINDER_HEIGHT=3 \
	WAYFINDER_CLIMB=3 WAYFINDER_MAXERR=3 WAYFINDER_MINREGION=20 WAYFINDER_MERGEREGION=40 WAYFINDER_M2_MIN=12

declare -A ZONE=([0]=EasternKingdoms [1]=Kalimdor)
declare -A TITLE=([0]="Eastern Kingdoms" [1]=Kalimdor)

maps=("$@")
[ ${#maps[@]} -gt 0 ] || maps=(1 0)
for map in "${maps[@]}"; do
	id=$(printf "%04d" "$map")
	name=${ZONE[$map]}
	echo "== map $map ($name)"
	"$PY" -u "$TOOLS/build_navgrid.py" --zone "$name" --listfile "$LISTFILE" --roadmask-only \
		--roadmask "$WORK/roadmask_$id.raw.bin" --ground "$WORK/ground_$id.npz" > "$WORK/roadmask_$id.log"
	"$PY" -u "$TOOLS/clean_roadmask.py" "$WORK/roadmask_$id.raw.bin" "$WORK/roadmask_$id.bin"
	rm -f "$WORK"/mmaps_wf/mmaps/"${id}"_*.mmtile "$WORK/mmaps_wf/mmaps/$id.mmap"
	mkdir -p "$WORK/mmaps_wf"
	(cd "$WORK" && ./tools/mmaps_generator.exe "$map" --threads 10 --silent --input "$WORK" --output "$WORK/mmaps_wf" > "$WORK/mmapgen_$id.log" 2>&1)
	echo "$(ls "$WORK/mmaps_wf/mmaps" | grep -c "^${id}_") tiles"
	(cd "$TOOLS" && "$PY" -u build_navmesh.py --map "$map" --name "$name" --title "${TITLE[$map]}" \
		--mmaps "$WORK/mmaps_wf/mmaps" --ground "$WORK/ground_$id.npz" --addon-dir "$REPO/StarfallTrail_$name")
done
