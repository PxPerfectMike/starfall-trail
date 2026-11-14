-- Starfall Trail: a smooth 3D arrow that points at the quest focused in Questie.
-- Frame art is pre-rendered by tools/render_arrow.py; Frames.lua holds the sheet layout.

local ADDON_NAME, ns = ...

local MEDIA = "Interface\\AddOns\\StarfallTrail\\Media\\"
local TWO_PI = math.pi * 2
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local ARROW_SIZE = 200          -- on-screen size of one sprite cell at scale 1
local TARGET_INTERVAL = 0.5     -- seconds between target lookups
local ARRIVE_YARDS = 10         -- distance that counts as "you're here"
local LEAVE_MARGIN = 6          -- yards past ARRIVE_YARDS before you count as gone again
-- Kill and collect objectives are areas (a camp of boars), not one spot: the target is always the
-- nearest spawn, so being within AREA_ARRIVE_YARDS of it means being anywhere in the camp.
local AREA_ARRIVE_YARDS = 35
local AREA_LEAVE_MARGIN = 15
local LIFT_SECONDS = 0.9        -- how long the text takes to glide up on arrival (and back down)
local LIFT_HEIGHT = 0.85        -- how far it glides, in arrow sizes (into where the arrow was)
local SPRING = 11               -- arrow turn responsiveness (critically damped)
local AUTO_INTERVAL = 2         -- seconds between closest-quest scans
local AUTO_SWITCH_YARDS = 30    -- a new closest quest must be this much nearer...
local AUTO_SWITCH_RATIO = 0.75  -- ...and at most this fraction of the current distance
local FRIEND_INTERVAL = 0.2     -- seconds between position lookups while following a group member
local FRIEND_DIRECT_YARDS = 40  -- this close to them, point straight at them, not along the route

local DEFAULTS = {
	point = "TOP",
	x = 0,
	y = -36,
	scale = 1,
	locked = true,
	autoFocus = true,
	trail = true,
	arrow = true,       -- the 3D arrow itself
	text = true,        -- distance and quest name under the arrow
	minimapAngle = 270, -- position of the minimap button around the rim, in degrees
	minimapHidden = false,
}

local GOLD = { 1.00, 0.80, 0.32 }
local GREEN = { 0.45, 1.00, 0.55 }

local HBD
local db

---------------------------------------------------------------------------
-- Math helpers
---------------------------------------------------------------------------

local function WrapPi(a)
	a = math.fmod(a + math.pi, TWO_PI)
	if a < 0 then
		a = a + TWO_PI
	end
	return a - math.pi
end

local function Clamp(v, lo, hi)
	if v < lo then
		return lo
	end
	if v > hi then
		return hi
	end
	return v
end

local function SmoothStep(e0, e1, x)
	local t = Clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function Lerp(a, b, t)
	return a + (b - a) * t
end

-- Exponential approach that behaves the same at any frame rate.
local function Approach(current, target, rate, dt)
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

---------------------------------------------------------------------------
-- Target lookup
---------------------------------------------------------------------------

local questieModules

local function GetQuestieModules()
	if questieModules then
		return questieModules
	end
	-- Questie builds its database for a few seconds after login; asking earlier errors inside Questie.
	if not (QuestieLoader and Questie and Questie.started and Questie.db and Questie.db.char) then
		return nil
	end
	local ok, distanceUtils, eligibility, zoneDB = pcall(function()
		return QuestieLoader:ImportModule("DistanceUtils"),
			QuestieLoader:ImportModule("TrackerMapEligibility"),
			QuestieLoader:ImportModule("ZoneDB")
	end)
	if not ok or not (distanceUtils and distanceUtils.GetNearestSpawnForQuest
		and eligibility and eligibility.RefreshAndGetCapabilities
		and zoneDB and zoneDB.GetUiMapIdByAreaId) then
		return nil
	end
	questieModules = { distance = distanceUtils, eligibility = eligibility, zones = zoneDB }
	return questieModules
end

local function GetFocusedQuestId()
	local focus = Questie and Questie.db and Questie.db.char and Questie.db.char.TrackerFocus
	if type(focus) == "number" and focus > 0 then
		return focus
	end
	-- Blizzard super tracking counts only when Questie is set to follow it, the same rule Questie uses.
	-- Otherwise newly accepted quests and map clicks would steal the arrow.
	local followSuperTracking = Questie and Questie.db and Questie.db.profile
		and Questie.db.profile.trackerFollowSuperTracking
	if followSuperTracking and C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
		local id = C_SuperTrack.GetSuperTrackedQuestID()
		if id and id > 0 then
			return id
		end
	end
	return nil
end

local function WorldFromMap(uiMapId, x, y)
	if not (HBD and uiMapId and x and y) then
		return nil
	end
	return HBD:GetWorldCoordinatesFromZone(x, y, uiMapId)
end

-- The corpse wins while you are a ghost: that is the only place worth going.
local function CorpseTarget()
	if not (UnitIsGhost and UnitIsGhost("player")) then
		return nil
	end
	if not (C_DeathInfo and C_DeathInfo.GetCorpseMapPosition and C_Map and C_Map.GetBestMapForUnit) then
		return nil
	end
	local mapId = C_Map.GetBestMapForUnit("player")
	local pos = mapId and C_DeathInfo.GetCorpseMapPosition(mapId)
	if not pos then
		return nil
	end
	local x, y = pos:GetXY()
	local wx, wy, instance = WorldFromMap(mapId, x, y)
	if not wx then
		return nil
	end
	return { key = "corpse", x = wx, y = wy, instance = instance, name = "Your corpse", quest = nil }
end

-- The nearest spawn of any unfinished objective, like Questie's GetNearestSpawnForQuest, but also
-- returning which objective it belongs to so the label can say what to do there.
local function NearestObjective(distance, quest)
	local bestDist, bestSpawn, bestZone, bestName, bestObjective
	for _, list in ipairs({ quest.Objectives or {}, quest.SpecialObjectives or {} }) do
		for _, objective in pairs(list) do
			if objective.spawnList and ((not objective.Needed) or objective.Needed ~= objective.Collected) then
				local spawn, zone, name, dist = distance.GetNearestObjective(objective.spawnList)
				if spawn and dist and (not bestDist or dist < bestDist) then
					bestDist, bestSpawn, bestZone, bestName, bestObjective = dist, spawn, zone, name, objective
				end
			end
		end
	end
	return bestSpawn, bestZone, bestName, bestObjective
end

local EVENT_VERBS = {}
for verb in ("go explore find visit investigate scout locate reach enter search survey listen speak talk "
	.. "protect escort lead defend guard help free rescue kill slay destroy defeat use place plant light "
	.. "burn activate open place collect gather learn travel return bring take ride fly witness observe "
	.. "complete win survive cleanse purify discover follow"):gmatch("%a+") do
	EVENT_VERBS[verb] = true
end

-- What to do at the target, in plain words: "Kill 7 Thistle Boar", "Collect 4 Chunk of Boar Meat
-- from Thistle Boar", "Turn in to Tenaron Stormgrip".
local function Instruction(objective, sourceName)
	local text = objective.Description
	if type(text) ~= "string" or text == "" then
		return sourceName
	end
	local needed, collected = tonumber(objective.Needed), tonumber(objective.Collected) or 0
	local left = needed and needed - collected
	local count = ""
	if left and left > 1 then
		count = left .. (collected > 0 and " more " or " ")
	elseif left == 1 and needed > 1 then
		count = "1 more "
	end
	local kind = objective.Type
	if kind == "monster" or kind == "killcredit" then
		local name = text:gsub("%s+[Ss]lain$", ""):gsub("%s+[Kk]illed$", "")
		return "Kill " .. count .. name
	elseif kind == "item" then
		local from = sourceName and sourceName ~= text and (" from " .. sourceName) or ""
		return "Collect " .. count .. text .. from
	elseif kind == "object" then
		return "Use " .. text
	elseif kind == "event" then
		-- Exploration objectives are bare place names ("Darnassus Bank"); others already start with a verb.
		local first = (text:match("^(%a+)") or ""):lower()
		if not EVENT_VERBS[first] then
			return "Go to " .. text
		end
	end
	return text
end

local function QuestieTarget(questId)
	local modules = GetQuestieModules()
	if not modules then
		return nil
	end
	local quest, capabilities = modules.eligibility.RefreshAndGetCapabilities(questId)
	if not (quest and capabilities and capabilities.canNavigateQuest) then
		return nil, quest
	end
	local complete = quest.IsComplete and quest:IsComplete()
	local turnIn = complete == 1 or (complete ~= -1 and quest.isComplete)
	local spawn, zone, name, objective
	if not turnIn and modules.distance.GetNearestObjective then
		spawn, zone, name, objective = NearestObjective(modules.distance, quest)
	end
	if not spawn then
		spawn, zone, name = modules.distance.GetNearestSpawnForQuest(quest)
	end
	if not (spawn and zone) then
		return nil, quest
	end
	local todo
	if turnIn then
		todo = name and ("Turn in to " .. name) or "Turn in"
	elseif objective then
		todo = Instruction(objective, name)
	end
	local uiMapId = modules.zones:GetUiMapIdByAreaId(zone)
	local wx, wy, instance = WorldFromMap(uiMapId, spawn[1] / 100, spawn[2] / 100)
	if not wx then
		return nil, quest
	end
	return {
		key = questId,
		x = wx,
		y = wy,
		instance = instance,
		name = name,
		quest = quest.name,
		turnIn = turnIn,
		todo = todo,
		-- Monsters to kill and items they drop are spread over an area; everything else is one spot.
		area = not turnIn and objective ~= nil and (objective.Type == "monster" or objective.Type == "item"
			or objective.Type == "killcredit"),
	}, quest
end

-- Blizzard's own quest waypoint, for quests Questie cannot place.
local function NativeTarget(questId)
	if not (C_QuestLog and C_QuestLog.GetNextWaypoint) then
		return nil
	end
	local mapId, x, y = C_QuestLog.GetNextWaypoint(questId)
	local wx, wy, instance = WorldFromMap(mapId, x, y)
	if not wx then
		return nil
	end
	local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questId)
	return { key = questId, x = wx, y = wy, instance = instance, name = nil, quest = title }
end

-- Closest navigable quest in the log, for auto focus. Returns its id and distance, plus the
-- distance to `currentId` (nil if that quest can no longer be reached) so the caller can apply hysteresis.
local function FindClosestQuest(currentId)
	if not (HBD and GetQuestieModules()) then
		return nil
	end
	local px, py, instance = HBD:GetPlayerWorldPosition()
	if not px then
		return nil
	end
	local ok, activeQuests = pcall(QuestieLoader.ImportModule, QuestieLoader, "ActiveQuests")
	if not (ok and activeQuests and activeQuests.GetAll) then
		return nil
	end
	local hidden = Questie.db.char.TrackerHiddenQuests or {}
	local bestId, bestDistance, currentDistance
	for questId in pairs(activeQuests.GetAll()) do
		if not hidden[questId] then
			local okTarget, target = pcall(QuestieTarget, questId)
			if okTarget and target and target.instance == instance then
				local distance = HBD:GetWorldDistance(instance, px, py, target.x, target.y)
				if distance then
					if questId == currentId then
						currentDistance = distance
					end
					if not bestDistance or distance < bestDistance then
						bestId, bestDistance = questId, distance
					end
				end
			end
		end
	end
	return bestId, bestDistance, currentDistance
end

local lookupErrorReported = false

-- Returns the current target, or nil plus a short status message.
-- A quest focused in Questie always wins; `autoQuestId` is only used when nothing is focused.
local function FindTarget(autoQuestId)
	local corpse = CorpseTarget()
	if corpse then
		return corpse
	end
	-- A followed group member replaces quests until they are cleared or leave the group.
	local okFriend, friend = pcall(ns.Friend.Target)
	if okFriend and friend then
		return friend
	end
	local questId = GetFocusedQuestId()
	local auto = false
	if not questId and autoQuestId then
		questId, auto = autoQuestId, true
	end
	if not questId then
		return nil
	end
	local ok, target, quest = pcall(QuestieTarget, questId)
	if not ok then
		-- pcall returns the error message in place of the target. Report the first one per session.
		if not lookupErrorReported then
			lookupErrorReported = true
			print("|cffffd24dStarfall Trail|r Questie lookup failed for quest " .. tostring(questId) .. ": " .. tostring(target))
		end
		target, quest = nil, nil
	end
	if not target then
		local okNative, native = pcall(NativeTarget, questId)
		if okNative and native then
			target = native
		end
	end
	if target then
		target.auto = auto
		return target
	end
	if auto then
		return nil
	end
	local title = ok and quest and quest.name
	return nil, (title and (title .. ": no location known")) or "Focused quest has no location"
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "StarfallTrailFrame", UIParent)
frame:SetSize(ARROW_SIZE, ARROW_SIZE)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()

-- Everything that pops and bobs lives on this child so the anchor never moves.
local art = CreateFrame("Frame", nil, frame)
art:SetSize(ARROW_SIZE, ARROW_SIZE)
art:SetPoint("CENTER")

local function NewTexture(parent, layer, sublevel, file, blend)
	local tex = parent:CreateTexture(nil, layer, nil, sublevel)
	tex:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR")
	if blend then
		tex:SetBlendMode(blend)
	end
	if tex.SetSnapToPixelGrid then
		tex:SetSnapToPixelGrid(false)
		tex:SetTexelSnappingBias(0)
	end
	return tex
end

-- Exactly one body frame is ever drawn: blending two neighbouring angles showed as a double arrow.
-- The 200 angles are split over sheets of 100; each sheet gets its own texture so swapping is free.
local glow = NewTexture(art, "BACKGROUND", 1, MEDIA .. "glow.png", "ADD")
glow:SetAllPoints(art)
-- Every sheet stays shown; the inactive one is just fully transparent. Hiding a sheet let the client
-- release it, so the swap at straight up and straight down (where the sheets meet) drew nothing for a moment.
local bodies = {}
for i = 1, ns.SHEET_COUNT do
	local tex = NewTexture(art, "ARTWORK", 0, MEDIA .. "arrow" .. i .. ".png")
	tex:SetAllPoints(art)
	tex:SetAlpha(0)
	bodies[i] = tex
end

local distanceText = frame:CreateFontString(nil, "OVERLAY")
distanceText:SetFont(FONT, 20, "OUTLINE")
distanceText:SetPoint("TOP", frame, "BOTTOM", 0, ARROW_SIZE * 0.18)
distanceText:SetTextColor(1, 0.92, 0.7)
distanceText:SetShadowOffset(1, -1)

local labelText = frame:CreateFontString(nil, "OVERLAY")
labelText:SetFont(FONT, 13, "OUTLINE")
labelText:SetPoint("TOP", distanceText, "BOTTOM", 0, -3)
labelText:SetTextColor(1, 1, 1)
labelText:SetJustifyH("CENTER")
labelText:SetSpacing(2)
-- Sized to its longest line every time the text changes (see SetLabel), wrapping only past
-- LABEL_MAX_WIDTH, so the client never cuts it off with "...".
labelText:SetWordWrap(true)
labelText:SetNonSpaceWrap(false)
local LABEL_MAX_WIDTH = 520
local labelMeasure = frame:CreateFontString(nil, "OVERLAY")
labelMeasure:SetFont(FONT, 13, "OUTLINE")
labelMeasure:SetWordWrap(false)
labelMeasure:Hide()
local shownLabel

local function SetLabel(text)
	if text == shownLabel then
		return
	end
	shownLabel = text
	local widest = 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		labelMeasure:SetText(line)
		local w = labelMeasure.GetUnboundedStringWidth and labelMeasure:GetUnboundedStringWidth()
			or labelMeasure:GetStringWidth()
		widest = math.max(widest, w)
	end
	labelText:SetWidth(math.min(math.ceil(widest) + 8, LABEL_MAX_WIDTH))
	labelText:SetText(text)
end

local unlockBox = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
unlockBox:SetAllPoints()
unlockBox:SetColorTexture(0.2, 0.6, 1, 0.18)
unlockBox:Hide()

local unlockHint = frame:CreateFontString(nil, "OVERLAY")
unlockHint:SetFont(FONT, 12, "OUTLINE")
unlockHint:SetPoint("BOTTOM", frame, "TOP", 0, 2)
unlockHint:SetText("Starfall Trail: drag to move, /sft lock when done")
unlockHint:Hide()

local FRAME_COUNT, GRID = ns.FRAME_COUNT, ns.GRID

local function SetCell(tex, index, cell, sheet)
	local col = index % GRID
	local row = math.floor(index / GRID)
	local size = cell / sheet
	tex:SetTexCoord(col * size, (col + 1) * size, row * size, (row + 1) * size)
end

local shownBody

-- Selects the cell for `index` on its sheet and returns that texture; the caller sets its alpha.
local function ShowFrame(index)
	local sheetIndex = math.floor(index / ns.FRAMES_PER_SHEET) + 1
	local body = bodies[sheetIndex]
	if body ~= shownBody then
		if shownBody then
			shownBody:SetAlpha(0)
		end
		shownBody = body
	end
	SetCell(body, index % ns.FRAMES_PER_SHEET, ns.CELL, ns.SHEET)
	SetCell(glow, math.floor(index / ns.GLOW_STEP), ns.GLOW_CELL, ns.GLOW_SHEET)
	return body
end

---------------------------------------------------------------------------
-- Animation state
---------------------------------------------------------------------------

local state = {
	time = 0,
	angle = 0,            -- displayed relative angle (radians, counterclockwise)
	velocity = 0,
	visible = 0,          -- 0..1 overall fade
	arrowAlpha = 1,       -- dims while arrived
	aligned = 0,          -- 0..1 how directly you face the target
	arrived = 0,
	isHere = false,       -- inside the arrival radius (with hysteresis)
	liftT = 0,            -- 0..1 progress of the text gliding up on arrival
	distance = nil,
	shownDistance = nil,
	pop = 1,              -- 0 at a new target, eases to 1
	lookupTimer = 0,
	target = nil,
	status = nil,
	testMode = false,
	autoQuestId = nil,    -- quest picked by auto focus
	autoTimer = 0,
}

local function ResetForNewTarget(snapAngle)
	state.pop = 0
	state.shownDistance = nil
	if snapAngle then
		state.angle = snapAngle
		state.velocity = 0
	end
end

local function FormatDistance(yards)
	if yards >= 1000 then
		return string.format("%.1fk yd", yards / 1000)
	end
	return string.format("%d yd", math.floor(yards + 0.5))
end

---------------------------------------------------------------------------
-- Per-frame update
---------------------------------------------------------------------------

local function RefreshTarget()
	local previousKey = state.target and state.target.key
	if state.testMode then
		state.target = { key = "test", test = true, name = "Starfall Trail test", quest = "/sft test to stop" }
		state.status = nil
	else
		state.target, state.status = FindTarget(db.autoFocus and state.autoQuestId or nil)
	end
	local newKey = state.target and state.target.key
	if newKey and newKey ~= previousKey then
		ResetForNewTarget(nil)
	end
	-- A person moves, so their position is read more often than a quest spot.
	if state.target and state.target.friend then
		state.lookupTimer = FRIEND_INTERVAL
	end
end

local function OnUpdate(_, elapsed)
	local dt = math.min(elapsed, 0.1)
	state.time = state.time + dt

	-- Auto focus: pick the closest quest, switching only when another is clearly nearer.
	state.autoTimer = state.autoTimer - dt
	if state.autoTimer <= 0 then
		state.autoTimer = AUTO_INTERVAL
		if db.autoFocus and not state.testMode and not GetFocusedQuestId() and not ns.Friend.Get() then
			local bestId, bestDistance, currentDistance = FindClosestQuest(state.autoQuestId)
			if not bestId then
				state.autoQuestId = nil
			elseif bestId ~= state.autoQuestId then
				local clearlyCloser = not currentDistance
					or (bestDistance < currentDistance - AUTO_SWITCH_YARDS
						and bestDistance < currentDistance * AUTO_SWITCH_RATIO)
				if clearlyCloser then
					state.autoQuestId = bestId
					state.lookupTimer = 0
				end
			end
		end
	end

	state.lookupTimer = state.lookupTimer - dt
	if state.lookupTimer <= 0 then
		state.lookupTimer = TARGET_INTERVAL
		RefreshTarget()
	end

	local target = state.target
	local relative, distance, showArrow = nil, nil, false
	local noHeading = false

	if target and target.test then
		relative = math.sin(state.time * 0.6) * 2.4
		distance = 120 + 80 * math.sin(state.time * 0.3)
		showArrow = true
	elseif target and HBD then
		local px, py, instance = HBD:GetPlayerWorldPosition()
		local facing = GetPlayerFacing()
		noHeading = not (px and facing) or IsSecret(facing)
		if not noHeading and instance == target.instance then
			local angle, dist = HBD:GetWorldVector(instance, px, py, target.x, target.y)
			if angle and dist then
				-- With a terrain route, aim along the route instead of straight at the target.
				local lx, ly = ns.Trail.Lookahead()
				if lx and dist > ARRIVE_YARDS and not (target.friend and dist < FRIEND_DIRECT_YARDS) then
					local routeAngle = HBD:GetWorldVector(instance, px, py, lx, ly)
					angle = routeAngle or angle
				end
				-- Relative to where the camera looks (left-drag swings the camera, not the character).
				relative = angle - (ns.Trail.CameraHeading() or facing)
				distance = dist
				showArrow = true
			end
		end
	end

	-- The ground trail runs every frame, including while the arrow is faded out.
	ns.Trail.SetQuiet(state.isHere)
	ns.Trail.Update(math.min(elapsed, 0.1), target and not target.test and target or nil, db.trail)

	-- Fade the whole widget in or out. While unlocked it always shows, so it can be dragged.
	local wantVisible = (target ~= nil or state.status ~= nil) and 1 or 0
	if not db.locked then
		wantVisible = 1
		showArrow = true
	end
	state.visible = Approach(state.visible, wantVisible, 9, dt)
	if state.visible < 0.01 and wantVisible == 0 then
		frame:SetAlpha(0)
		return
	end
	frame:SetAlpha(state.visible)

	-- Critically damped spring toward the true direction, in small steps for stability.
	if relative then
		if state.pop == 0 and state.distance == nil then
			state.angle = relative
		end
		local remaining = dt
		while remaining > 0 do
			local step = math.min(remaining, 1 / 240)
			local err = WrapPi(relative - state.angle)
			state.velocity = state.velocity + (SPRING * SPRING * err - 2 * SPRING * state.velocity) * step
			state.angle = state.angle + state.velocity * step
			remaining = remaining - step
		end
		state.angle = WrapPi(state.angle)
	end
	state.distance = distance

	-- Nearest rendered angle; with 200 frames the steps are 1.8 degrees.
	local index = math.floor((state.angle % TWO_PI) / TWO_PI * FRAME_COUNT + 0.5) % FRAME_COUNT
	local body = ShowFrame(index)

	-- Facing and arrival feedback.
	local aligned = relative and SmoothStep(math.cos(math.rad(28)), math.cos(math.rad(6)), math.cos(state.angle)) or 0
	state.aligned = Approach(state.aligned, aligned, 6, dt)
	-- Arrive inside ARRIVE_YARDS, leave only past ARRIVE_YARDS + LEAVE_MARGIN, so standing at the
	-- edge does not flicker the arrow and bounce the text.
	local isArea = target and target.area
	local arriveAt = isArea and AREA_ARRIVE_YARDS or ARRIVE_YARDS
	local leaveAt = arriveAt + (isArea and AREA_LEAVE_MARGIN or LEAVE_MARGIN)
	if not distance then
		state.isHere = false
	elseif distance <= arriveAt then
		state.isHere = true
	elseif distance > leaveAt then
		state.isHere = false
	end
	state.arrived = Approach(state.arrived, state.isHere and 1 or 0, 5, dt)
	-- The arrow fades out completely once you are there.
	local arrowWanted = showArrow and (1 - state.arrived) or 0
	state.arrowAlpha = Approach(state.arrowAlpha, arrowWanted, 8, dt)

	-- Pop-in: an underdamped ease so new targets land with a small bounce.
	state.pop = math.min(1, state.pop + dt * 1.6)
	local p = state.pop
	local popScale = 1 - math.exp(-7 * p) * math.cos(11 * p) * 0.45
	art:SetScale(math.max(0.2, popScale))

	local bob = math.sin(state.time * 2.1) * 3 * (1 - state.arrived)
	art:ClearAllPoints()
	art:SetPoint("CENTER", frame, "CENTER", 0, bob)

	body:SetAlpha(state.arrowAlpha)

	local pulse = 0.5 + 0.5 * math.sin(state.time * 2.6)
	glow:SetVertexColor(
		Lerp(GOLD[1], GREEN[1], state.aligned),
		Lerp(GOLD[2], GREEN[2], state.aligned),
		Lerp(GOLD[3], GREEN[3], state.aligned)
	)
	glow:SetAlpha((0.35 + 0.15 * pulse + 0.2 * state.aligned) * state.arrowAlpha)

	-- Arrived: the text glides up into the arrow's place, out of the way while you do the task.
	-- A fixed-length ease-in-out (not an exponential chase) so it starts and stops softly.
	local liftTarget = state.isHere and 1 or 0
	if state.liftT < liftTarget then
		state.liftT = math.min(liftTarget, state.liftT + dt / LIFT_SECONDS)
	elseif state.liftT > liftTarget then
		state.liftT = math.max(liftTarget, state.liftT - dt / LIFT_SECONDS)
	end
	local t = state.liftT
	local eased = t < 0.5 and 4 * t * t * t or 1 - (-2 * t + 2) ^ 3 / 2
	distanceText:ClearAllPoints()
	distanceText:SetPoint("TOP", frame, "BOTTOM", 0, ARROW_SIZE * (0.18 + LIFT_HEIGHT * eased))

	-- Labels.
	if distance then
		if state.shownDistance == nil then
			state.shownDistance = distance
		end
		state.shownDistance = Approach(state.shownDistance, distance, 7, dt)
		if state.arrived > 0.5 then
			distanceText:SetText(target.friend and (target.name .. " is here") or "You're here")
		else
			distanceText:SetText(FormatDistance(state.shownDistance))
		end
	elseif target and target.unavailable then
		distanceText:SetText("")
	elseif target and not target.test then
		distanceText:SetText(noHeading and "No heading available here" or "Not on this continent")
	elseif state.status then
		distanceText:SetText("")
	else
		distanceText:SetText(db.locked and "" or "Starfall Trail")
	end

	local label
	if target and target.friend then
		label = ns.Friend.ColoredName(target.name, target.class)
		if target.unavailable then
			label = label .. ": location not available"
		end
	elseif target then
		local name = target.todo or target.name
		if target.turnIn and name and not target.todo then
			name = "Turn in: " .. name
		end
		if name and target.quest and name ~= target.quest then
			label = name .. "\n|cffffd24d" .. target.quest .. "|r"
		else
			label = name or (target.quest and ("|cffffd24d" .. target.quest .. "|r")) or ""
		end
		if target.auto then
			label = label .. " |cff8fa3b8(auto)|r"
		end
	else
		label = state.status or ""
	end
	SetLabel(label)
end

-- One bad API difference must not become an error popup every frame: report once, stop after a few.
local failures = 0
local function GuardedUpdate(self, elapsed)
	local ok, err = pcall(OnUpdate, self, elapsed)
	if ok then
		return
	end
	failures = failures + 1
	if failures == 1 then
		print("|cffffd24dStarfall Trail|r error: " .. tostring(err))
	end
	if failures >= 5 then
		self:SetScript("OnUpdate", nil)
		self:Hide()
		print("|cffffd24dStarfall Trail|r stopped after repeated errors. Send the message above to fix it.")
	end
end

frame:SetScript("OnUpdate", GuardedUpdate)

---------------------------------------------------------------------------
-- Position, locking and slash commands
---------------------------------------------------------------------------

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relativePoint or db.point, db.x, db.y)
	frame:SetScale(db.scale)
end

-- While unlocked everything shows, so there is something to grab.
local function ApplyVisibility()
	art:SetShown(db.arrow or not db.locked)
	distanceText:SetShown(db.text or not db.locked)
	labelText:SetShown(db.text or not db.locked)
end

local function ApplyLock()
	frame:EnableMouse(not db.locked)
	unlockBox:SetShown(not db.locked)
	unlockHint:SetShown(not db.locked)
	ApplyVisibility()
end

-- Settings shared by the slash commands and the minimap menu.
ns.Settings = {}

function ns.Settings.Get(key)
	return db and db[key]
end

function ns.Settings.Set(key, value)
	db[key] = value
	if key == "trail" and not value then
		ns.Trail.Stop()
	elseif key == "locked" then
		ApplyLock()
	elseif key == "arrow" or key == "text" then
		ApplyVisibility()
	end
	ns.Menu.Refresh()
end

frame:SetScript("OnDragStart", function(self)
	if not db.locked then
		self:StartMoving()
	end
end)

frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relativePoint, x, y = self:GetPoint(1)
	db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
	ApplyPosition()
end)

local function Print(msg)
	print("|cffffd24dStarfall Trail|r " .. msg)
end

SLASH_STARFALLTRAIL1 = "/starfall"
SLASH_STARFALLTRAIL2 = "/sft"
SlashCmdList.STARFALLTRAIL = function(input)
	local cmd, arg = strsplit(" ", (input or ""):lower(), 2)
	if cmd == "arrow" or cmd == "text" then
		ns.Settings.Set(cmd, not db[cmd])
		Print((cmd == "arrow" and "arrow " or "text under the arrow ") .. (db[cmd] and "on." or "off."))
	elseif cmd == "minimap" then
		ns.Settings.Set("minimapHidden", not db.minimapHidden)
		ns.Menu.ApplyButton()
		Print(db.minimapHidden and "minimap button hidden (/sft minimap to show it)." or "minimap button shown.")
	elseif cmd == "unlock" then
		db.locked = false
		ApplyLock()
		Print("unlocked. Drag the arrow, then type /sft lock.")
	elseif cmd == "lock" then
		db.locked = true
		ApplyLock()
		Print("locked.")
	elseif cmd == "scale" then
		local value = tonumber(arg)
		if value then
			db.scale = Clamp(value, 0.4, 2.5)
			ApplyPosition()
			Print(string.format("scale %.2f", db.scale))
		else
			Print("usage: /sft scale 1.2")
		end
	elseif cmd == "reset" then
		for k, v in pairs(DEFAULTS) do
			db[k] = v
		end
		db.relativePoint = nil
		ns.Friend.Clear()
		ApplyPosition()
		ApplyLock()
		ns.Menu.ApplyButton()
		Print("settings, position and size reset.")
	elseif cmd == "rec" then
		local on, count = ns.Trail.ToggleRecording()
		Print(on and "camera recording on. Move the camera around; /sft rec again to stop."
			or ("camera recording off: " .. count .. " samples. /reload to write them to disk."))
	elseif cmd == "trail" then
		if arg == "status" then
			Print(ns.Trail.Status())
			local Nav = ns.Nav
			if Nav.loadError then
				Print("map data failed to load: " .. Nav.loadError)
			elseif Nav.loadMs then
				UpdateAddOnMemoryUsage()
				local kb = 0
				for _, name in ipairs({ "StarfallTrail_Kalimdor", "StarfallTrail_EasternKingdoms" }) do
					kb = kb + (GetAddOnMemoryUsage(name) or 0)
				end
				Print(format("map data loaded in %.0f ms, %.1f MB", Nav.loadMs, kb / 1024))
			end
		elseif arg == "log" then
			local on, count = ns.Trail.ToggleSolveLog()
			Print(on and "trail log on: walk along the trail, then /sft trail log again."
				or ("trail log off: " .. count .. " frames. /reload to write them to disk."))
		elseif arg == "debug" then
			ns.Trail.debug = not ns.Trail.debug
			Print(ns.Trail.debug and "trail debug view on: raw line plus measured anchors." or "trail debug view off: sparkles.")
		else
			ns.Settings.Set("trail", not db.trail)
			Print(db.trail and "ground trail on." or "ground trail off.")
		end
	elseif cmd == "auto" then
		db.autoFocus = not db.autoFocus
		state.autoQuestId = nil
		state.autoTimer = 0
		state.lookupTimer = 0
		Print(db.autoFocus
			and "auto focus on: with nothing focused in Questie, the arrow picks your closest quest."
			or "auto focus off: the arrow only follows the quest you focus in Questie.")
	elseif cmd == "friend" or cmd == "follow" then
		arg = arg and strtrim(arg) or ""
		local ok, result
		if arg == "off" or arg == "stop" or arg == "clear" then
			local _, name = ns.Friend.Get()
			ns.Friend.Clear()
			Print(name and ("no longer following " .. name .. ".") or "not following anyone.")
			return
		elseif arg ~= "" then
			ok, result = ns.Friend.SetByName(arg)
		elseif UnitExists("target") then
			ok, result = ns.Friend.SetByUnit("target")
		else
			local _, name = ns.Friend.Get()
			Print(name and ("following " .. name .. ". /sft friend off to stop.")
				or "usage: /sft friend <name of a group member>, or target them and type /sft friend. /sft friend off to stop.")
			return
		end
		Print(ok and ("following " .. result .. ". /sft friend off to stop.") or result)
	elseif cmd == "probe" then
		if arg == "party" then
			ns.ProbeParty()
		elseif arg == "live" then
			ns.ProbeLive()
		elseif arg == "nav" then
			ns.ProbeNav()
		elseif arg == "trail" then
			ns.ProbeTrail()
		elseif arg == "view" then
			ns.ProbeView()
		elseif arg == "height" then
			ns.Trail.StartHeightTest()
			Print("height test running, hold still for a moment...")
		else
			ns.ProbeReport()
		end
	elseif cmd == "test" then
		state.testMode = not state.testMode
		state.lookupTimer = 0
		Print(state.testMode and "test mode on (the arrow sweeps by itself)." or "test mode off.")
	else
		Print("focus a quest in Questie's tracker (right-click > Focus Quest) and the arrow points to it.")
		Print("auto focus is " .. (db.autoFocus and "on" or "off") .. ": with nothing focused, it points at your closest quest.")
		Print("/sft friend <name> leads you to a group member instead (/sft friend off to stop).")
		Print("/sft trail | arrow | text | auto | friend | minimap | unlock | lock | scale <0.4-2.5> | reset | test")
	end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name == ADDON_NAME then
		StarfallTrailDB = StarfallTrailDB or {}
		db = StarfallTrailDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then
				db[k] = v
			end
		end
		ns.Friend.Init(db)
		ns.Friend.onChange = function()
			state.lookupTimer = 0
			ns.Menu.Refresh()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Load this continent's walkable-area map now, behind the loading screen, not mid-run.
		local _, _, instance = HBD and HBD:GetPlayerWorldPosition()
		if instance then
			ns.Nav.LoadMesh(instance)
		end
	elseif event == "PLAYER_LOGIN" then
		ns.Menu.Init()
		-- Questie ships HereBeDragons under its own name; a standalone copy uses the standard one.
		HBD = LibStub and (LibStub("HereBeDragonsQuestie-2.0", true) or LibStub("HereBeDragons-2.0", true))
		if not HBD then
			Print("needs Questie (for its map library). The arrow is disabled.")
			return
		end
		ns.HBD = HBD
		ApplyPosition()
		ApplyLock()
		frame:SetAlpha(0)
		frame:Show()
		ns.Trail.Show()
	end
end)
