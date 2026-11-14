-- Starfall Trail trail: a soft cloud of sparkles on the ground along the computed route.
--
-- The client reports where the super tracked user waypoint appears on screen (C_Navigation).
-- Camera: each frame the waypoint is placed ahead of the player; the client draws its marker at the
-- player's height, so that one reading solves the camera's heading and pitch (see the camera
-- model section). Every trail point is then projected at its true ground height from one
-- consistent camera, so the whole path moves rigidly with the world.

local _, ns = ...

local Trail = {}
ns.Trail = Trail

local AHEAD_YARDS = 45          -- how far ahead of you the trail is drawn
local START_YARDS = 5           -- the trail begins this far ahead of you, so it never covers your character
local START_FADE_YARDS = 4      -- and fades in over this distance beyond that
local LOOKAHEAD_YARDS = 25      -- the arrow aims at this point along the route
local OFF_ROUTE_YARDS = 12      -- re-route when you are this far from the path
local REQUEST_COOLDOWN = 1.5
local SPACING = 2.5             -- must match Nav.lua SAMPLE_SPACING

-- Sparkles: each is fixed to one spot on the ground beside the route, blooms in, glimmers gently
-- and dissolves after a second or two while new ones bloom elsewhere. They are redrawn at their
-- ground spot every frame, so they move with the world while you walk or turn and stay put
-- when you stand still.
local SPARKS = 320                     -- texture pool, including sparkles crossfading out
local SPARKS_PER_YARD = 70 / 45        -- density along the trail
local LIFE_MIN, LIFE_MAX = 1.0, 2.2    -- natural lifespan, seconds
local BLOOM_IN, DISSOLVE_OUT = 0.35, 0.6
local SWAP_TIME = 0.08                 -- afterglow left at a sparkle's old spot when it is corrected
local AFTERGLOW = 0.3                  -- its starting brightness, relative to the sparkle
local PASSED_FADE = 0.3                -- fade for sparkles you walk past
local QUIET_FADE = 0.6                 -- slower fade for the whole trail on reaching the quest area
local SPREAD_YARDS = 0.6               -- sideways scatter around the route (standard deviation)
local SPREAD_MAX = 1.6
local LIFT_MIN, LIFT_MAX = 0.05, 0.4   -- height above the ground
-- Each sparkle floats on its own: a slow bob, a slight sideways waft, and a rise as it fades.
local FLOAT_AMP_MIN, FLOAT_AMP_MAX = 0.06, 0.22   -- bob height, yards
local FLOAT_HZ_MIN, FLOAT_HZ_MAX = 0.25, 0.6      -- bob speed, cycles per second
local WAFT_MAX = 0.18                             -- sideways waft, yards
local RISE_MIN, RISE_MAX = 0.25, 0.8              -- drift upward over its life, yards
local SIZE_SCALE = 360                 -- on-screen size = SIZE_SCALE * size factor / depth
local REVEAL_SPEED = 55                -- yards per second (average) the trail builds out for a new path
local FILL_PER_FRAME = 8
local EDGE_YARDS = 8                   -- the trail's leading edge fades in over this distance
local CANDIDATES = 5                   -- best of N random spots keeps sparkles evenly spread

local MEDIA = "Interface\\AddOns\\StarfallTrail\\Media\\"
local sqrt, floor, sin, exp, max, min = math.sqrt, math.floor, math.sin, math.exp, math.max, math.min

local frame = CreateFrame("Frame", nil, UIParent)
frame:SetAllPoints()
frame:SetFrameStrata("BACKGROUND")
frame:Hide()

-- Twinkling particles that float along the route: half four-point stars, half soft motes.
local sparks = {}
for i = 1, SPARKS do
	local tex = frame:CreateTexture(nil, "OVERLAY")
	local star = i % 2 == 0
	tex:SetTexture(MEDIA .. (star and "sparkle.png" or "mote.png"), "CLAMP", "CLAMP", "TRILINEAR")
	tex:SetBlendMode("ADD")
	tex:SetAlpha(0)
	if tex.SetSnapToPixelGrid then
		tex:SetSnapToPixelGrid(false)
		tex:SetTexelSnappingBias(0)
	end
	sparks[i] = { tex = tex, star = star, state = "off" }
end

-- Camera recorder state and step function; assigned further down, declared here so the
-- per-frame Trail.Update (defined before them) refers to these locals, not to globals.
local rec, RecordStep, SmoothPosition, ExactProgress, FarProbeVisible

local s = {
	time = 0,
	progress = 1,          -- index of the route point nearest the player
	probe = nil,           -- world spot whose waypoint was set last frame { x, y }
	pz = 0,                -- ground height under the player this frame
	zoom = 15,
	reveal = 0,            -- yards of trail revealed so far for the current target
	sparkFrame = 0,
	swaps = 0,
	requestTimer = 0,
	waypointActive = false,
	route = nil,
}

local function Distance(ax, ay, bx, by)
	local dx, dy = ax - bx, ay - by
	return sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- Waypoint projection
---------------------------------------------------------------------------

local function ReleaseWaypoint()
	if s.waypointActive then
		s.waypointActive = false
		if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
			C_SuperTrack.SetSuperTrackedUserWaypoint(false)
		end
		if C_Map and C_Map.ClearUserWaypoint then
			C_Map.ClearUserWaypoint()
		end
	end
	s.probe = nil
end

-- World point to a map the client accepts user waypoints on.
local function MapPoint(x, y)
	local HBD = ns.HBD
	local mapId = C_Map.GetBestMapForUnit("player")
	local tries = 0
	while mapId and tries < 4 do
		local mx, my = HBD:GetZoneCoordinatesFromWorld(x, y, mapId, true)
		if mx and mx >= 0 and mx <= 1 and my >= 0 and my <= 1
			and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(mapId)) then
			return mapId, mx, my
		end
		local info = C_Map.GetMapInfo(mapId)
		mapId = info and info.parentMapID
		tries = tries + 1
	end
	return nil
end

local function SetWaypoint(x, y, z)
	local mapId, mx, my = MapPoint(x, y)
	if not mapId then
		return false
	end
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapId, mx, my, z))
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	s.waypointActive = true
	return true
end

-- Where the point set last frame landed on screen; nil when off screen or unknown.
local function ReadProjection()
	local navFrame = C_Navigation.GetFrame()
	if not (navFrame and C_Navigation.HasValidScreenPosition()) then
		return nil
	end
	if C_Navigation.WasClampedToScreen and C_Navigation.WasClampedToScreen() then
		return nil
	end
	local fx, fy = navFrame:GetCenter()
	if not fx then
		return nil
	end
	local scale = navFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
	return fx * scale, fy * scale
end

-- Which screen edge the marker was pinned to when it was off screen: "top" (looking steeply down),
-- "bottom" (looking steeply up) or "side"; nil when it is on screen.
local function OffscreenEdge()
	local navFrame = C_Navigation.GetFrame()
	if not (navFrame and C_Navigation.WasClampedToScreen and C_Navigation.WasClampedToScreen()) then
		return nil
	end
	local fx, fy = navFrame:GetCenter()
	if not fx then
		return "side"
	end
	local scale = navFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
	fx, fy = fx * scale, fy * scale
	local top, bottom = UIParent:GetHeight() - fy, fy
	local side = min(fx, UIParent:GetWidth() - fx)
	if top <= bottom and top <= side then
		return "top"
	elseif bottom <= side then
		return "bottom"
	end
	return "side"
end

---------------------------------------------------------------------------
-- Camera model, fitted offline from /sft rec samples (tools/fit_camera.py, median error ~4 units).
-- The client draws the waypoint marker at the player's own height (user waypoints carry no
-- height), so one marker reading per frame pins down the camera exactly. Trail points are then
-- projected with their true ground heights from the terrain grid, all from one consistent camera.
---------------------------------------------------------------------------

local CAM = {
	fov = math.rad(52.98),   -- vertical field of view
	pivot = 2.556,           -- camera orbits this far above the player's feet
	k = 0.8782, b = 1.889,   -- camera distance = k * zoom + b
	-- The marker frame's centre is exactly the ground spot at the player's height (confirmed in
	-- game 11/08/2026: the raw centre sits on the path; the earlier fitted 67-unit offset was wrong).
	markerDz = 0,
	markerOx = 0,
	markerOy = 0,
}
-- Raw solution (heading, pitch) is smoothed into the displayed camera (sHeading, sPitch).
-- zoff: the player's real height minus the grid height under them. Markers cannot measure it
-- (camera and marker both move with the player), so it stays 0; estimating it made the line
-- drift further and further while standing still.
local cam = { heading = nil, pitch = 0.35, zoff = 0, sHeading = nil, sPitch = 0.35, valid = false, error = 0 }
-- Where the camera probe goes. The client draws every user waypoint as a diamond on the minimap
-- (engine-drawn, nothing hides it; waypoint height is ignored, SaveView exposes no live camera
-- angles, tested 11/08/2026), and the marker must be inside the view to be measured (it is always
-- drawn at the player's height, so beyond ~100-120 yards at a usual 25-degree tilt it is above the
-- top of the screen). So, every frame:
--   1. a spot exists beyond the minimap's reach but inside the view: put the probe there (hidden);
--   2. otherwise, while the camera is being dragged (and briefly after): a visible probe, 100 yards
--      ahead, or 3 yards when looking steeply down;
--   3. otherwise: no probe at all; the camera is estimated (heading from the character's facing,
--      tilt held), which is right while the camera simply follows the character.
local PROBE_FAR = 100
local PROBE_CLOSE = 3
local PROBE_RETURN = math.rad(3)     -- go back out only once the far marker would be this far inside the view
local VIEW_MARGIN = math.rad(3)      -- a hidden probe must sit this far inside the top of the view
local PIN_MARGIN = 14                -- minimap units beyond the rim, so no part of the pin shows
local DRAG_HOLD = 0.6                -- seconds of visible measuring after the camera was dragged

-- True when a point PROBE_FAR yards ahead at the player's height is inside the view, with margin.
function FarProbeVisible(pitch, zoom, margin)
	local dist = CAM.k * zoom + CAM.b
	local camUp = CAM.pivot + dist * math.sin(pitch)     -- camera height above the player's feet
	local camBack = dist * math.cos(pitch)               -- camera distance behind the player
	local below = math.atan(camUp / (PROBE_FAR + camBack)) -- angle under the horizontal
	return pitch - below < CAM.fov / 2 - margin
end

-- Farthest distance ahead, at the player's height, that is still inside the view (with margin).
local function MaxVisibleDistance(pitch, zoom)
	local dist = CAM.k * zoom + CAM.b
	local camUp = CAM.pivot + dist * math.sin(pitch)
	local camBack = dist * math.cos(pitch)
	local need = pitch - (CAM.fov / 2 - VIEW_MARGIN)
	if need <= 0.001 then
		return math.huge
	end
	return camUp / math.tan(need) - camBack
end

-- Nearest distance at which the minimap no longer shows a pin, or nil when unknown.
local function HiddenDistance()
	if not (C_Minimap and C_Minimap.GetViewRadius and Minimap) then
		return nil
	end
	local radius = C_Minimap.GetViewRadius()
	local width = Minimap:GetWidth()
	if not radius or radius <= 0 or not width or width <= 0 then
		return nil
	end
	-- Square minimaps (some UI addons) reach farther in their corners.
	local shape = GetMinimapShape and GetMinimapShape()
	local reach = (shape and shape ~= "ROUND") and radius * 1.42 or radius
	return reach + PIN_MARGIN * 2 * radius / width
end

-- Adaptive smoothing (one-euro filter): heavy while the camera is still, so measurement noise
-- cannot shake the trail, and nearly none while it turns, so the trail stays glued to the ground.
local STILL_CUTOFF = 0.4     -- Hz, smoothing cutoff with a motionless camera
local SPEED_CUTOFF = 25      -- extra Hz per radian per second of camera motion
local SPEED_FILTER = 4       -- Hz, smoothing of the motion estimate itself
local RECOVERY_SWEEP = { 0, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, 3.14 }

-- Screen position (UIParent units, origin bottom-left) of world point (x, y, z), plus depth.
-- pz is the player's real height (feet).
local function Project(x, y, z, heading, pitch, px, py, pz, zoom)
	local dx, dy = math.sin(heading), math.cos(heading)
	local cp, sp = math.cos(pitch), math.sin(pitch)
	local dist = CAM.k * zoom + CAM.b
	local cx = px - dist * cp * dx
	local cy = py - dist * cp * dy
	local cz = pz + CAM.pivot + dist * sp
	local vx, vy, vz = x - cx, y - cy, z - cz
	local along = vx * dx + vy * dy
	local xc = -vx * dy + vy * dx
	local yc = sp * along + cp * vz
	local zc = cp * along - sp * vz
	if zc < 0.5 then
		return nil
	end
	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	local f = (h / 2) / math.tan(CAM.fov / 2)
	return w / 2 + f * xc / zc, h / 2 + f * yc / zc, zc
end

-- Marker error for one measurement m = { x, y, mx, my, px, py, pz, zoom } given camera parameters.
local function MarkerError(m, heading, pitch, zoff)
	local feet = m.pz + zoff
	local sx, sy = Project(m.x, m.y, feet + CAM.markerDz, heading, pitch, m.px, m.py, feet, m.zoom)
	if not sx then
		return nil
	end
	return sx + CAM.markerOx - m.mx, sy + CAM.markerOy - m.my
end

-- Small dense least squares: solves (J^T J) d = J^T r for up to 3 unknowns by Gaussian elimination.
local function SolveNormal(J, r, n)
	local A, b = {}, {}
	for i = 1, n do
		A[i] = {}
		b[i] = 0
		for j = 1, n do
			local sum = 0
			for k = 1, #r do
				sum = sum + J[k][i] * J[k][j]
			end
			A[i][j] = sum + (i == j and 1e-6 or 0)
		end
		for k = 1, #r do
			b[i] = b[i] + J[k][i] * r[k]
		end
	end
	for c = 1, n do
		local pivot = A[c][c]
		if math.abs(pivot) < 1e-12 then
			return nil
		end
		for rr = c + 1, n do
			local f = A[rr][c] / pivot
			for cc = c, n do
				A[rr][cc] = A[rr][cc] - f * A[c][cc]
			end
			b[rr] = b[rr] - f * b[c]
		end
	end
	local x = {}
	for i = n, 1, -1 do
		local sum = b[i]
		for j = i + 1, n do
			sum = sum - A[i][j] * x[j]
		end
		x[i] = sum / A[i][i]
	end
	return x
end

-- Gauss-Newton over the given measurements. Unknowns: heading, pitch and (optionally) zoff.
local function Fit(measurements, heading, pitch, zoff, withHeight)
	local n = withHeight and 3 or 2
	local params = { heading, pitch, zoff }
	for _ = 1, 6 do
		local J, r = {}, {}
		for _, m in ipairs(measurements) do
			local ex, ey = MarkerError(m, params[1], params[2], params[3])
			if not ex then
				return nil
			end
			local rowX, rowY = {}, {}
			for k = 1, n do
				local eps = k == 3 and 0.01 or 1e-3
				local q = { params[1], params[2], params[3] }
				q[k] = q[k] + eps
				local ax, ay = MarkerError(m, q[1], q[2], q[3])
				if not ax then
					return nil
				end
				rowX[k], rowY[k] = (ax - ex) / eps, (ay - ey) / eps
			end
			J[#J + 1], r[#r + 1] = rowX, ex
			J[#J + 1], r[#r + 1] = rowY, ey
		end
		local d = SolveNormal(J, r, n)
		if not d then
			return nil
		end
		params[1] = params[1] - max(-0.5, min(0.5, d[1]))
		params[2] = max(-1.3, min(1.45, params[2] - max(-0.3, min(0.3, d[2]))))
		if withHeight then
			params[3] = max(-6, min(6, params[3] - max(-1, min(1, d[3]))))
		end
		if math.abs(d[1]) < 1e-5 and math.abs(d[2]) < 1e-5 then
			break
		end
	end
	local worst = 0
	for _, m in ipairs(measurements) do
		local ex, ey = MarkerError(m, params[1], params[2], params[3])
		if not ex then
			return nil
		end
		worst = max(worst, sqrt(ex * ex + ey * ey))
	end
	return params[1], params[2], params[3], worst
end

local function SmoothAngle(current, target, k)
	if not current then
		return target
	end
	local diff = (target - current + math.pi) % (2 * math.pi) - math.pi
	return current + diff * k
end

-- Uses last frame's probe reading to update the camera, then places this frame's probe.
-- Debug ground truth: every third frame the probe goes on a route point instead, and its marker
-- position (the client's own projection, at the player's height) is kept as a white dot.
local TRUTH_EVERY = 3
local TRUTH_STEPS = { 2, 4, 6, 9, 12, 15 }   -- route points past the trail start
s.truth = {}

local HISTORY = 2   -- frames of player position kept for pairing with marker readings
s.history = {}

-- Height test (/sft probe height): does the client draw a user waypoint at the height it is given?
-- Places the marker at one ground spot 16 yards ahead at three heights in turn and averages where
-- each shows on screen. Takes over the probe for about 1.5 seconds.
local HEIGHT_TEST_OFFSETS = { 0, 10, 20 }

function Trail.StartHeightTest()
	s.heightTest = { frame = 0, sums = {}, counts = {} }
end

local function HeightTestStep(px, py, pz, facing)
	local t = s.heightTest
	if t.pending then
		local mx, my = ReadProjection()
		if mx then
			local k = t.pending
			t.sums[k] = (t.sums[k] or 0) + my
			t.counts[k] = (t.counts[k] or 0) + 1
		end
	end
	t.frame = t.frame + 1
	if t.frame > 150 then
		local parts = {}
		for k, off in ipairs(HEIGHT_TEST_OFFSETS) do
			local n = t.counts[k] or 0
			parts[#parts + 1] = string.format("+%d yd: %s", off, n > 0 and string.format("y %.1f (%d readings)", t.sums[k] / n, n) or "no reading")
		end
		local y0 = t.counts[1] and t.sums[1] / t.counts[1]
		local y2 = t.counts[3] and t.sums[3] / t.counts[3]
		local verdict = (y0 and y2) and (math.abs(y2 - y0) > 20 and "HEIGHT IS USED" or "height is ignored") or "inconclusive"
		local msg = "height test: " .. table.concat(parts, ", ") .. " -> " .. verdict
		print("|cff7fd4ffStarfall Trail|r " .. msg)
		StarfallTrailDB.heightTest = msg
		s.heightTest = nil
		s.probe = nil
		return
	end
	-- Hold the spot fixed: 16 yards along the facing when the test started.
	t.x = t.x or px + math.sin(facing) * 16
	t.y = t.y or py + math.cos(facing) * 16
	t.z = t.z or pz
	local k = t.frame % #HEIGHT_TEST_OFFSETS + 1
	t.pending = SetWaypoint(t.x, t.y, t.z + HEIGHT_TEST_OFFSETS[k]) and k or nil
end

local function UpdateCamera(px, py, pz, zoom, facing, dt)
	if s.heightTest then
		HeightTestStep(px, py, pz, facing)
		return
	end
	local history = s.history
	history[#history + 1] = { px, py, pz, zoom }
	if #history > HISTORY then
		table.remove(history, 1)
	end
	if s.probe and s.probe.truth then
		local mx, my = ReadProjection()
		s.truth[s.probe.truth] = mx and { mx - CAM.markerOx, my - CAM.markerOy, mx, my } or nil
	elseif s.probe then
		local mx, my = ReadProjection()
		local solved = false
		if mx then
			-- The marker on screen was drawn with last frame's player position (measured from a
			-- logged walk: pairing it with that frame gives the steadiest camera).
			local h = s.history[max(1, #s.history - 1)]
			local m = { x = s.probe.x, y = s.probe.y, mx = mx, my = my, px = h[1], py = h[2], pz = h[3], zoom = h[4] }
			local guessHeading = s.probe.lost and s.probe.dir or cam.heading or facing
			local a, p, _, worst = Fit({ m }, guessHeading, cam.pitch, cam.zoff, false)
			if a and worst >= 40 then
				a = nil
			end
			if a then
				cam.heading, cam.pitch, cam.error = a, p, worst
				cam.valid = true
				cam.age = 0
				solved = true
			end
			s.lastMarkerX, s.lastMarkerY = mx, my
		end
		-- No usable reading (marker off screen or the fit failed): count it, so the probe starts
		-- searching after two frames instead of staying stuck.
		s.offscreen = not solved and OffscreenEdge() or nil
		if not solved then
			cam.age = (cam.age or 0) + 1
			if cam.age > 30 then
				cam.valid = false
			end
		end
		-- Per-frame solver log for offline analysis (/sft trail log).
		local log = Trail.solveLog
		if log and #log < 6000 then
			log[#log + 1] = string.format("%.4f;%.5f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.3f;%.5f;%.6f;%.6f;%.6f;%.6f;%d;%d",
				debugprofilestop and debugprofilestop() / 1000 or GetTime(), dt, s.probe.x, s.probe.y, mx or -1, my or -1,
				px, py, pz, zoom, facing, cam.heading or -9, cam.pitch or -9, cam.sHeading or -9, cam.sPitch or -9,
				solved and 1 or 0, IsMouselooking() and 1 or 0)
		end
	end
	if cam.valid then
		if not cam.sHeading or not cam.lastHeading then
			cam.sHeading, cam.sPitch = cam.heading, cam.pitch
			cam.lastHeading, cam.lastPitch, cam.vh, cam.vp = cam.heading, cam.pitch, 0, 0
		end
		-- Signed rates of change, averaged: frame-to-frame noise cancels out, real turning does not.
		local step = max(dt, 0.001)
		local rh = ((cam.heading - cam.lastHeading + math.pi) % (2 * math.pi) - math.pi) / step
		local rp = (cam.pitch - cam.lastPitch) / step
		cam.lastHeading, cam.lastPitch = cam.heading, cam.pitch
		local ks = 1 - exp(-2 * math.pi * SPEED_FILTER * dt)
		cam.vh = cam.vh + (rh - cam.vh) * ks
		cam.vp = cam.vp + (rp - cam.vp) * ks
		cam.speed = sqrt(cam.vh * cam.vh + cam.vp * cam.vp)
		local cutoff = STILL_CUTOFF + SPEED_CUTOFF * cam.speed
		local k = 1 - exp(-2 * math.pi * cutoff * dt)
		cam.sHeading = SmoothAngle(cam.sHeading, cam.heading, k)
		local dp = cam.pitch - cam.sPitch
		cam.sPitch = cam.sPitch + dp * k
	end
	s.frameCount = (s.frameCount or 0) + 1
	if Trail.debug and s.route and s.frameCount % TRUTH_EVERY == 0 then
		s.truthSlot = (s.truthSlot or 0) % #TRUTH_STEPS + 1
		local n = min(#s.route.points, s.progress + 2 + TRUTH_STEPS[s.truthSlot])
		local p = s.route.points[n]
		s.probe = SetWaypoint(p[1], p[2]) and { x = p[1], y = p[2], truth = s.truthSlot } or nil
		return
	end
	-- Probe a spot ahead along the camera's heading; the client draws it at the player's height.
	local heading = cam.heading or facing
	if s.offscreen == "top" then
		s.nearProbe = true
	elseif s.nearProbe and cam.valid and FarProbeVisible(cam.pitch, zoom, PROBE_RETURN) then
		s.nearProbe = false
	end
	-- Off the bottom while the camera was tilting up (looking at the sky), the pitch is out of range,
	-- not the heading: wait, however long, until the camera comes back down. A marker behind the
	-- camera after a snap also lands on the bottom edge, so this only counts when the last pitch was
	-- upward. Off the top the close probe takes over; if even that fails for 1.5 seconds, search.
	local age = cam.age or 0
	local lookingUp = s.offscreen == "bottom" and (cam.pitch or 0) < -0.2
	local lookingDown = s.offscreen == "top" and age < 90
	local lost = age >= 2 and not (lookingUp or lookingDown)

	local hidden = HiddenDistance()
	local reach = MaxVisibleDistance(cam.pitch or 0.35, zoom)
	if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
		s.dragUntil = s.time + DRAG_HOLD
	end
	local d
	if lost then
		d = (hidden and hidden < reach) and hidden or PROBE_FAR
	elseif hidden and hidden < reach and not s.nearProbe then
		d = min(reach, hidden + 5)                             -- 1. hidden from the minimap
		s.probeMode = "hidden"
	elseif not cam.valid or s.time < (s.dragUntil or 0) or lookingUp then
		d = s.nearProbe and PROBE_CLOSE or PROBE_FAR           -- 2. visible, while the camera moves
		s.probeMode = "visible"
	end
	s.probeDistance = d
	if not d then
		-- 3. Estimate: the camera follows the character. Keep the last measured offset between camera
		-- and facing; mouselook locks the camera to the facing, and walking swings it behind.
		if s.probeMode ~= "estimate" then
			s.probeMode = "estimate"
			s.headingOffset = cam.heading and ((cam.heading - facing + math.pi) % (2 * math.pi) - math.pi) or 0
			ReleaseWaypoint()
		end
		if IsMouselooking() then
			s.headingOffset = 0
		elseif s.moving then
			s.headingOffset = s.headingOffset * math.exp(-dt * 1.5)
		end
		cam.heading = facing + s.headingOffset
		cam.age = 0
		cam.valid = cam.pitch ~= nil
		return
	end
	if lost then
		-- Lost track (hitch, camera snap): look along the character's facing first, then sweep around
		-- the player until the marker shows up on screen again.
		heading = facing + RECOVERY_SWEEP[(cam.age - 2) % #RECOVERY_SWEEP + 1]
	end
	local x, y = px + math.sin(heading) * d, py + math.cos(heading) * d
	s.probe = SetWaypoint(x, y) and { x = x, y = y, dir = heading, lost = lost } or nil
end

---------------------------------------------------------------------------
-- Route following
---------------------------------------------------------------------------

-- Nearest route index to the player, searched around the last known progress.
local function UpdateProgress(points, px, py)
	local best, bestDist = s.progress, math.huge
	local from = max(1, s.progress - 8)
	local to = min(#points, s.progress + 60)
	for n = from, to do
		local d = Distance(px, py, points[n][1], points[n][2])
		if d < bestDist then
			best, bestDist = n, d
		end
	end
	if best < s.progress - 1 or best > s.progress then
		s.progress = best
	end
	return bestDist
end

-- Route position of the player as a fractional index: the nearest point on the segments around
-- the current progress.
function ExactProgress(points, px, py)
	local n = s.progress
	local best, bestDist = n, math.huge
	for k = max(1, n - 1), min(#points - 1, n) do
		local ax, ay = points[k][1], points[k][2]
		local ex, ey = points[k + 1][1] - ax, points[k + 1][2] - ay
		local len2 = ex * ex + ey * ey
		local t = len2 > 0 and max(0, min(1, ((px - ax) * ex + (py - ay) * ey) / len2)) or 0
		local dx, dy = ax + ex * t - px, ay + ey * t - py
		local d = dx * dx + dy * dy
		if d < bestDist then
			best, bestDist = k + t, d
		end
	end
	return best
end

-- Route point about LOOKAHEAD_YARDS ahead, for the arrow. Nil without a route.
function Trail.Lookahead()
	local route = s.route
	if not route then
		return nil
	end
	local n = min(#route.points, s.progress + floor(LOOKAHEAD_YARDS / SPACING))
	local p = route.points[n]
	return p[1], p[2]
end

-- Screen spot and world distance at a fractional route index, projected at true ground height
-- with this frame's solved camera.
local function ScreenAt(points, at, px, py)
	if not cam.valid or not s.route then
		return nil
	end
	local count = #points
	local n = floor(at)
	if n < 1 or n >= count then
		return nil
	end
	local t = at - n
	local p, q = points[n], points[n + 1]
	local heights = s.route.heights
	local x = p[1] + (q[1] - p[1]) * t
	local y = p[2] + (q[2] - p[2]) * t
	local z = heights[n] + (heights[n + 1] - heights[n]) * t
	local sx, sy = Project(x, y, z, cam.sHeading, cam.sPitch, px, py, s.trailPz or s.pz, s.zoom)
	if not sx then
		return nil
	end
	return sx, sy, Distance(px, py, x, y)
end

---------------------------------------------------------------------------
-- Sparkles
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Debug view: the projected route as a line plus the probe marker prediction, redrawn every frame.
---------------------------------------------------------------------------

Trail.debug = false
local DEBUG_SEGMENTS = 120
local debugLines, debugDots = {}, {}
for i = 1, DEBUG_SEGMENTS do
	local line = frame:CreateLine(nil, "OVERLAY")
	line:SetColorTexture(1, 0.8, 0.25, 0.9)
	line:SetThickness(3)
	line:Hide()
	debugLines[i] = line
end
for i = 1, 24 do
	local dot = frame:CreateTexture(nil, "OVERLAY", nil, 2)
	dot:SetTexture(MEDIA .. "mote.png")
	dot:SetBlendMode("ADD")
	dot:SetSize(18, 18)
	dot:Hide()
	debugDots[i] = dot
end

local function HideDebug()
	for _, line in ipairs(debugLines) do
		line:Hide()
	end
	for _, dot in ipairs(debugDots) do
		dot:Hide()
	end
end

local function DrawDebug(points, first, last, px, py, justMeasured)
	-- The curve, sampled every half route point.
	local used = 0
	local prevX, prevY
	local at = first
	while at <= last and used < DEBUG_SEGMENTS do
		local x, y = ScreenAt(points, at, px, py)
		if x and prevX then
			used = used + 1
			local line = debugLines[used]
			line:SetStartPoint("BOTTOMLEFT", UIParent, prevX, prevY)
			line:SetEndPoint("BOTTOMLEFT", UIParent, x, y)
			line:Show()
		end
		prevX, prevY = x, y
		at = at + 0.5
	end
	for i = used + 1, DEBUG_SEGMENTS do
		debugLines[i]:Hide()
	end
	-- The probe: where the model expects the client's marker (cyan), for checking the camera fit.
	local dot = debugDots[1]
	local probe = s.probe
	local ex, ey
	if probe and cam.valid then
		-- Called on its own line: "a and f()" would keep only f's first return value.
		ex, ey = Project(probe.x, probe.y, s.pz + cam.zoff + CAM.markerDz, cam.heading, cam.pitch, px, py, s.pz + cam.zoff, s.zoom)
	end
	if ex then
		dot:ClearAllPoints()
		dot:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ex + CAM.markerOx, ey + CAM.markerOy)
		dot:SetVertexColor(0.3, 0.9, 1)
		dot:Show()
	else
		dot:Hide()
	end
	-- White: where the client itself puts route points (at the player's height).
	for i = 2, #debugDots do
		debugDots[i]:Hide()
	end
	for i = 2, 7 do
		local t = s.truth[i - 1]
		if t then
			debugDots[i]:ClearAllPoints()
			debugDots[i]:SetPoint("CENTER", UIParent, "BOTTOMLEFT", t[1], t[2])
			debugDots[i]:SetVertexColor(1, 1, 1)
			debugDots[i]:Show()
		else
			debugDots[i]:Hide()
		end
		-- Magenta: the raw marker frame centre, before the fitted screen offset.
		local raw = debugDots[i + 8]
		if t then
			raw:ClearAllPoints()
			raw:SetPoint("CENTER", UIParent, "BOTTOMLEFT", t[3], t[4])
			raw:SetVertexColor(1, 0.2, 1)
			raw:Show()
		end
	end
	-- Green: the model's projection of the player's own feet.
	local feet = debugDots[20]
	local fx, fy = Project(px, py, s.pz, cam.sHeading or 0, cam.sPitch, px, py, s.pz, s.zoom)
	if fx and cam.valid then
		feet:ClearAllPoints()
		feet:SetPoint("CENTER", UIParent, "BOTTOMLEFT", fx, fy)
		feet:SetVertexColor(0.2, 1, 0.2)
		feet:Show()
	end
end

local function SparksOff()
	for _, spark in ipairs(sparks) do
		spark.state = "off"
		spark.tex:SetAlpha(0)
	end
end

local function Hide()
	SparksOff()
	s.revealGoalX = nil
	HideDebug()
	ReleaseWaypoint()
end

-- Screen spot, depth and distance from the player of a sparkle at route position `at`, `lat`
-- yards to the side of the route and `lift` yards above the ground.
local function SparkSpot(points, at, lat, lift, px, py)
	if not cam.valid or not s.route then
		return nil
	end
	local n = floor(at)
	if n < 1 or n >= #points then
		return nil
	end
	local t = at - n
	local p, q = points[n], points[n + 1]
	local ex, ey = q[1] - p[1], q[2] - p[2]
	local len = sqrt(ex * ex + ey * ey)
	if len < 1e-6 then
		return nil
	end
	local heights = s.route.heights
	local x = p[1] + ex * t - ey / len * lat
	local y = p[2] + ey * t + ex / len * lat
	local z = heights[n] + (heights[n + 1] - heights[n]) * t + lift
	local sx, sy, depth = Project(x, y, z, cam.sHeading, cam.sPitch, px, py, s.trailPz or s.pz, s.zoom)
	if not sx then
		return nil
	end
	return sx, sy, depth, Distance(px, py, x, y)
end

-- Brightness over a sparkle's life (smooth bloom, hold, smooth dissolve), and bloom progress.
local function Envelope(spark)
	local age, life = spark.age, spark.life
	local rise = min(BLOOM_IN, life * 0.3)
	local fall = min(DISSOLVE_OUT, life * 0.45)
	local e = 1
	if age < rise then
		e = age / rise
	elseif age > life - fall then
		e = (life - age) / fall
	end
	e = max(0, min(1, e))
	return e * e * (3 - 2 * e), age < rise and e or 1
end

local function FreeSpark()
	local faintest
	for _, spark in ipairs(sparks) do
		if spark.state == "off" then
			return spark
		end
		if spark.state == "ghost" and (not faintest or spark.swap < faintest.swap) then
			faintest = spark
		end
	end
	return faintest
end

-- Best of a few random route spots: the one farthest from the sparkles already shown.
local function PickSpot(first, spawnLast)
	local bestAt, bestLat, bestScore = nil, nil, -1
	for _ = 1, CANDIDATES do
		local at = first + math.random() * (spawnLast - first)
		local g = (math.random() + math.random() + math.random() - 1.5) * 2   -- about N(0, 1)
		local lat = max(-SPREAD_MAX, min(SPREAD_MAX, g * SPREAD_YARDS))
		local score = math.huge
		for _, other in ipairs(sparks) do
			if other.state == "live" then
				local da = (other.at - at) * SPACING
				local dl = other.lat - lat
				local d2 = da * da + dl * dl
				if d2 < score then
					score = d2
				end
			end
		end
		if score > bestScore then
			bestAt, bestLat, bestScore = at, lat, score
		end
	end
	return bestAt, bestLat
end

-- Height of a sparkle above the route right now: its base lift, a slow bob at its own rhythm, a
-- little sideways waft, and a soft rise toward the end of its life, like an ember drifting up.
-- Every sparkle moves differently, so the trail breathes instead of moving as one block.
local function SparkFloat(spark)
	local age = spark.age or 0
	local life = spark.life or 1
	local k = min(1, age / life)
	local bob = spark.floatAmp * math.sin(spark.floatPhase + spark.floatFreq * age)
	local waft = spark.waftAmp * math.sin(spark.waftPhase + spark.floatFreq * 0.63 * age)
	return spark.lift + bob + spark.rise * k * k, spark.lat + waft
end

local function NewFloat(spark)
	spark.floatAmp = FLOAT_AMP_MIN + math.random() * (FLOAT_AMP_MAX - FLOAT_AMP_MIN)
	spark.floatFreq = 6.283 * (FLOAT_HZ_MIN + math.random() * (FLOAT_HZ_MAX - FLOAT_HZ_MIN))
	spark.floatPhase = math.random() * 6.283
	spark.waftAmp = WAFT_MAX * math.random()
	spark.waftPhase = math.random() * 6.283
	spark.rise = RISE_MIN + math.random() * (RISE_MAX - RISE_MIN)
end

local function CopyFloat(spark, like)
	spark.floatAmp, spark.floatFreq, spark.floatPhase = like.floatAmp, like.floatFreq, like.floatPhase
	spark.waftAmp, spark.waftPhase, spark.rise = like.waftAmp, like.waftPhase, like.rise
end

-- Shows a sparkle. With `like`, it continues that sparkle (same spot on the route, look and age)
-- at its corrected screen position, fading in while the old one fades out.
local function SpawnSpark(points, first, spawnLast, px, py, like)
	local spark = FreeSpark()
	if not spark or spark == like then
		return false
	end
	local at, lat, lift
	if like then
		at, lat, lift = like.at, like.lat, like.lift
		CopyFloat(spark, like)
		spark.age, spark.life = like.age, like.life
	else
		at, lat = PickSpot(first, spawnLast)
		lift = LIFT_MIN + math.random() * (LIFT_MAX - LIFT_MIN)
		NewFloat(spark)
		spark.age, spark.life = 0, 1
	end
	spark.lat, spark.lift = lat, lift
	local floatLift, floatLat = SparkFloat(spark)
	local x, y, depth, d = SparkSpot(points, at, floatLat, floatLift, px, py)
	if not x then
		return false
	end
	spark.state = "live"
	spark.at, spark.lat, spark.lift = at, lat, lift
	spark.x, spark.y = x, y
	spark.born = s.sparkFrame
	if like then
		spark.sizeK, spark.peak, spark.phase, spark.twinkle = like.sizeK, like.peak, like.phase, like.twinkle
		spark.life, spark.age, spark.rot = like.life, like.age, like.rot
		spark.r, spark.g, spark.b = like.r, like.g, like.b
		spark.swap = like.swap
		spark.lastSwap = s.time
	else
		spark.sizeK = 0.45 + math.random() * 0.55
		spark.peak = 0.4 + math.random() * 0.45
		spark.phase = math.random() * 6.283
		spark.twinkle = 1.2 + math.random() * 1.4
		spark.life = LIFE_MIN + math.random() * (LIFE_MAX - LIFE_MIN)
		spark.age = 0
		spark.rot = math.random() * 6.283
		local warm = math.random()
		spark.r, spark.g, spark.b = 1, 0.8 + 0.18 * warm, 0.42 + 0.45 * warm
		spark.swap = 1
		spark.lastSwap = -10
	end
	local fadeNear = min(1, max(0, (d - START_YARDS) / START_FADE_YARDS))
	local fadeFar = max(0, 1 - max(0, (d - (AHEAD_YARDS - 15)) / 15))
	spark.fade = fadeNear * fadeFar
	spark.size = max(3, SIZE_SCALE * spark.sizeK / depth)
	spark.shownSize = nil
	local tex = spark.tex
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	if spark.star then
		tex:SetRotation(spark.rot)
	end
	tex:SetVertexColor(spark.r, spark.g, spark.b)
	return true
end

-- Fades a sparkle out in place over `duration` seconds.
local function Ghost(spark, duration)
	if spark.swap < 0.02 then
		spark.state = "off"   -- too faint to see; frees the texture at once
		return
	end
	spark.state = "ghost"
	spark.ghostRate = spark.swap / duration
end

-- Fades out every sparkle shown (a new route replaces them all).
local function GhostAll()
	for _, spark in ipairs(sparks) do
		if spark.state == "live" then
			Ghost(spark, PASSED_FADE)
		end
	end
end

local function UpdateSparks(dt, points, first, last, px, py)
	s.sparkFrame = s.sparkFrame + 1
	local frameId = s.sparkFrame
	local spawnLast = min(last, first + s.reveal / SPACING)

	-- Keep each sparkle where it is until its spot has drifted on screen or it is behind you.
	local alive = 0
	for _, spark in ipairs(sparks) do
		if spark.state == "live" and spark.born ~= frameId then
			spark.age = spark.age + dt
			if spark.age >= spark.life then
				spark.state = "off"
			elseif spark.at < first or spark.at > last then
				Ghost(spark, PASSED_FADE)
			else
				local floatLift, floatLat = SparkFloat(spark)
				local x, y, depth, d = SparkSpot(points, spark.at, floatLat, floatLift, px, py)
				if not x then
					Ghost(spark, PASSED_FADE)
				else
					-- Glued to its spot on the ground: redrawn there every frame, so walking and turning
					-- move it exactly like the terrain under it. A still camera is already held steady
					-- by the camera smoothing, so nothing here needs a dead zone.
					local dx, dy = x - spark.x, y - spark.y
					if dx * dx + dy * dy > 0.01 then
						spark.x, spark.y = x, y
						spark.tex:ClearAllPoints()
						spark.tex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
					end
					spark.size = max(3, SIZE_SCALE * spark.sizeK / depth)
					local fadeNear = min(1, max(0, (d - START_YARDS) / START_FADE_YARDS))
					local fadeFar = max(0, 1 - max(0, (d - (AHEAD_YARDS - 15)) / 15))
					-- Feathered ends along the route itself: the growing front edge (and the edge being
					-- revealed by a new path) always tweens in, even where the path curves back close.
					local front = min(1, (spawnLast - spark.at) * SPACING / EDGE_YARDS)
					local back = min(1, (spark.at - first) * SPACING / START_FADE_YARDS)
					front = front * front * (3 - 2 * front)
					spark.fade = fadeNear * fadeFar * max(0, front) * max(0, back)
					alive = alive + 1
				end
			end
		end
	end

	-- Top up to an even density over the revealed part of the trail.
	local wanted = floor(SPARKS_PER_YARD * (spawnLast - first) * SPACING + 0.5)
	local added = 0
	while alive < wanted and added < FILL_PER_FRAME and spawnLast - first >= 1 do
		if not SpawnSpark(points, first, spawnLast, px, py) then
			break
		end
		alive, added = alive + 1, added + 1
	end

	-- Brightness: life envelope x crossfade x a slow glimmer. Positions never change.
	local time = s.time
	for _, spark in ipairs(sparks) do
		local state = spark.state
		if state == "ghost" then
			spark.age = spark.age + dt
			spark.swap = spark.swap - dt * spark.ghostRate
			if spark.swap <= 0 or spark.age >= spark.life then
				spark.state = "off"
				state = "off"
			end
		elseif state == "live" then
			spark.swap = min(1, spark.swap + dt / SWAP_TIME)
		end
		if state == "off" then
			spark.tex:SetAlpha(0)
		else
			local envelope, bloom = Envelope(spark)
			local glimmer = 0.82 + 0.18 * sin(spark.phase + time * spark.twinkle)
			spark.tex:SetAlpha(spark.peak * envelope * spark.swap * glimmer * spark.fade)
			-- Blossom from 70% to full size while blooming in.
			local size = spark.size * (0.7 + 0.3 * bloom)
			if not spark.shownSize or math.abs(size - spark.shownSize) > 0.05 then
				spark.shownSize = size
				spark.tex:SetSize(size, size)
			end
		end
	end
end

-- Counts for /sft trail status.
local function SparkStats()
	local live, ghost = 0, 0
	for _, spark in ipairs(sparks) do
		if spark.state == "live" then
			live = live + 1
		elseif spark.state == "ghost" then
			ghost = ghost + 1
		end
	end
	return live, ghost
end

---------------------------------------------------------------------------
-- Per frame
---------------------------------------------------------------------------

-- The client reports the player's position rounded to 0.1 yards (logged walk: every step is
-- 0.100 or 0.141 yards, or zero), while the character and camera move smoothly. Drawing with the
-- rounded position made the sparkles shake. An alpha-beta (position + velocity) filter recovers the
-- smooth path; its gains follow from one time constant, so it behaves the same at any frame rate.
local POSITION_TIME = 0.09   -- seconds; tuned on the logged walk (position jerk down 10x)
local TRAIL_HEIGHT_TIME = 0.22   -- seconds; any leftover height change glides instead of snapping

function SmoothPosition(x, y, dt)
	if not s.fx or (x - s.fx) ^ 2 + (y - s.fy) ^ 2 > 1 then
		-- First frame, or a jump (teleport, mount, loading screen): start over.
		s.fx, s.fy, s.vx, s.vy = x, y, 0, 0
		s.surfaceRef = nil
		s.trailPz = nil
		return x, y
	end
	dt = max(dt, 0.001)
	local alpha = 1 - exp(-dt / POSITION_TIME)
	local beta = alpha * alpha / (2 - alpha)
	local fx, fy = s.fx + s.vx * dt, s.fy + s.vy * dt
	local rx, ry = x - fx, y - fy
	s.fx, s.fy = fx + alpha * rx, fy + alpha * ry
	s.vx, s.vy = s.vx + beta / dt * rx, s.vy + beta / dt * ry
	s.moving = s.vx * s.vx + s.vy * s.vy > 1
	return s.fx, s.fy
end

function Trail.Update(dt, target, enabled)
	local Nav = ns.Nav
	s.time = s.time + dt
	Nav.Step()
	if rec then
		RecordStep()
		return
	end
	local HBD = ns.HBD
	if not (enabled and target and target.x and HBD and C_Navigation and UiMapPoint) then
		s.route = nil
		s.routeKey = nil
		Nav.Clear()
		Hide()
		return
	end
	local rawX, rawY, instance = HBD:GetPlayerWorldPosition()
	if not rawX or instance ~= target.instance or not Nav.GridFor(rawX, rawY, instance) then
		s.route = nil
		s.routeKey = nil
		s.fx = nil
		s.surfaceRef = nil
		Hide()
		return
	end
	local px, py = SmoothPosition(rawX, rawY, dt)

	-- Camera: read last frame's probe, solve, place the next probe.
	-- Follow the surface you are on (a bridge deck, not the ravine under it).
	s.pz = Nav.HeightAtWorld(px, py, instance, s.surfaceRef) or 0
	s.surfaceRef = s.pz
	s.zoom = GetCameraZoom and GetCameraZoom() or 15
	UpdateCamera(px, py, s.pz, s.zoom, GetPlayerFacing() or 0, dt)
	s.cameraTime = s.time

	-- Route management.
	-- Switching to or from a followed person drops the old route and any search still running for
	-- it at once. Otherwise, when no route to the new target can be found, the old one would stay
	-- on the ground and keep steering the arrow.
	if s.targetKey ~= target.key then
		if target.friend or s.targetFriend then
			s.route = nil
			s.routeKey = nil
			Nav.Clear()
			GhostAll()
		end
		s.targetKey, s.targetFriend = target.key, target.friend
	end
	-- A followed person keeps moving: re-plans to them must not replay the sweep-out every time.
	-- True only when the route now shown was already planned for this same person.
	local sameFriend = target.friend and s.routeKey == target.key
	if Nav.route and Nav.route ~= s.route then
		s.route = Nav.route
		s.routeKey = target.key
		s.progress = 1
		-- Ground height of every route point, for projecting the trail onto the terrain.
		local heights = {}
		-- The router supplies them (from the cells it walked, so bridge decks stay decks).
		if not s.route.heights then
			for n, p in ipairs(s.route.points) do
				heights[n] = Nav.HeightAtWorld(p[1], p[2], instance) or s.pz
			end
			s.route.heights = heights
		end
		GhostAll()
		if not sameFriend then
			s.reveal = 0   -- a re-route sweeps out from you too, so the new path builds instead of popping in
		end
	end
	s.requestTimer = s.requestTimer - dt
	local route = s.route
	-- goalSlack: how far a moving target may drift from the route's end before a new search.
	local needRoute = not route or Distance(route.goalX, route.goalY, target.x, target.y) > (target.goalSlack or 3)
	if route and not needRoute then
		needRoute = UpdateProgress(route.points, px, py) > OFF_ROUTE_YARDS
	end
	if needRoute and not Nav.Busy() and s.requestTimer <= 0 then
		s.requestTimer = REQUEST_COOLDOWN
		Nav.Request(px, py, target.x, target.y, instance, s.trailPz or s.pz)
	end
	if not route then
		s.trailPz = nil
		Hide()
		return
	end
	-- A new target sweeps the trail out from you; re-routes to the same target do not.
	if not s.revealGoalX or Distance(route.goalX, route.goalY, s.revealGoalX, s.revealGoalY) > 3 then
		s.revealGoalX, s.revealGoalY = route.goalX, route.goalY
		if not sameFriend then
			s.reveal = 0
		end
	end
	-- Eased: the path builds out quickly near you and slows gently as it reaches its far end.
	local full = AHEAD_YARDS + SPACING
	s.reveal = min(full, s.reveal + REVEAL_SPEED * dt * (0.2 + 1.3 * (1 - s.reveal / full)))
	if s.quiet then
		-- In the quest area: nothing new spawns, and on leaving the trail sweeps out from you again.
		s.reveal = 0
	end

	local points = route.points
	local count = #points
	-- Start a few yards ahead of you so sparkles never sit on your character.
	-- Fractional route positions, so the trail's ends glide with you instead of stepping a whole
	-- route point (2.5 yards) at a time; new sparkles then trickle in one by one at the front.
	local progress = ExactProgress(points, px, py)
	local first = min(count - 1, progress + START_YARDS / SPACING)

	-- Your height for drawing the trail: read from the trail's own heights at your exact spot on
	-- it, so you and the trail always stand on the same ground and map errors cancel instead of
	-- lifting or sinking the whole trail. Well off the path, blend to the terrain under you.
	local n = min(count - 1, max(1, floor(progress)))
	local t = progress - n
	local heights = route.heights
	local onTrail = heights[n] + (heights[n + 1] - heights[n]) * t
	local p, q = points[n], points[n + 1]
	local away = Distance(px, py, p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t)
	local w = min(1, max(0, (away - 3) / 5))
	local height = onTrail
	if w > 0 then
		-- Off the path: the terrain under you, on the surface the trail is on.
		local ground = Nav.HeightAtWorld(px, py, instance, onTrail) or onTrail
		height = onTrail * (1 - w) + ground * w
	end
	if not s.trailPz or math.abs(height - s.trailPz) > 8 then
		s.trailPz = height
	else
		s.trailPz = s.trailPz + (height - s.trailPz) * (1 - exp(-dt / TRAIL_HEIGHT_TIME))
	end
	local last = min(count - 0.001, first + AHEAD_YARDS / SPACING)

	-- Sparkles, or the debug line.
	if Trail.debug then
		SparksOff()
		DrawDebug(points, first, last, px, py, s.lastMeasured)
	else
		HideDebug()
		UpdateSparks(dt, points, first, last, px, py)
	end
end

---------------------------------------------------------------------------
-- Camera recorder: measures random ground spots around the player and logs everything needed
-- to fit the camera model offline (StarfallTrailDB.cameraLog, written to disk on /reload).
---------------------------------------------------------------------------

local REC_LIMIT = 6000
rec = nil               -- declared near the top so Trail.Update sees the same variable

function Trail.ToggleRecording()
	if rec then
		ReleaseWaypoint()
		local n = #rec.log
		rec = nil
		return false, n
	end
	StarfallTrailDB.cameraLog = {}
	rec = { log = StarfallTrailDB.cameraLog }
	Hide()
	return true, 0
end

function Trail.Recording()
	return rec ~= nil
end

function RecordStep()
	local HBD = ns.HBD
	local px, py, instance = HBD:GetPlayerWorldPosition()
	if not px then
		return
	end
	-- 1) Log where last frame's spot landed, with the camera inputs of this moment.
	if rec.pending then
		local x, y = ReadProjection()
		if x and #rec.log < REC_LIMIT then
			local p = rec.pending
			local pz = ns.Nav.HeightAtWorld(px, py, instance)
			rec.log[#rec.log + 1] = string.format("%.3f;%.2f;%.2f;%.2f;%.2f;%.2f;%.2f;%.2f;%.2f;%.4f;%.3f;%d;%d;%d",
				GetTime(), p[1], p[2], p[3], x, y, px, py, pz or -9999, GetPlayerFacing() or -1,
				GetCameraZoom and GetCameraZoom() or -1,
				IsMouselooking() and 1 or 0, IsMouseButtonDown("LeftButton") and 1 or 0, IsMouseButtonDown("RightButton") and 1 or 0)
		end
	end
	-- 2) Pick a new random ground spot around the player and set the waypoint there.
	local angle = math.random() * 6.2832
	local dist = 6 + math.random() * 39
	local x, y = px + math.sin(angle) * dist, py + math.cos(angle) * dist
	local z = ns.Nav.HeightAtWorld(x, y, instance)
	if z and SetWaypoint(x, y) then
		rec.pending = { x, y, z }
	else
		rec.pending = nil
	end
end

-- Starts or stops the per-frame solver log (StarfallTrailDB.solveLog, written on /reload).
function Trail.ToggleSolveLog()
	if Trail.solveLog then
		local n = #Trail.solveLog
		Trail.solveLog = nil
		return false, n
	end
	StarfallTrailDB.solveLog = {}
	Trail.solveLog = StarfallTrailDB.solveLog
	return true, 0
end

-- For offline tests: grid height under the player and the height the trail is drawn from.
function Trail.Heights()
	return s.pz, s.trailPz
end

-- For offline tests.
function Trail.Camera()
	return cam
end

-- Quiet: the sparkles fade out (routing and the camera solve keep running) while you are in the
-- quest area, and the trail builds back out from you when you leave it.
function Trail.SetQuiet(quiet)
	quiet = quiet and true or false
	if quiet and not s.quiet then
		for _, spark in ipairs(sparks) do
			if spark.state == "live" then
				Ghost(spark, QUIET_FADE)
			end
		end
	end
	s.quiet = quiet
end

-- The camera's current heading (same convention as GetPlayerFacing), or nil when it is not being
-- solved right now (trail off, no map data here). Left-drag turns the camera but not the character,
-- so the arrow aims relative to this when it can.
function Trail.CameraHeading()
	if cam.valid and cam.sHeading and s.cameraTime and s.time - s.cameraTime < 0.25 then
		return cam.sHeading
	end
	return nil
end

function Trail.Status()
	local Nav = ns.Nav
	local route = s.route
	return string.format("route: %s, points %d, progress %d, busy %s, last expansions %s, camera %s (heading %.2f, pitch %.2f, height offset %.2f raw %.2f, err %.1f), last error %s",
		tostring(route ~= nil), route and #route.points or 0, s.progress, tostring(Nav.Busy()),
		tostring(Nav.lastExpansions), tostring(cam.valid), cam.heading or -1, cam.pitch or -1, cam.zoff or 0, cam.rawZoff or -1, cam.error or -1, tostring(Nav.lastError))
		.. (function()
			local px, py = ns.HBD:GetPlayerWorldPosition()
			local live, ghost = SparkStats()
			return string.format(" | player %.1f %.1f goal %.1f %.1f | sparkles %d (+%d fading) | probe %s %s",
				px or 0, py or 0, route and route.goalX or 0, route and route.goalY or 0, live, ghost, s.probeMode or "?", s.probeDistance and string.format("%.0f yd", s.probeDistance) or "off")
		end)()
end

function Trail.Show()
	frame:Show()
end

function Trail.Stop()
	s.route = nil
	ns.Nav.Clear()
	Hide()
end
