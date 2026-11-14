# Follow a party member: design

Date: 11/13/2026. Target version: 1.1.0.

## Intent

Let the player pick one person in their group and have Starfall Trail's arrow (and sparkle trail)
lead to that person instead of to a quest. It is for finding a friend in the open world.

## Goals, non-goals, anti-goals

- **Goals:** one arrow and one trail that point at the chosen person; picking them takes one or two
  clicks; nothing changes for players who never use it.
- **Non-goals:** a second arrow; highlighting the person's character, nameplate or unit frame; raid
  target markers; following people outside your group; working inside dungeons and raids (the game
  hides positions there).
- **Anti-goals:** the quest arrow breaking or shutting off for existing users because the friend
  lookup failed. A failed lookup must fall back quietly.

## Constraints

- Addons cannot draw on the 3D world, so an arrow plus the existing ground trail is the feature.
- **Unverified:** nothing in the addon reads another player's position today, and it is not confirmed
  that the Forever client gives it to addons. `/sft probe party` ships in the same build to check
  this in game with a real group. This blocks the release, not the build.
- `GuardedUpdate` stops the whole addon after 5 errors, so the position read lives in one function,
  runs under `pcall`, and checks every returned value with `IsSecret` before doing math on it.

## Approaches

1. **Friend replaces the quest target (picked by the user).** One arrow, one trail; matches how the
   corpse already overrides quests. Simplest.
2. **Second, smaller arrow for the friend.** Both at once; more clutter and a second copy of the
   arrow state and art handling.
3. **Auto-switch by distance.** Friend when far, quest when near; surprising target changes.

## Behavior

- **Priority:** corpse, then friend, then quest. While a friend is set, the closest-quest auto focus
  scan does not run.
- **Label:** distance on top as today; under it the person's name (class colored).
- **Arrival:** within 10 yards the arrow fades as today and the text reads "<Name> is here".
- **Friend cannot be located** (in a dungeon, position hidden, offline): the arrow hides and the text
  reads "<Name>: location not available". Another continent uses the existing "Not on this
  continent" text. The arrow does not fall back to a quest while a friend is set. (My call.)
- **Friend leaves the group, or you do:** the choice is cleared, a chat line says so, and the quest
  arrow returns. (My call.)
- **Persistence:** the choice is saved (GUID and name), so it survives `/reload` and a relog while
  they are still in your group. It is checked against the roster a few seconds after login, since
  group data arrives late. `/sft reset` clears it. (My call.)
- **Raid groups:** supported. The minimap panel lists party members only; raid members are picked by
  right-click or slash command. (My call.)

## Picking the person

- **Minimap panel:** a "Follow" section under the three checkboxes listing current party members by
  name. Clicking one selects them (highlighted); clicking the selected one clears. Shows "Not in a
  party" when empty. The panel resizes each time it opens and when the roster changes.
- **Right-click menu** on a party or raid member: "Starfall Trail: follow" / "stop following".
  Skipped silently if the client has no menu hook.
- **Slash:** `/sft friend <name>` (case-insensitive, since the handler lowercases input),
  `/sft friend` with a target selected uses the target, `/sft friend off` clears.
- **Minimap button default** moves from 200 degrees to 270 (bottom). Existing users keep their saved
  position.

## Trail

The trail leads to the friend too. Today it re-plans whenever the goal moves 3 yards and replays its
sweep-out effect, which would flicker for a walking friend. For a friend target the route is kept
until they are 15 yards from where it ends, and re-plans to the same person do not replay the sweep.
Within 40 yards the arrow points straight at the person instead of along the route.

## Code shape

- **`Friend.lua` (new):** stores the choice, finds the current unit token for the saved GUID
  (`party1`-`party4` and `raid1`-`raid40` shift), matches names, reads the position, lists the
  roster, and owns its own event frame for roster changes. Name matching and unit resolution are
  plain functions so `tools/sim` can test them with stubbed unit APIs.
- **`StarfallTrail.lua`:** `FindTarget` asks `Friend` after the corpse check; label, arrival text,
  auto focus skip, slash command, defaults.
- **`Menu.lua`:** the "Follow" section, dynamic size. Blizzard's global menu API is reached as
  `_G.Menu` because the file's local `Menu` shadows it.
- **`Trail.lua`:** per-target re-plan distance and the no-sweep rule.
- **`Probe.lua`:** `/sft probe party` prints what the client returns for each group member's position.
- **Release files:** TOC (file list, notes, version on all three addons), CHANGELOG, README layout
  table, `branding/curseforge-description.md`.

## Left to the builder

- Which position call to use (HereBeDragons unit position, or map position converted to world
  coordinates), after checking what Questie's copy of the library provides.
- Exact panel layout and colors, matching the existing panel.
- Exact wording of chat lines.
