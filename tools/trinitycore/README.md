# Walkable-area maps from TrinityCore's tools

Starfall Trail's navigation mesh comes from TrinityCore's map tools (mapextractor, vmap4extractor,
vmap4assembler, mmaps_generator), built from TrinityCore master with `wayfinder-forever.patch`.
Only the tools' output is used: nothing from TrinityCore ships in the addon.

What the patch changes:

- `src/tools/extractor_common/ExtractorDB2LoadInfo.h`: Forever 1.60.1's Map.db2 layout (0xD43AFAC3,
  the retail 12.1.7 layout: one extra `OceanLiquidTypeID` column). The other tables the tools read
  already match.
- `src/common/mmaps_common/Generator/TileBuilder.cpp`: tags road (area 7) and dirt-trail (area 6)
  ground from `roadmask_<map>.bin` in the working directory, so polygons follow road edges; and reads
  `WAYFINDER_*` environment settings (voxel size, outline simplification, region sizes, agent size).
- `TerrainBuilder.cpp`: `WAYFINDER_M2_MIN` leaves out small doodads (trees, rocks, fences).
- The generator takes `--input` and `--output` folders.

## Build the tools (Windows, Visual Studio 2022)

`tc-build.ps1` clones TrinityCore, fetches Boost 1.84 and OpenSSL into `$env:TC_ROOT` (default
`C:\tc`), applies the patch and builds the four tools. `tc-rebuild.ps1` rebuilds `mmaps_generator`
after a source change. Copy the four `.exe` files (with OpenSSL's libcrypto/libssl/legacy DLLs) to
`<work>\tools`.

## Extract the game data (once per game patch)

From the work folder (`D:\wayfinder-tc` by default), with the game installed at `D:\World of Warcraft`:

```
tools\mapextractor.exe -i "D:\World of Warcraft" -p wowf -e 3 -o .
tools\vmap4extractor.exe -d "D:\World of Warcraft" -p wowf
tools\vmap4assembler.exe Buildings vmaps
```

## Build the data addons

`tools/build_world.sh` does the rest for each continent: the road map from the terrain textures
(`build_navgrid.py --roadmask-only`, needs the community `listfile.csv`), cleanup
(`clean_roadmask.py`), the walkable-area tiles (`mmaps_generator` with the settings at the top of
the script), and the data addon (`build_navmesh.py`):

```
LISTFILE=/path/to/listfile.csv tools/build_world.sh        # both continents, about 20 minutes
LISTFILE=/path/to/listfile.csv tools/build_world.sh 1      # Kalimdor only
```

The result is `StarfallTrail_Kalimdor/Mesh.lua` and `StarfallTrail_EasternKingdoms/Mesh.lua`
(generated, not in git). Note that `mmaps_generator --tile` takes row first: the tile file
`0001_13_27.mmtile` is row 13, column 27.
