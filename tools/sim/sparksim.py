"""Runs Trail.lua for real (Lua 5.1 via lupa) against stubbed WoW APIs and a fake camera."""
import sys
sys.path.insert(0, sys.argv[1])
from lupa import lua51

L = lua51.LuaRuntime(unpack_returned_tuples=True)
src = r"C:\repos\starfall-trail\StarfallTrail"
L.execute(r'''
STUB_MT = {}
STUB_MT.__index = function(t, k)
	return function(self, ...) return nil end
end
function NewObject()
	local o = setmetatable({ alpha = 0, shown = false }, STUB_MT)
	ALL = ALL or {}
	ALL[#ALL + 1] = o
	o.CreateTexture = function(self) return NewObject() end
	o.CreateLine = function(self) return NewObject() end
	o.SetAlpha = function(self, a) self.alpha = a end
	o.SetPoint = function(self, _, _, _, x, y) self.x, self.y = x, y end
	o.SetSize = function(self, w) self.size = w end
	o.GetWidth = function() return 2048 end
	o.GetHeight = function() return 1152 end
	o.GetEffectiveScale = function() return 1 end
	return o
end
UIParent = NewObject()
Minimap = NewObject()
Minimap.GetWidth = function() return 140 end
RADIUS = 67
C_Minimap = { GetViewRadius = function() return RADIUS end }
MOUSE = false
function IsMouseButtonDown() return MOUSE end
function CreateFrame() return NewObject() end
-- Fake camera, same model as the addon.
TRUE = { heading = 1.0, pitch = 0.45, px = 2463.3, py = 10098.4, pz = 1317.78, zoom = 13 }
local fov, pivot, k, b = math.rad(52.98), 2.556, 0.8782, 1.889
function TrueProject(x, y, z)
	local T = TRUE
	local dx, dy = math.sin(T.heading), math.cos(T.heading)
	local cp, sp = math.cos(T.pitch), math.sin(T.pitch)
	local dist = k * T.zoom + b
	local cx, cy, cz = T.px - dist * cp * dx, T.py - dist * cp * dy, T.pz + pivot + dist * sp
	local vx, vy, vz = x - cx, y - cy, z - cz
	local along = vx * dx + vy * dy
	local xc = -vx * dy + vy * dx
	local yc = sp * along + cp * vz
	local zc = cp * along - sp * vz
	if zc < 0.5 then return 1024, 0, true end -- behind the camera: pinned to the bottom edge
	local f = 576 / math.tan(fov / 2)
	local sx, sy = 1024 + f * xc / zc, 576 + f * yc / zc
	if sx < 0 or sx > 2048 or sy < 0 or sy > 1152 then
		-- the client pins off-screen markers to the nearest screen edge
		return math.max(0, math.min(2048, sx)), math.max(0, math.min(1152, sy)), true
	end
	return sx, sy, false
end
local waypoint, shown
local navFrame = NewObject()
navFrame.GetCenter = function()
	if not shown then return nil end
	return shown[1], shown[2]
end
C_Navigation = {
	GetFrame = function() return navFrame end,
	HasValidScreenPosition = function() return shown ~= nil end,
	WasClampedToScreen = function() return CLAMPED and true or false end,
}
C_Map = {
	GetBestMapForUnit = function() return 1 end,
	CanSetUserWaypointOnMap = function() return true end,
	SetUserWaypoint = function(p) waypoint = p end,
	ClearUserWaypoint = function() waypoint = nil end,
	GetMapInfo = function() return nil end,
}
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { x = x, y = y } end }
-- The client renders last frame's waypoint at the player's height.
function RenderFrame()
	if waypoint then
		local x, y = waypoint.x * 100000, waypoint.y * 100000
		local sx, sy, clamped = TrueProject(x, y, TRUE.pz)
		CLAMPED = clamped
		shown = sx and { sx, sy } or nil
	else
		shown = nil
	end
end
HBD = {
	GetZoneCoordinatesFromWorld = function(self, x, y) return x / 100000, y / 100000 end,
	GetPlayerWorldPosition = function() if QUANT then return math.floor(TRUE.px * 10 + 0.5) / 10, math.floor(TRUE.py * 10 + 0.5) / 10, 1 end return TRUE.px, TRUE.py, 1 end,
}
function GetCameraZoom() return TRUE.zoom end
function GetPlayerFacing() return TRUE.heading end
function GetTime() return 0 end
function IsMouselooking() return false end
''')
ns = L.eval("{}")
for f in ("WayfinderMesh_Teldrassil.lua", "Nav.lua", "Trail.lua"):
	code = open(src + "\\" + f, encoding="utf-8").read()
	L.execute("local code, ns = ...; local fn = assert(loadstring(code)); fn('StarfallTrail', ns)", code, ns)
ns.HBD = L.eval("HBD")
Trail = ns.Trail
target = L.eval("{ x = 2534.3, y = 10085.6, instance = 1 }")
run = L.eval('''function(Trail, target, frames, dt, each)
	for i = 1, frames do
		if each then each(i) end
		RenderFrame()
		Trail.Update(dt, target, true)
	end
end''')
L.execute("function GLOW() local t = 0 for _, o in ipairs(ALL) do t = t + (o.alpha or 0) end return t end")
status = lambda: Trail.Status().split("|")[-1].strip() + "  total glow %.1f, camera %s" % (L.eval("GLOW()"), Trail.Camera().valid)
dt = 1 / 60
run(Trail, target, 120, dt, None)
print("after 2 s still:", status())
run(Trail, target, 180, dt, None)
print("after 5 s still:", status())
L.execute("TURN = function() TRUE.heading = TRUE.heading + 1.0 / 60 end")
run(Trail, target, 60, dt, L.eval("TURN"))
print("after 1 s turning at 1 rad/s:", status())
L.execute("FAST = function() TRUE.heading = TRUE.heading + 3.0 / 60 end")
run(Trail, target, 60, dt, L.eval("FAST"))
print("after 1 s turning at 3 rad/s:", status())
run(Trail, target, 60, dt, None)
print("settled facing away:", status())
L.execute("TRUE.heading = 1.0")
run(Trail, target, 3, dt, None)
print("3 frames after a camera jump back:", status())
run(Trail, target, 30, dt, None)
print("0.5 s after the jump:", status())
L.execute("WALK = function() local h = 1.45; TRUE.heading = h; TRUE.px = TRUE.px + math.sin(h) * 7 / 60; TRUE.py = TRUE.py + math.cos(h) * 7 / 60 end")
run(Trail, target, 180, dt, L.eval("WALK"))
print("after 3 s walking:", status())
print(Trail.Status())
