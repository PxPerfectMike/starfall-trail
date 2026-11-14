"""Smoke test: loads the whole addon in Lua 5.1 (lupa) with stubbed WoW APIs and follows a party member.

Usage: python friendsmoke.py <pylibs dir>

Catches runtime errors in the arrow, the minimap menu and the slash commands when a group member is
the target. The ground trail is not exercised (C_Navigation is absent, so it stays off).
"""

import os
import sys

sys.path.insert(0, sys.argv[1])
from lupa import lua51  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "..", "StarfallTrail")
FILES = ["Frames.lua", "Nav.lua", "Trail.lua", "Probe.lua", "Friend.lua", "Menu.lua", "StarfallTrail.lua"]

L = lua51.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
PRINTED = {}
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	PRINTED[#PRINTED + 1] = table.concat(parts, " ")
end

-- Widgets: unknown methods do nothing; the few whose results are used return sensible values.
FRAMES = {}
local MT = {}
MT.__index = function(_, key)
	if key:match("^Get.*Width$") or key:match("^Get.*Height$") then
		return function() return 100 end
	end
	if key:match("^Create") then
		return function() return NewObject() end
	end
	return function() return nil end
end
function NewObject(name)
	local o = setmetatable({ scripts = {}, events = {}, shown = true, name = name }, MT)
	o.CreateTexture = function() return NewObject() end
	o.CreateFontString = function() return NewObject() end
	o.SetScript = function(self, what, fn) self.scripts[what] = fn end
	o.RegisterEvent = function(self, event) self.events[event] = true end
	o.UnregisterAllEvents = function(self) self.events = {} end
	o.Show = function(self) self.shown = true end
	o.Hide = function(self) self.shown = false end
	o.SetShown = function(self, on) self.shown = on and true or false end
	o.IsShown = function(self) return self.shown end
	o.SetText = function(self, text) self.text = text end
	o.GetText = function(self) return self.text end
	o.SetSize = function(self, w, h) self.w, self.h = w, h end
	o.SetChecked = function(self, on) self.checked = on end
	o.GetChecked = function(self) return self.checked end
	o.GetCenter = function() return 500, 400 end
	o.GetEffectiveScale = function() return 1 end
	o.GetPoint = function() return "TOP", nil, "TOP", 0, -36 end
	o.IsMouseOver = function() return false end
	FRAMES[#FRAMES + 1] = o
	if name then _G[name] = o end
	return o
end
function CreateFrame(_, name) return NewObject(name) end
UIParent = NewObject()
Minimap = NewObject()
GameTooltip = NewObject()
UISpecialFrames = {}
SlashCmdList = {}
STANDARD_TEXT_FONT = "font"
RAID_CLASS_COLORS = { DRUID = { colorStr = "ffff7d0a" } }

function strsplit(sep, text, limit)
	local a, b = text:match("^([^" .. sep .. "]*)" .. sep .. "(.*)$")
	if a then return a, b end
	return text
end
function strtrim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
format = string.format

NOW = 100
function GetTime() return NOW end
TIMERS = {}
C_Timer = { After = function(delay, fn) TIMERS[#TIMERS + 1] = fn end }
function GetPlayerFacing() return 0 end
function UnitIsGhost() return false end

-- The fake group. UNITS[token] = { guid, name, class, x, y, instance }.
UNITS = { player = { guid = "G-Me", name = "Me", class = "MAGE", x = 0, y = 0, instance = 1 } }
RAID = false
function UnitExists(unit) return UNITS[unit] ~= nil end
function UnitGUID(unit) return UNITS[unit] and UNITS[unit].guid end
function UnitName(unit) return UNITS[unit] and UNITS[unit].name end
function UnitClass(unit) return "Class", UNITS[unit] and UNITS[unit].class end
function UnitIsUnit(a, b) return UNITS[a] ~= nil and UNITS[a] == UNITS[b] end
function IsInRaid() return RAID end
function GetNumGroupMembers() return 0 end

-- HereBeDragons, flat world.
local HBD = {}
function HBD:GetUnitWorldPosition(unit)
	local u = UNITS[unit]
	if not (u and u.x) then return nil, nil, u and u.instance end
	return u.x, u.y, u.instance
end
function HBD:GetPlayerWorldPosition() return self:GetUnitWorldPosition("player") end
function HBD:GetWorldVector(_, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	return math.atan2(-dx, dy), math.sqrt(dx * dx + dy * dy)
end
function HBD:GetWorldDistance(_, ax, ay, bx, by)
	return math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
end
function LibStub(name) return name == "HereBeDragons-2.0" and HBD or nil end

-- The game's right-click menu API (this global is shadowed inside Menu.lua).
MENU_HOOKS = {}
Menu = { ModifyMenu = function(tag, fn) MENU_HOOKS[tag] = fn end }

function Fire(event, ...)
	for _, f in ipairs(FRAMES) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end
function Frames(seconds)
	local frame = StarfallTrailFrame
	for _ = 1, math.floor(seconds * 60) do
		NOW = NOW + 1 / 60
		frame.scripts.OnUpdate(frame, 1 / 60)
	end
end
function TextShown(pattern)
	for _, f in ipairs(FRAMES) do
		if type(f.text) == "string" and f.text:find(pattern, 1, true) then return true end
	end
	return false
end
''')

ns = L.eval("{}")
load = L.eval("function(code, name, ns) local fn = assert(loadstring(code, '@' .. name)); fn('StarfallTrail', ns) end")
for name in FILES:
	load(open(os.path.join(ADDON, name), encoding="utf-8").read(), name, ns)

lua = L.globals()
step = L.eval("Frames")
shown = L.eval("TextShown")
slash = lua.SlashCmdList["STARFALLTRAIL"]


def printed():
	return "\n".join(lua.PRINTED.values())


def check(condition, message):
	if not condition:
		print("FAIL", message)
		print(printed())
		sys.exit(1)


lua.Fire("ADDON_LOADED", "StarfallTrail")
lua.Fire("PLAYER_LOGIN")
lua.Fire("PLAYER_ENTERING_WORLD")
db = lua.StarfallTrailDB
check(db["minimapAngle"] == 270, "the minimap button should default to the bottom")
step(0.5)
check("error" not in printed(), "idle frames should not error")
print("ok loads and idles with no group")

# A party member 100 yards north.
L.execute('UNITS.party1 = { guid = "G-Anna", name = "Anna", class = "DRUID", x = 0, y = 100, instance = 1 }')
lua.Fire("GROUP_ROSTER_UPDATE")
slash("friend ann")
check(db["friendGUID"] == "G-Anna", "/sft friend ann should pick Anna: " + printed())
step(2)
check("error" not in printed(), "following should not error")
check(shown("Anna"), "the label should show the name")
check(shown("100 yd"), "the distance should read 100 yd")
print("ok /sft friend <prefix> follows a party member")

# They move: the arrow keeps up.
L.execute("UNITS.party1.x, UNITS.party1.y = 300, 400")
step(3)
check(shown("500 yd"), "the distance should follow them to 500 yd")
print("ok distance follows a moving friend")

# Arrival.
L.execute("UNITS.party1.x, UNITS.party1.y = 3, 4")
step(3)
check(shown("Anna is here"), "arrival text should name the friend")
print("ok arrival text")

# Position hidden (dungeon).
L.execute("UNITS.party1.x = nil")
step(2)
check(shown("location not available"), "a hidden position should say so")
check("error" not in printed(), "a hidden position should not error")
print("ok hidden position")

# Another continent.
L.execute("UNITS.party1.x, UNITS.party1.instance = 3, 0")
step(2)
check(shown("Not on this continent"), "another continent should say so")
print("ok other continent")
L.execute("UNITS.party1.instance = 1")

# Minimap menu: open it, the row is highlighted, clicking it clears.
lua.StarfallTrailMinimapButton.scripts["OnClick"](lua.StarfallTrailMinimapButton)
check(lua.StarfallTrailSettingsMenu.shown, "the menu should open")
rows = list(L.eval("""function()
	local out = {}
	for _, f in ipairs(FRAMES) do
		if rawget(f, "entry") and f.shown then out[#out + 1] = f end
	end
	return out
end""")().values())
check(len(rows) == 1 and rows[0]["entry"]["name"] == "Anna", "the menu should list Anna once")
rows[0].scripts["OnClick"](rows[0])
check(db["friendGUID"] is None, "clicking the followed name should clear it")
rows[0].scripts["OnClick"](rows[0])
check(db["friendGUID"] == "G-Anna", "clicking a name should follow them")
print("ok minimap menu list")

# Right-click menu entry.
hook = lua.MENU_HOOKS["MENU_UNIT_PARTY"]
check(hook is not None, "the party right-click menu should be hooked")
captured = L.eval("{}")
root = L.eval("""function(out) return {
	CreateDivider = function() end,
	CreateButton = function(self, text, fn) out.text, out.fn = text, fn end,
} end""")(captured)
hook(None, root, L.table_from({"unit": "party1"}))
check(captured["text"] == "Starfall Trail: stop following", "entry text while following: " + str(captured["text"]))
captured["fn"]()
check(db["friendGUID"] is None, "the right-click entry should stop following")
hook(None, root, L.table_from({"name": "Anna-SomeRealm"}))
check(captured["text"] == "Starfall Trail: follow", "entry text when not following")
captured["fn"]()
check(db["friendGUID"] == "G-Anna", "the right-click entry should follow by name")
hook(None, root, L.table_from({"unit": "player"}))
print("ok right-click menu entry")

# Target, off, probe.
L.execute('UNITS.target = UNITS.party1')
slash("friend off")
slash("friend")
check(db["friendGUID"] == "G-Anna", "/sft friend with a group member targeted should follow them")
slash("probe party")
check("arrow can use it: yes" in printed(), "probe should report a usable position: " + printed())
print("ok target, off and probe")

# They leave the group.
L.execute("UNITS.party1 = nil; UNITS.target = nil; NOW = NOW + 60")
lua.Fire("GROUP_ROSTER_UPDATE")
check(db["friendGUID"] is None, "leaving the group should clear the choice")
check("no longer in your group" in printed(), "leaving should be announced")
step(1)
check("error" not in printed(), "frames after they leave should not error")
print("ok friend leaves the group")

slash("reset")
slash("")
check("error" not in printed(), "reset and help should not error")
print("all smoke checks passed")
