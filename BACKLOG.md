# Starfall Trail backlog

## Sparkles hide behind pillars, trees and walls (occlusion)

The addon API gives no depth information, so this is done ourselves:

- **Occluders:** from the extracted collision data (`D:\wayfinder-tc\vmaps` / WMO and M2 geometry),
  build a simplified obstacle set for the zone: each pillar, trunk, wall or building as a 2D
  footprint plus a top height. Ship it as a compact data file with a coarse spatial index, like the
  navigation mesh.
- **Per frame:** for each sparkle, cast a line from the camera (position from our solved camera model)
  to the sparkle and fade it when the line passes through an obstacle. Also test against terrain
  heights so sparkles hide behind hills.
- **Soft edges:** fade gradually as the line nears an obstacle edge; the camera model is a few pixels
  off at worst, and a hard cutoff would flicker along pillar edges.
- **Limits:** obstacle shapes are approximate (ornate objects and canopies hide by a rough outline);
  walk-through decoration is not in collision data; players and creatures never occlude.
- **Test** offline in the sparkle simulator before tuning in game.
- Do this after the navmesh routing is confirmed in game; it builds on the same data.

## Settings menu for players

Today every option is a slash command (`/sft trail`, `/sft auto`, `/sft scale`, `/sft lock`, ...).
Players need a simple way to change settings without typing:

- **Entry point:** a small Starfall Trail icon on the edge of the minimap. Clicking it opens a compact
  settings panel (or a dropdown menu); the icon itself can be dragged around the minimap edge and
  hidden. Optionally also register a page in the game's Interface/AddOns options.
- **Toggles:** sparkle path on/off, arrow on/off, the text under the arrow (distance and quest name)
  on/off, auto-focus the closest quest on/off, lock/unlock the arrow position.
- **Adjustments:** arrow size, maybe sparkle brightness/density, reset position.
- Keep the slash commands working; the panel just calls the same settings.
- Settings already live in `StarfallTrailDB` (saved variables); the panel edits those.

## Branding and CurseForge release

- **Name:** check that "Starfall Trail" is free on CurseForge/Wago (rename if taken); final title, short
  tagline and description.
- **Art:** addon icon (also used for the minimap button and the TOC `## IconTexture`), a logo/banner
  for the project page, and screenshots or a short clip of the arrow and sparkle trail.
- **TOC metadata:** version scheme, author, notes, category, `X-Curse-Project-ID`, `X-Wago-ID`,
  supported interface versions.
- **Packaging:** `.pkgmeta` (BigWigs packager or CurseForge packager) to build release zips without
  the `tools/` folder; changelog; tag-based releases.
- **Dependencies:** it currently borrows HereBeDragons from Questie (`HereBeDragonsQuestie-2.0`).
  Either declare Questie as required or embed LibStub + HereBeDragons in the addon.
- **Clean-up for release:** hide or remove debug-only commands (`/sft probe`, `/sft rec`, `/sft trail
  debug`, `/sft trail log`) and debug drawing; make sure nothing logs every frame.
- **License and credits:** pick a license for the addon; credit TrinityCore (the map tools) and
  HereBeDragons. Check the terms for shipping navigation data derived from the game's files.
- **Size and load time:** the Teldrassil navigation file is 3.5 MB; with more zones, consider loading
  zone data on demand.
- Write the project page (features, commands, known limits, supported zones).

## Known gaps

- Only Teldrassil has navigation data. Other zones: run the same pipeline on their tiles
  (`tools/trinitycore/README.md`).
- Rut'theran Village (sea level, below the tree) is not included.
- Raised areas not connected to the ground in the generated mesh (upper levels of Aldrassil in
  Shadowglen) are dropped; quest targets there get routed to the nearest ground below.
