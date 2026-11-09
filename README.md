# Starfall Trail

A World of Warcraft: Forever addon that walks you to your next quest objective: a glowing trail of
sparkles on the ground along a real walkable route, and a smooth 3D arrow that turns with your camera.
It reads the quest you focus in [Questie](https://www.curseforge.com/wow/addons/questie).

![logo](branding/logo.png)

## What it does

- Routes follow the walkable ground of Kalimdor and the Eastern Kingdoms: roads and paths first,
  around cliffs and water, over bridges.
- The trail is projected onto the terrain every frame, so it stays on the ground while you walk and
  turn the camera.
- The text under the arrow says what to do ("Kill 7 Thistle Boar", "Turn in to ...").
- In a quest area the arrow and the trail fade out until you leave.

See [branding/curseforge-description.md](branding/curseforge-description.md) for the full feature
list and commands (`/starfall`, `/sft`).

## Repository layout

| Path | What it is |
|---|---|
| `StarfallTrail/` | The addon: arrow (`StarfallTrail.lua`), route search (`Nav.lua`), trail (`Trail.lua`), minimap menu (`Menu.lua`), arrow sprite metadata (`Frames.lua`), diagnostics (`Probe.lua`). |
| `StarfallTrail_Kalimdor/`, `StarfallTrail_EasternKingdoms/` | Load-on-demand data addons with each continent's walkable-area map. `Mesh.lua` is generated (see below) and not in git. |
| `tools/` | Map building (`build_world.sh`, `build_navgrid.py`, `build_navmesh.py`), art (`render_arrow.py`, `render_logo.py`), camera fitting, packaging. |
| `tools/trinitycore/` | The patch and build scripts for TrinityCore's map tools, which produce the walkable-area tiles. |
| `tools/sim/` | Offline tests that run the addon's real Lua in Lua 5.1 (`lupa`). |

## How the maps are made

1. TrinityCore's extractors read terrain, buildings and doodads from your own game install.
2. A patched `mmaps_generator` (Recast) builds walkable-area tiles, with road and path ground tagged
   from the terrain textures so routes prefer roads.
3. `build_navmesh.py` stitches the tiles into one mesh per continent, works out which pieces connect,
   adds a coarse 64-yard cost grid that guides long searches, and writes it as compact Lua strings
   (every format is described in comments at the top of the generated file).

No game files, textures or models are included in the addon or this repository. Full steps are in
[tools/trinitycore/README.md](tools/trinitycore/README.md).

## Building a release

```
LISTFILE=/path/to/listfile.csv tools/build_world.sh     # regenerate the map data (game patch changes)
tools/package.sh                                         # dist/StarfallTrail-<version>.zip
```

## License

MIT, see [LICENSE](LICENSE).
