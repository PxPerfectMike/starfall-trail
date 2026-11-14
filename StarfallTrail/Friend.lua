-- Starfall Trail: the group member the arrow follows instead of a quest.

local _, ns = ...

local Friend = {}
ns.Friend = Friend

local GRACE = 8 -- seconds after login before a missing friend is dropped
local VALIDATE_DELAY = 8.5 -- seconds after login for the scheduled check
local GOAL_SLACK = 15 -- yards they may move from the end of the trail before it is planned again

local saved -- the settings table from Friend.Init
local frame
local graceUntil = 0 -- set in Init: roster events can arrive before the group is known at login

local function Print(msg)
	print("|cffffd24dStarfall Trail|r " .. msg)
end

-- Secret values must be checked before anything else touches them.
local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local function Notify()
	if Friend.onChange then
		Friend.onChange()
	end
end

---------------------------------------------------------------------------
-- Saved choice
---------------------------------------------------------------------------

function Friend.Init(db)
	saved = db
	graceUntil = GetTime() + GRACE
	if frame or not CreateFrame then
		return
	end
	frame = CreateFrame("Frame")
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_ENTERING_WORLD" then
			graceUntil = GetTime() + GRACE
			if C_Timer and C_Timer.After then
				C_Timer.After(VALIDATE_DELAY, Friend.Validate)
			end
		elseif event == "GROUP_ROSTER_UPDATE" then
			Friend.Validate()
			Notify()
		end
	end)
end

function Friend.Get()
	if not saved or not saved.friendGUID then
		return nil
	end
	return saved.friendGUID, saved.friendName, saved.friendClass
end

function Friend.Set(guid, name, class)
	if not saved then
		return
	end
	saved.friendGUID = guid
	saved.friendName = name
	saved.friendClass = class
	Notify()
end

function Friend.Clear()
	if not saved then
		return
	end
	saved.friendGUID = nil
	saved.friendName = nil
	saved.friendClass = nil
	Notify()
end

---------------------------------------------------------------------------
-- Group roster
---------------------------------------------------------------------------

-- Returns the group unit tokens to scan for the given scope.
local function Tokens(scope)
	local tokens = {}
	if scope == "party" or not IsInRaid() then
		for i = 1, 4 do
			tokens[#tokens + 1] = "party" .. i
		end
	else
		for i = 1, GetNumGroupMembers() do
			tokens[#tokens + 1] = "raid" .. i
		end
	end
	return tokens
end

-- Other players in the group: { unit, guid, name, class } for each.
function Friend.Roster(scope)
	local roster = {}
	for _, unit in ipairs(Tokens(scope)) do
		if UnitExists(unit) and not UnitIsUnit(unit, "player") then
			local guid = UnitGUID(unit)
			local name = UnitName(unit)
			if not IsSecret(guid) and not IsSecret(name) and guid ~= nil and name ~= nil then
				local _, class = UnitClass(unit)
				if IsSecret(class) then
					class = nil
				end
				roster[#roster + 1] = { unit = unit, guid = guid, name = name, class = class }
			end
		end
	end
	return roster
end

-- The unit token currently holding the saved friend, or nil.
function Friend.Unit()
	local guid = Friend.Get()
	if guid == nil then
		return nil
	end
	for _, entry in ipairs(Friend.Roster("group")) do
		if entry.guid == guid then
			return entry.unit
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Choosing a friend
---------------------------------------------------------------------------

-- Trims spaces and drops any realm suffix, lowercased for comparison.
local function NormalName(text)
	local trimmed = string.match(text, "^%s*(.-)%s*$")
	local base = string.match(trimmed, "^[^-]*")
	return string.lower(string.match(base, "^%s*(.-)%s*$"))
end

-- Finds one roster entry by name. Returns entry, or nil and "none" / "ambiguous".
function Friend.MatchName(roster, text)
	text = NormalName(text or "")
	if text == "" then
		return nil, "none"
	end

	local exact, exactCount = nil, 0
	local prefix, prefixCount = nil, 0
	for _, entry in ipairs(roster) do
		local name = NormalName(entry.name)
		if name == text then
			exact = exact or entry
			exactCount = exactCount + 1
		elseif string.sub(name, 1, #text) == text then
			prefix = prefix or entry
			prefixCount = prefixCount + 1
		end
	end

	if exactCount > 1 then
		return nil, "ambiguous"
	elseif exactCount == 1 then
		return exact
	elseif prefixCount > 1 then
		return nil, "ambiguous"
	elseif prefixCount == 1 then
		return prefix
	end
	return nil, "none"
end

function Friend.SetByUnit(unit)
	local guid = UnitGUID(unit)
	if IsSecret(guid) or guid == nil then
		return false, "That is not someone in your group."
	end
	for _, entry in ipairs(Friend.Roster("group")) do
		if entry.guid == guid then
			Friend.Set(entry.guid, entry.name, entry.class)
			return true, entry.name
		end
	end
	return false, "That is not someone in your group."
end

function Friend.SetByName(text)
	local entry, why = Friend.MatchName(Friend.Roster("group"), text)
	if entry == nil then
		if why == "ambiguous" then
			return false, 'More than one group member matches "' .. (text or "") .. '".'
		end
		return false, 'No one in your group is named "' .. (text or "") .. '".'
	end
	Friend.Set(entry.guid, entry.name, entry.class)
	return true, entry.name
end

---------------------------------------------------------------------------
-- Where they are
---------------------------------------------------------------------------

-- World x, y and instance for a unit, or nil when unknown or secret.
function Friend.Position(unit)
	if ns.HBD == nil then
		return nil
	end
	local ok, x, y, instance = pcall(function()
		return ns.HBD:GetUnitWorldPosition(unit)
	end)
	if not ok then
		return nil
	end
	if IsSecret(x) or IsSecret(y) or IsSecret(instance) then
		return nil
	end
	if type(x) ~= "number" or type(y) ~= "number" or type(instance) ~= "number" then
		return nil
	end
	return x, y, instance
end

-- A fresh target table for the arrow, or nil when nothing is chosen.
function Friend.Target()
	local guid, name, class = Friend.Get()
	if guid == nil then
		return nil
	end
	local target = {
		key = "friend:" .. guid,
		friend = true,
		name = name,
		class = class,
		goalSlack = GOAL_SLACK,
	}
	local unit = Friend.Unit()
	if unit == nil then
		target.unavailable = true
		return target
	end
	local x, y, instance = Friend.Position(unit)
	if x == nil then
		target.unavailable = true
	else
		target.x, target.y, target.instance = x, y, instance
	end
	return target
end

---------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------

-- Drops the friend when they have left the group, once the login grace is over.
function Friend.Validate()
	local guid, name = Friend.Get()
	if guid == nil then
		return
	end
	if GetTime() < graceUntil then
		return
	end
	if Friend.Unit() ~= nil then
		return
	end
	Print((name or "Your friend") .. " is no longer in your group. Back to quests.")
	Friend.Clear()
end

function Friend.ColoredName(name, class)
	if RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class] and RAID_CLASS_COLORS[class].colorStr then
		return "|c" .. RAID_CLASS_COLORS[class].colorStr .. name .. "|r"
	end
	return name
end
