# Offline simulators

Run the addon's real Lua (Lua 5.1 via `lupa`) against stubbed WoW APIs and a known "true" camera.
Usage: `python <script>.py <folder with lupa/luaparser>` from this folder.

- `sparksim.py`: base harness (stubs, fake client that draws the waypoint marker, standing/turning/
  camera-jump/walking checks). Other scripts `exec` its setup.
- `walkjitter.py`: sparkle smoothness while walking with 0.1-yard rounded positions and a one-frame
  marker delay (as the real client does).
- `pitchsweep.py`: looking steeply down and up; which probe distance is used, recovery.
- `minimapsim.py`: probe hidden beyond the minimap's reach vs. estimate mode, drags, turns.
- `meshtest.py` / `meshroutes.py`: navigation-mesh routes between known Teldrassil spots.
- `heightwalk.py`: how smoothly the trail's reference height changes along a route.
- `meshlong.py`: loads a continent's data addon and times random long routes (the current data).
- `friendtest.py`: the followed party member (`Friend.lua`): roster, name matching, position guards,
  leaving the group. Needs no map data.
- `friendsmoke.py`: loads the whole addon with stubbed APIs and follows a party member through the
  arrow, the minimap menu, the right-click entry and the slash commands. Needs no map data.
- `tunefilter.py`: tunes the position filter on a recorded walk (`/sft trail log`).

The scripts other than `meshlong.py`, `friendtest.py` and `friendsmoke.py` were written against the earlier Teldrassil-only data
(`WayfinderMesh_Teldrassil.lua`, `tools/data/WayfinderData_Teldrassil.lua`) and need that data to run.
