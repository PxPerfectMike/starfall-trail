-- Starfall Trail probe: reports which camera-related data this client exposes to addons.
-- Used to decide whether a ground-anchored 3D trail is possible. Run with /sft probe or /sft probe live.

local _, ns = ...

local CVARS = {
	"cameraFov",
	"cameraFieldOfView",
	"cameraPitchMoveSpeed",
	"cameraYawMoveSpeed",
	"cameraSmoothStyle",
	"cameraView",
	"cameraDistanceMaxZoomFactor",
	"test_cameraDynamicPitch",
	"test_cameraDynamicPitchBaseFovPad",
	"test_cameraDynamicPitchBaseFovPadFlying",
	"test_cameraDynamicPitchBaseFovPadDownScale",
	"test_cameraDynamicPitchSmartPivotCutoffDist",
	"test_cameraOverShoulder",
	"nameplateShowSelf",
	"nameplateShowAll",
}

local log

-- Prints, and also records into StarfallTrailDB.probeLog so the full report can be read from disk after /reload.
local function Out(msg)
	print("|cff7fd4ffWF probe|r " .. msg)
	if log then
		log[#log + 1] = msg
	end
end

local function Describe(value)
	if value == nil then
		return "nil"
	end
	if issecretvalue and issecretvalue(value) then
		return "<secret>"
	end
	return tostring(value)
end

local function ListFunctions(name, tbl)
	if type(tbl) ~= "table" then
		Out(name .. ": missing")
		return
	end
	local names = {}
	for k, v in pairs(tbl) do
		if type(v) == "function" then
			names[#names + 1] = k
		end
	end
	table.sort(names)
	Out(name .. ": " .. (#names > 0 and table.concat(names, ", ") or "(no functions)"))
end

local function SelfPlate()
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
		return nil, "C_NamePlate.GetNamePlateForUnit missing"
	end
	local plate = C_NamePlate.GetNamePlateForUnit("player")
	if not plate then
		return nil, "no self nameplate (nameplateShowSelf off?)"
	end
	local x, y = plate:GetCenter()
	if not x then
		return nil, "self nameplate has no position"
	end
	local scale = plate:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local cx, cy = UIParent:GetCenter()
	return { x = x * scale - cx, y = y * scale - cy }
end

function ns.ProbeReport()
	log = {}
	if StarfallTrailDB then
		StarfallTrailDB.probeLog = log
	end
	Out("---- functions ----")
	Out("GetCameraZoom: " .. (GetCameraZoom and Describe(GetCameraZoom()) or "missing"))
	Out("IsMouselooking: " .. (IsMouselooking and Describe(IsMouselooking()) or "missing"))
	Out("GetPlayerFacing: " .. Describe(GetPlayerFacing and GetPlayerFacing()))
	Out("SaveView/SetView: " .. tostring(SaveView ~= nil) .. "/" .. tostring(SetView ~= nil))
	if UnitPosition then
		local a, b, c, d = UnitPosition("player")
		Out("UnitPosition(player): " .. Describe(a) .. ", " .. Describe(b) .. ", " .. Describe(c) .. ", " .. Describe(d))
	else
		Out("UnitPosition: missing")
	end
	ListFunctions("C_Navigation", C_Navigation)
	ListFunctions("C_SuperTrack", C_SuperTrack)
	Out("C_Map.SetUserWaypoint: " .. tostring(C_Map and C_Map.SetUserWaypoint ~= nil))
	Out("---- cvars ----")
	for _, name in ipairs(CVARS) do
		local ok, value = pcall(GetCVar, name)
		Out(name .. " = " .. (ok and Describe(value) or "error"))
	end
	Out("---- screen ----")
	Out(string.format("UIParent %.0fx%.0f, scale %.3f", UIParent:GetWidth(), UIParent:GetHeight(), UIParent:GetEffectiveScale()))
	local plate, why = SelfPlate()
	Out("self nameplate: " .. (plate and string.format("%.1f, %.1f from screen center", plate.x, plate.y) or why))
end

-- Group positions: what the client gives addons for each party or raid member. Run it in a group,
-- outdoors, to check that the arrow can follow a person (/sft probe party).
function ns.ProbeParty()
	log = {}
	if StarfallTrailDB then
		StarfallTrailDB.probeLog = log
	end
	Out("---- group positions ----")
	local units = { "player" }
	if IsInRaid and IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			units[#units + 1] = "raid" .. i
		end
	else
		for i = 1, 4 do
			units[#units + 1] = "party" .. i
		end
	end
	local found = 0
	for _, unit in ipairs(units) do
		if UnitExists(unit) then
			found = found + 1
			Out(unit .. " = " .. Describe(UnitName(unit)) .. ", guid " .. Describe(UnitGUID(unit)))
			if UnitPosition then
				local ok, a, b, c, d = pcall(UnitPosition, unit)
				Out("  UnitPosition: " .. (ok and (Describe(a) .. ", " .. Describe(b) .. ", " .. Describe(c) .. ", " .. Describe(d))
					or ("error " .. tostring(a))))
			else
				Out("  UnitPosition: missing")
			end
			local mapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit(unit)
			local okPos, pos = pcall(function()
				return mapId and C_Map.GetPlayerMapPosition(mapId, unit)
			end)
			if okPos and pos and not (issecretvalue and issecretvalue(pos)) then
				local x, y = pos:GetXY()
				Out("  map " .. Describe(mapId) .. " position: " .. Describe(x) .. ", " .. Describe(y))
			else
				Out("  map " .. Describe(mapId) .. " position: " .. (okPos and "none" or "error"))
			end
			if unit ~= "player" then
				local x, y, instance = ns.Friend.Position(unit)
				Out("  arrow can use it: " .. (x and string.format("yes (%.1f, %.1f, map %s)", x, y, tostring(instance)) or "NO"))
			end
		end
	end
	if found <= 1 then
		Out("you are not in a group: join one and run this again.")
	end
end

-- Live readout: zoom, mouselook and the self nameplate's screen offset, refreshed every frame.
local live = CreateFrame("Frame", nil, UIParent)
live:SetSize(420, 120)
live:SetPoint("LEFT", UIParent, "LEFT", 20, 120)
live:Hide()
local text = live:CreateFontString(nil, "OVERLAY")
text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 15, "OUTLINE")
text:SetPoint("TOPLEFT")
text:SetJustifyH("LEFT")
local bg = live:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.55)

live:SetScript("OnUpdate", function()
	local zoom = GetCameraZoom and GetCameraZoom()
	local plate, why = SelfPlate()
	local _, _, z = UnitPosition and UnitPosition("player")
	local lines = {
		"WF probe live (/sft probe live to close)",
		"zoom: " .. Describe(zoom),
		"mouselook: " .. Describe(IsMouselooking and IsMouselooking()) .. "  L:" .. tostring(IsMouseButtonDown("LeftButton")) .. " R:" .. tostring(IsMouseButtonDown("RightButton")),
		"facing: " .. Describe(GetPlayerFacing and GetPlayerFacing()) .. "  height: " .. Describe(z),
		"self plate: " .. (plate and string.format("x %.1f  y %.1f", plate.x, plate.y) or why),
	}
	text:SetText(table.concat(lines, "\n"))
end)

---------------------------------------------------------------------------
-- Navigation projector test: drop a map pin near the player, super track it, and put a dot
-- wherever C_Navigation says that world spot is on screen. If the dot stays glued to the
-- ground while the camera moves, the client is projecting world points for us.
---------------------------------------------------------------------------

local nav = CreateFrame("Frame", nil, UIParent)
nav:SetAllPoints()
nav:Hide()
local dot = nav:CreateTexture(nil, "OVERLAY")
dot:SetSize(18, 18)
dot:SetTexture("Interface\\AddOns\\StarfallTrail\\Media\\ring.png")
dot:SetVertexColor(0.3, 0.95, 1)
local navText = nav:CreateFontString(nil, "OVERLAY")
navText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 15, "OUTLINE")
navText:SetPoint("LEFT", UIParent, "LEFT", 20, -60)
navText:SetJustifyH("LEFT")

local navSampleTimer = 0
nav:SetScript("OnUpdate", function(_, elapsed)
	local frame = C_Navigation.GetFrame()
	local valid = C_Navigation.HasValidScreenPosition()
	local clamped = C_Navigation.WasClampedToScreen and C_Navigation.WasClampedToScreen()
	local dist = C_Navigation.GetDistance()
	local x, y
	if frame then
		local fx, fy = frame:GetCenter()
		if fx then
			local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
			x, y = fx * scale, fy * scale
			dot:ClearAllPoints()
			dot:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
		end
	end
	dot:SetShown(x ~= nil)
	local cx, cy = UIParent:GetCenter()
	local line = string.format("nav frame: %s  valid: %s  clamped: %s  dist: %s\nscreen: %s  zoom: %.2f  facing: %.3f",
		tostring(frame ~= nil), Describe(valid), Describe(clamped), Describe(dist),
		x and string.format("%.1f, %.1f from center", x - cx, y - cy) or "none",
		GetCameraZoom and GetCameraZoom() or -1, GetPlayerFacing() or -1)
	navText:SetText(line)
	navSampleTimer = navSampleTimer - elapsed
	if log and navSampleTimer <= 0 then
		navSampleTimer = 0.25
		log[#log + 1] = line:gsub("\n", " | ")
	end
end)

function ns.ProbeNav()
	if nav:IsShown() then
		nav:Hide()
		if C_Map.ClearUserWaypoint then
			C_Map.ClearUserWaypoint()
		end
		Out("nav test off, map pin cleared.")
		return
	end
	if not (C_Navigation and C_Map and C_Map.SetUserWaypoint and UiMapPoint and C_SuperTrack) then
		Out("nav test unavailable: missing C_Navigation, C_Map.SetUserWaypoint or UiMapPoint.")
		return
	end
	local mapId = C_Map.GetBestMapForUnit("player")
	local pos = mapId and C_Map.GetPlayerMapPosition(mapId, "player")
	if not pos then
		Out("nav test: no map position here.")
		return
	end
	local px, py = pos:GetXY()
	-- About 30 yards north on most zone maps (map y grows southward).
	local point = UiMapPoint.CreateFromCoordinates(mapId, px, py - 0.012)
	if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapId) then
		Out("nav test: this map does not allow user waypoints.")
		return
	end
	C_Map.SetUserWaypoint(point)
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	log = {}
	if StarfallTrailDB then
		StarfallTrailDB.probeLog = log
	end
	Out(string.format("nav test on: pin at map %d (%.4f, %.4f). Watch the cyan ring.", mapId, px, py - 0.012))
	nav:Show()
end

---------------------------------------------------------------------------
-- Trail prototype: cycle the user waypoint through several points on a line, one per frame.
-- The navigation frame reports where last frame's point landed on screen; a dot is kept there.
---------------------------------------------------------------------------

local TRAIL_POINTS = 10
local trail = CreateFrame("Frame", nil, UIParent)
trail:SetAllPoints()
trail:Hide()
local trailDots, trailPoints = {}, {}
for i = 1, TRAIL_POINTS do
	local tex = trail:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\AddOns\\StarfallTrail\\Media\\ring.png")
	tex:SetBlendMode("ADD")
	tex:SetVertexColor(1, 0.85, 0.35)
	tex:SetSize(16, 16)
	tex:Hide()
	trailDots[i] = tex
end
local trailMap, trailIndex, trailFrames, trailUpdates = nil, 0, 0, 0

trail:SetScript("OnUpdate", function()
	trailFrames = trailFrames + 1
	-- Read where the point set on the previous frame landed.
	if trailIndex > 0 then
		local frame = C_Navigation.GetFrame()
		if frame and C_Navigation.HasValidScreenPosition() then
			local fx, fy = frame:GetCenter()
			if fx then
				local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
				local dotTex = trailDots[trailIndex]
				dotTex:ClearAllPoints()
				dotTex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", fx * scale, fy * scale)
				dotTex:Show()
				trailUpdates = trailUpdates + 1
			end
		end
	end
	trailIndex = trailIndex % TRAIL_POINTS + 1
	local p = trailPoints[trailIndex]
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(trailMap, p[1], p[2]))
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end)

function ns.ProbeTrail()
	if trail:IsShown() then
		trail:Hide()
		for _, tex in ipairs(trailDots) do
			tex:Hide()
		end
		if C_Map.ClearUserWaypoint then
			C_Map.ClearUserWaypoint()
		end
		Out(string.format("trail test off. %d frames, %d dot updates.", trailFrames, trailUpdates))
		return
	end
	local mapId = C_Map.GetBestMapForUnit("player")
	local pos = mapId and C_Map.GetPlayerMapPosition(mapId, "player")
	if not pos then
		Out("trail test: no map position here.")
		return
	end
	local px, py = pos:GetXY()
	for i = 1, TRAIL_POINTS do
		-- A straight line heading north from the player, roughly a few yards apart.
		trailPoints[i] = { px, py - 0.0025 * i }
	end
	trailMap, trailIndex, trailFrames, trailUpdates = mapId, 0, 0, 0
	trail:Show()
	Out("trail test on: " .. TRAIL_POINTS .. " points heading north. Move the camera; the dots should stay on the ground.")
end

local savedShowSelf

function ns.ProbeLive()
	if live:IsShown() then
		live:Hide()
		if savedShowSelf ~= nil and not InCombatLockdown() then
			SetCVar("nameplateShowSelf", savedShowSelf)
		end
		Out("live readout off.")
		return
	end
	if not InCombatLockdown() then
		savedShowSelf = GetCVar("nameplateShowSelf")
		SetCVar("nameplateShowSelf", "1")
	end
	live:Show()
	Out("live readout on. Zoom and tilt the camera and watch the numbers.")
end

-- Camera-view probe: does saving the current camera view expose its pitch and turn to addons?
-- Lists every camera/view setting, saves the view into slot 5, and records which settings changed,
-- next to the camera the trail currently measures. Appends to StarfallTrailDB.viewLog on each run.
function ns.ProbeView()
	local entry = {}
	local function Add(msg)
		print("|cff7fd4ffWF view|r " .. msg)
		entry[#entry + 1] = msg
	end
	local names = {}
	local all = (C_Console and C_Console.GetAllCommands and C_Console.GetAllCommands())
		or (ConsoleGetAllCommands and ConsoleGetAllCommands())
	if all then
		for _, c in ipairs(all) do
			local n = c.command or c.name
			if type(n) == "string" then
				local low = n:lower()
				if low:find("camera") or low:find("view") or low:find("pitch") or low:find("yaw") then
					names[#names + 1] = n
				end
			end
		end
	end
	Add(string.format("%d camera/view settings found (command list %s)", #names, all and "available" or "MISSING"))
	local before = {}
	for _, n in ipairs(names) do
		before[n] = GetCVar(n)
	end
	local ok, err = pcall(SaveView, 5)
	Add("SaveView(5): " .. (ok and "ok" or ("error " .. tostring(err))))
	local changed = 0
	for _, n in ipairs(names) do
		local v = GetCVar(n)
		if v ~= before[n] then
			Add(n .. ": " .. tostring(before[n]) .. " -> " .. tostring(v))
			changed = changed + 1
		end
	end
	for _, n in ipairs({ "cameraSavedPitch", "cameraSavedYaw", "cameraSavedDistance", "cameraView5Pitch", "cameraView5Yaw", "cameraView5Distance" }) do
		Add(n .. " = " .. tostring(GetCVar(n)))
	end
	local cam = ns.Trail.Camera()
	Add(string.format("measured camera: heading %.4f, pitch %.4f | facing %.4f, zoom %.2f, mouselook %s",
		cam.heading or -1, cam.pitch or -1, GetPlayerFacing() or -1, GetCameraZoom() or -1, tostring(IsMouselooking())))
	Add(changed .. " settings changed by SaveView")
	-- Everything camera-related, for the record (only to the saved log, not chat).
	for _, n in ipairs(names) do
		entry[#entry + 1] = "  " .. n .. " = " .. tostring(GetCVar(n))
	end
	StarfallTrailDB.viewLog = StarfallTrailDB.viewLog or {}
	table.insert(StarfallTrailDB.viewLog, entry)
end
