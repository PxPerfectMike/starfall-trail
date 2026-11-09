# Starfall Trail

**A glowing trail of sparkles on the ground and a smooth 3D arrow that walk you to your next quest objective.**

Focus a quest in Questie and Starfall Trail lights the way: a soft cloud of drifting sparkles along the actual walkable route (around cliffs, over bridges, along roads), and a gold arrow above your character that turns with your camera.

## Features

- **A real path, not a straight line.** Routes follow the walkable ground of Kalimdor and the Eastern Kingdoms, prefer roads and paths, go around mountains and water, and cross bridges. Long cross-zone routes are computed in well under a second, spread over frames so the game never stutters.
- **A trail that sits on the ground.** Sparkles stay glued to the terrain while you walk, turn and move the camera, and each one floats and fades on its own.
- **A 3D arrow** that points along the route relative to your camera, glows green when you are facing the right way, and shows the distance.
- **Says what to do.** "Kill 7 Thistle Boar", "Collect 4 Chunk of Boar Meat from Thistle Boar", "Go to Darnassus Bank", "Turn in to Tenaron Stormgrip", with the count going down as you go.
- **Stays out of the way when you get there.** In a quest area the arrow and the trail fade out and the text glides up, then everything comes back when you leave.
- **Auto focus:** with nothing focused, it guides you to your closest quest.
- **Corpse runs:** when you die, it leads you back to your body.
- **Minimap button** with a small menu to turn the trail, the arrow and the text on or off.

## Requirements

- **Questie** (for quest locations).
- World of Warcraft: Forever.

The walkable-area maps for each continent are separate load-on-demand addons in the same download (**StarfallTrail_Kalimdor**, **StarfallTrail_EasternKingdoms**). Only the continent you are on is loaded, the moment you enter it (about 0.1 seconds, behind the loading screen).

## Commands

`/starfall` or `/sft`

- `/sft trail`: trail on or off
- `/sft arrow`, `/sft text`: arrow, or the text under it, on or off
- `/sft auto`: auto focus on the closest quest
- `/sft unlock`, `/sft lock`: move the arrow
- `/sft scale 0.4-2.5`: arrow size
- `/sft minimap`: show or hide the minimap button
- `/sft reset`: back to defaults

## How the maps are made

The walkable-area maps are computed from the game's own terrain and buildings with open-source navigation-mesh tools (Recast, via TrinityCore's map tools), then compressed into plain Lua data. No game files, textures or models are included. The full source, including the map-building tools, is on GitHub.

## Known limits

- Routes cover Kalimdor and the Eastern Kingdoms. In other places (dungeons, islands without map data) the arrow still points straight at the target and the trail is off.
- Boats, zeppelins and flight paths are not part of routes yet.
