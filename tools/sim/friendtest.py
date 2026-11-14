"""Offline tests for StarfallTrail/Friend.lua, run in Lua 5.1 through lupa.

Usage: python friendtest.py <pylibs dir>

The WoW globals are stubbed in Lua. The fake group, clock, HereBeDragons
object and print are all configurable from here between cases.
"""

import os
import sys

sys.path.insert(0, sys.argv[1])
from lupa import lua51  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FRIEND_LUA = os.path.join(HERE, "..", "..", "StarfallTrail", "Friend.lua")

HARNESS = r'''
SAVED = {}

-- Values the stubbed issecretvalue reports as secret. Any operation on them
-- except rawget and type errors, so code that touches a secret is caught.
SECRET_MT = {}
for _, key in ipairs({ "__index", "__concat", "__eq", "__lt", "__le", "__add", "__len", "__call" }) do
	SECRET_MT[key] = function() error("secret value used", 2) end
end

function Secret(value)
	return setmetatable({ isSecret = true, hidden = value }, SECRET_MT)
end

function issecretvalue(value)
	return type(value) == "table" and rawget(value, "isSecret") == true
end

function UnitExists(unit)
	return G_units[unit] ~= nil
end

function UnitGUID(unit)
	local u = G_units[unit]
	if u then return u.guid end
	return nil
end

function UnitName(unit)
	local u = G_units[unit]
	if u then return u.name end
	return nil
end

function UnitClass(unit)
	local u = G_units[unit]
	if u then return "Localized", u.class end
	return nil
end

function UnitIsUnit(a, b)
	local x, y = G_units[a], G_units[b]
	return x ~= nil and y ~= nil and x.guid == y.guid
end

function IsInRaid() return G_inRaid end
function GetNumGroupMembers() return G_numMembers end
function GetTime() return G_now end

C_Timer = {}
function C_Timer.After(seconds, fn)
	table.insert(G_timers, { seconds = seconds, at = G_now + seconds, fn = fn })
end

function CreateFrame(kind)
	local frame = { kind = kind, registered = {} }
	function frame:RegisterEvent(event) self.registered[event] = true end
	function frame:SetScript(name, fn)
		if name == "OnEvent" then self.onEvent = fn end
	end
	table.insert(G_frames, frame)
	return frame
end

function FireEvent(event)
	for _, frame in ipairs(G_frames) do
		if frame.onEvent then frame.onEvent(frame, event) end
	end
end

function RunTimers()
	local pending = G_timers
	G_timers = {}
	for _, timer in ipairs(pending) do timer.fn() end
end

FakeHBD = { mode = "numbers" }
function FakeHBD:GetUnitWorldPosition(unit)
	self.lastUnit = unit
	if self.mode == "numbers" then
		return 12.5, 34.25, 1400
	elseif self.mode == "nil" then
		return nil
	elseif self.mode == "error" then
		error("HBD failed")
	elseif self.mode == "secret" then
		return 12.5, Secret(34.25), 1400
	elseif self.mode == "string" then
		return "12.5", 34.25, 1400
	end
end

function print(msg)
	table.insert(G_printed, tostring(msg))
end

G_frames = {}
G_units = {}
G_inRaid = false
G_numMembers = 0
G_now = 0
G_timers = {}
G_printed = {}

function ResetAll()
	G_units = { player = { guid = "Player-1", name = "Me", class = "MAGE" } }
	G_inRaid = false
	G_numMembers = 0
	G_now = 0
	G_timers = {}
	G_printed = {}
	for k in pairs(SAVED) do SAVED[k] = nil end
	FakeHBD.mode = "numbers"
	RAID_CLASS_COLORS = nil
end

function AddUnit(unit, guid, name, class)
	G_units[unit] = { guid = guid, name = name, class = class }
end

function Entry(unit, guid, name, class)
	return { unit = unit, guid = guid, name = name, class = class }
end

function MakeRoster(...)
	return { ... }
end

function Dump(list)
	local out = {}
	for i, e in ipairs(list) do
		out[i] = e.unit .. "|" .. tostring(e.guid) .. "|" .. tostring(e.name) .. "|" .. tostring(e.class)
	end
	return table.concat(out, ";")
end

function Printed()
	return table.concat(G_printed, "\n")
end
'''

L = lua51.LuaRuntime(unpack_returned_tuples=True)
L.execute(HARNESS)
lua = L.globals()
ns = L.eval("{}")
with open(FRIEND_LUA, encoding="utf-8") as f:
	friend_code = f.read()
L.execute("local code, ns = ...; local fn = assert(loadstring(code, '@Friend.lua')); fn('StarfallTrail', ns)", friend_code, ns)
F = ns["Friend"]

PREFIX = "|cffffd24dStarfall Trail|r "
CASES = []


def case(name):
	def register(fn):
		CASES.append((name, fn))
		return fn
	return register


def reset():
	lua.ResetAll()
	ns["HBD"] = lua.FakeHBD
	F["onChange"] = None


def add(unit, guid, name, cls=None):
	lua.AddUnit(unit, guid, name, cls)


def remove(unit):
	lua["G_units"][unit] = None


def dump(entries):
	return lua.Dump(entries)


def entries(*rows):
	return lua.MakeRoster(*[lua.Entry(*row) for row in rows])


def match(roster, text):
	# MatchName returns a single entry on success, so normalize to (entry, reason).
	result = F.MatchName(roster, text)
	if isinstance(result, tuple):
		return result
	return result, None


def printed():
	text = lua.Printed()
	return text.split("\n") if text else []


@case("Get returns nothing before Init")
def _():
	assert F.Get() is None, "Get() should be nil before Init"


@case("Init creates one event frame that registers both events")
def _():
	F.Init(lua.SAVED)
	assert len(lua.G_frames) == 1, "Init should create exactly one frame"
	frame = lua.G_frames[1]
	assert frame["registered"]["GROUP_ROSTER_UPDATE"] is True, "GROUP_ROSTER_UPDATE not registered"
	assert frame["registered"]["PLAYER_ENTERING_WORLD"] is True, "PLAYER_ENTERING_WORLD not registered"
	assert frame["onEvent"] is not None, "OnEvent script not set"
	F.Init(lua.SAVED)
	assert len(lua.G_frames) == 1, "a second Init should not create another frame"


@case("Init starts the grace period, so an early roster event at login keeps the saved friend")
def _():
	lua.G_now = 50
	F.Init(lua.SAVED)
	F.Set("G-Gone", "Gone", "MAGE")
	lua.G_now = 57.9
	F.Validate()
	assert F.Get() == ("G-Gone", "Gone", "MAGE"), "inside the grace from Init the friend should be kept"
	assert printed() == [], printed()
	lua.G_now = 58
	F.Validate()
	assert F.Get() is None, "friend missing from group should be cleared once the grace is over"
	assert printed() == [PREFIX + "Gone is no longer in your group. Back to quests."], printed()


@case("Set, Get and Clear store the three fields and call onChange")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	F.Set("G-Anna", "Anna", "DRUID")
	assert F.Get() == ("G-Anna", "Anna", "DRUID"), "Get after Set"
	assert lua.SAVED["friendGUID"] == "G-Anna", "db.friendGUID not stored"
	assert lua.SAVED["friendName"] == "Anna", "db.friendName not stored"
	assert lua.SAVED["friendClass"] == "DRUID", "db.friendClass not stored"
	assert len(changes) == 1, "Set should call onChange once"
	F.Clear()
	assert F.Get() is None, "Get after Clear"
	assert lua.SAVED["friendGUID"] is None and lua.SAVED["friendName"] is None, "Clear should nil the db"
	assert lua.SAVED["friendClass"] is None, "Clear should nil friendClass"
	assert len(changes) == 2, "Clear should call onChange"
	F.Clear()
	assert F.Get() is None, "second Clear should be safe"
	assert len(changes) == 3, "every Clear should call onChange"


@case("Roster lists party tokens and skips missing, secret and player units")
def _():
	lua["G_numMembers"] = 4
	add("party1", "G-Anna", "Anna", "DRUID")
	add("party2", "G-Sec", lua.Secret("Hidden"), "MAGE")
	add("party3", "G-Bo", "Bo", "WARRIOR")
	add("party4", "Player-1", "Me", "MAGE")
	add("raid1", "G-Raid", "Raider", "ROGUE")
	expected = "party1|G-Anna|Anna|DRUID;party3|G-Bo|Bo|WARRIOR"
	assert dump(F.Roster("party")) == expected, dump(F.Roster("party"))
	assert dump(F.Roster("group")) == expected, "group scope outside a raid should use party tokens"


@case("Roster skips a secret guid")
def _():
	add("party1", lua.Secret("G-Hidden"), "Hidden", "MAGE")
	add("party2", "G-Bo", "Bo", "WARRIOR")
	assert dump(F.Roster("group")) == "party2|G-Bo|Bo|WARRIOR", dump(F.Roster("group"))


@case("Roster uses raid tokens in a raid and skips the player")
def _():
	lua["G_inRaid"] = True
	lua["G_numMembers"] = 3
	add("party1", "G-Party", "Party", "PRIEST")
	add("raid1", "Player-1", "Me", "MAGE")
	add("raid2", "G-Anna", "Anna", "DRUID")
	add("raid3", "G-Bo", "Bo", "WARRIOR")
	add("raid4", "G-Ext", "Extra", "ROGUE")
	assert dump(F.Roster("group")) == "raid2|G-Anna|Anna|DRUID;raid3|G-Bo|Bo|WARRIOR", dump(F.Roster("group"))
	assert dump(F.Roster("party")) == "party1|G-Party|Party|PRIEST", dump(F.Roster("party"))


@case("Unit follows the saved GUID when the token changes")
def _():
	assert F.Unit() is None, "Unit() should be nil with nothing chosen"
	add("party1", "G-Anna", "Anna", "DRUID")
	F.Set("G-Anna", "Anna", "DRUID")
	assert F.Unit() == "party1", "Unit() should find party1"
	remove("party1")
	add("party2", "G-Anna", "Anna", "DRUID")
	assert F.Unit() == "party2", "Unit() should follow the GUID to party2"
	remove("party2")
	assert F.Unit() is None, "Unit() should be nil when the friend leaves"


@case("MatchName prefers an exact match over prefix matches")
def _():
	roster = entries(("party1", "G1", "Annabel", "MAGE"), ("party2", "G2", "Anna-Hill", "DRUID"))
	entry, why = match(roster, "anna")
	assert why is None and entry["unit"] == "party2", "exact match should win over Annabel"


@case("MatchName returns a unique prefix match, ignoring case and spaces")
def _():
	roster = entries(("party1", "G1", "Annabel", "MAGE"), ("party2", "G2", "Bo", "WARRIOR"))
	entry, why = match(roster, "  ANN ")
	assert why is None and entry["unit"] == "party1", "unique prefix should match"


@case("MatchName reports ambiguous prefix matches")
def _():
	roster = entries(("party1", "G1", "Annabel", "MAGE"), ("party2", "G2", "Andrea", "MAGE"))
	entry, why = match(roster, "an")
	assert entry is None and why == "ambiguous", "two prefix matches should be ambiguous"


@case("MatchName reports none for no match and for empty text")
def _():
	roster = entries(("party1", "G1", "Anna", "DRUID"))
	assert match(roster, "zed") == (None, "none"), "no match should be none"
	assert match(roster, "") == (None, "none"), "empty text should be none"
	assert match(roster, "   ") == (None, "none"), "blank text should be none"


@case("MatchName drops the realm from text and from roster names")
def _():
	roster = entries(("party1", "G1", "Anna-Hill", "DRUID"), ("party2", "G2", "Bo-Ridge", "WARRIOR"))
	assert match(roster, "Anna-Hill")[0]["unit"] == "party1", "realm in text should be dropped"
	assert match(roster, "anna-other")[0]["unit"] == "party1", "any realm in text should be dropped"
	assert match(roster, "bo")[0]["unit"] == "party2", "realm in roster name should be dropped"
	assert match(roster, "ann")[0]["unit"] == "party1", "prefix should match after dropping realm"


@case("MatchName reports two exact matches on different realms as ambiguous")
def _():
	roster = entries(("party1", "G1", "Anna-Hill", "DRUID"), ("party2", "G2", "Anna-Other", "MAGE"))
	assert match(roster, "Anna") == (None, "ambiguous"), "same name, two realms should be ambiguous"
	assert match(roster, "Anna-Hill") == (None, "ambiguous"), "realm in text does not separate them"


@case("SetByUnit stores a group member and rejects anyone else")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	add("party1", "G-Anna", "Anna", "DRUID")
	ok, name = F.SetByUnit("party1")
	assert ok is True and name == "Anna", "SetByUnit should succeed for a group member"
	assert F.Get() == ("G-Anna", "Anna", "DRUID"), "SetByUnit should store the member"
	assert len(changes) == 1, "SetByUnit should call onChange"
	message = "That is not someone in your group."
	assert F.SetByUnit("party2") == (False, message), "missing unit should fail"
	assert F.SetByUnit("player") == (False, message), "the player is not in the roster"
	assert F.Get() == ("G-Anna", "Anna", "DRUID"), "a failed SetByUnit should change nothing"


@case("SetByName stores a match and reports both failure messages")
def _():
	add("party1", "G-Anna", "Anna-Hill", "DRUID")
	add("party2", "G-Andrea", "Andrea", "MAGE")
	add("party3", "G-Bo", "Bo", "WARRIOR")
	assert F.SetByName("bo") == (True, "Bo"), "unique name should succeed"
	assert F.Get() == ("G-Bo", "Bo", "WARRIOR"), "SetByName should store the member"
	assert F.SetByName("zed") == (False, 'No one in your group is named "zed".'), "no match message"
	assert F.SetByName("an") == (False, 'More than one group member matches "an".'), "ambiguous message"
	assert F.SetByName("ann") == (True, "Anna-Hill"), "prefix should succeed with the roster name"


@case("Position converts HBD numbers to x, y, instance")
def _():
	add("party1", "G-Anna", "Anna", "DRUID")
	pos = F.Position("party1")
	assert pos is not None and tuple(pos) == (12.5, 34.25, 1400), "numbers should pass through"
	assert lua.FakeHBD["lastUnit"] == "party1", "GetUnitWorldPosition should get the unit"


@case("Position returns nil when HBD returns nothing")
def _():
	lua.FakeHBD["mode"] = "nil"
	assert F.Position("party1") is None, "nil return should give nil"


@case("Position returns nil when HBD raises an error")
def _():
	lua.FakeHBD["mode"] = "error"
	assert F.Position("party1") is None, "an error inside pcall should give nil"


@case("Position returns nil when a value is secret")
def _():
	lua.FakeHBD["mode"] = "secret"
	assert F.Position("party1") is None, "a secret value should give nil"


@case("Position returns nil when a value is not a number")
def _():
	lua.FakeHBD["mode"] = "string"
	assert F.Position("party1") is None, "a string x should give nil"


@case("Position returns nil when ns.HBD is missing")
def _():
	ns["HBD"] = None
	assert F.Position("party1") is None, "no HBD should give nil"


@case("Target with a position carries the friend and coordinates")
def _():
	add("party1", "G-Anna", "Anna", "DRUID")
	F.Set("G-Anna", "Anna", "DRUID")
	t = F.Target()
	assert t["key"] == "friend:G-Anna", "key should be friend:<guid>"
	assert t["friend"] is True, "friend flag should be set"
	assert t["name"] == "Anna" and t["class"] == "DRUID", "name and class should be copied"
	assert t["goalSlack"] == 15, "goalSlack should be 15"
	assert t["x"] == 12.5 and t["y"] == 34.25 and t["instance"] == 1400, "coordinates should be copied"
	assert t["unavailable"] is None, "a located friend should not be unavailable"


@case("Target without the unit is unavailable")
def _():
	F.Set("G-Gone", "Gone", "MAGE")
	t = F.Target()
	assert t["unavailable"] is True, "missing unit should be unavailable"
	assert t["x"] is None and t["y"] is None and t["instance"] is None, "no coordinates when unavailable"


@case("Target without a position is unavailable")
def _():
	add("party1", "G-Anna", "Anna", "DRUID")
	F.Set("G-Anna", "Anna", "DRUID")
	lua.FakeHBD["mode"] = "nil"
	t = F.Target()
	assert t["unavailable"] is True, "no position should be unavailable"
	assert t["x"] is None, "no coordinates without a position"


@case("Target is nil with nothing chosen and is a new table each call")
def _():
	assert F.Target() is None, "Target() should be nil with nothing chosen"
	F.Set("G-Anna", "Anna", "DRUID")
	add("party1", "G-Anna", "Anna", "DRUID")
	first, second = F.Target(), F.Target()
	assert lua.rawequal(first, second) is False, "Target should return a new table each call"


@case("Validate inside the grace period does nothing")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	lua.G_now = 100
	lua.FireEvent("PLAYER_ENTERING_WORLD")
	F.Set("G-Gone", "Gone", "MAGE")
	changes.clear()
	lua.G_now = 105
	F.Validate()
	assert F.Get() == ("G-Gone", "Gone", "MAGE"), "friend should be kept inside the grace period"
	assert printed() == [], "nothing should print inside the grace period"
	assert changes == [], "onChange should not fire inside the grace period"


@case("Validate after the grace period clears, prints and calls onChange")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	lua.G_now = 100
	lua.FireEvent("PLAYER_ENTERING_WORLD")
	F.Set("G-Gone", "Gone", "MAGE")
	changes.clear()
	lua.G_now = 108
	F.Validate()
	assert F.Get() is None, "friend should be cleared after the grace period"
	assert printed() == [PREFIX + "Gone is no longer in your group. Back to quests."], printed()
	assert len(changes) == 1, "Validate should call onChange through Clear"


@case("Scheduled Validate runs 8.5 seconds after login")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	lua.FireEvent("PLAYER_ENTERING_WORLD")
	assert len(lua.G_timers) == 1, "PLAYER_ENTERING_WORLD should schedule one timer"
	assert lua.G_timers[1]["seconds"] == 8.5, "Validate should be scheduled 8.5 seconds out"
	F.Set("G-Gone", "Gone", "MAGE")
	lua.G_now = 8.5
	lua.RunTimers()
	assert F.Get() is None, "the scheduled Validate should clear a missing friend"
	assert printed() == [PREFIX + "Gone is no longer in your group. Back to quests."], printed()


@case("GROUP_ROSTER_UPDATE validates and then calls onChange")
def _():
	changes = []
	F["onChange"] = lambda: changes.append(1)
	lua.FireEvent("PLAYER_ENTERING_WORLD")
	lua.G_now = 10
	F.Set("G-Gone", "Gone", "MAGE")
	changes.clear()
	lua.FireEvent("GROUP_ROSTER_UPDATE")
	assert F.Get() is None, "roster update should clear a missing friend"
	assert len(changes) == 2, "one onChange from Clear and one from the roster event"

	add("party1", "G-Anna", "Anna", "DRUID")
	F.Set("G-Anna", "Anna", "DRUID")
	changes.clear()
	lua.FireEvent("GROUP_ROSTER_UPDATE")
	assert F.Get() == ("G-Anna", "Anna", "DRUID"), "roster update should keep a present friend"
	assert len(changes) == 1, "a present friend should give one onChange"


@case("ColoredName wraps the name in the class color when one exists")
def _():
	lua["RAID_CLASS_COLORS"] = L.eval('{ DRUID = { colorStr = "ffff7d0a" } }')
	assert F.ColoredName("Anna", "DRUID") == "|cffff7d0aAnna|r", "class color should wrap the name"
	assert F.ColoredName("Anna", "MAGE") == "Anna", "a class missing from the table should stay plain"
	assert F.ColoredName("Anna", None) == "Anna", "a nil class should stay plain"


@case("ColoredName returns the plain name without a color table")
def _():
	lua["RAID_CLASS_COLORS"] = None
	assert F.ColoredName("Anna", "DRUID") == "Anna", "no color table should give the plain name"


def main():
	for name, fn in CASES:
		reset()
		try:
			fn()
		except AssertionError as err:
			print(f"FAIL {name}: {err}")
			sys.exit(1)
		print(f"ok {name}")
	print("all friend tests passed")


if __name__ == "__main__":
	main()
