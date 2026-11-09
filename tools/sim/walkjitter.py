import random
exec(open("sparksim.py").read().split("status = lambda")[0])
L.execute("""
function RenderLagged()
	-- Draw the marker with the player position of the previous frame.
	local cx, cy = TRUE.px, TRUE.py
	if PREV then TRUE.px, TRUE.py = PREV[1], PREV[2] end
	RenderFrame()
	TRUE.px, TRUE.py = cx, cy
end
function SNAP() local t = {} for i, o in ipairs(ALL) do t[i] = { o.x, o.y, o.alpha } end return t end
function JERK(a, b) -- mean |second difference| over textures visible in all three snapshots
	local sum, n = 0, 0
	for i, o in ipairs(ALL) do
		local p, q = a[i], b[i]
		if p[1] and q[1] and o.x and p[3] > 0.05 and q[3] > 0.05 and (o.alpha or 0) > 0.05 then
			local jx = o.x - 2 * q[1] + p[1]
			local jy = o.y - 2 * q[2] + p[2]
			sum = sum + math.sqrt(jx * jx + jy * jy); n = n + 1
		end
	end
	return n > 0 and sum / n or 0
end
""")
step = L.eval("""function(Trail, target, dt, lagged)
	local h = 1.45
	PREV = { TRUE.px, TRUE.py }
	TRUE.heading = h
	TRUE.px = TRUE.px + math.sin(h) * 7 * dt
	TRUE.py = TRUE.py + math.cos(h) * 7 * dt
	if lagged then RenderLagged() else RenderFrame() end
	Trail.Update(dt, target, true)
end""")
L.execute('QUANT = true')
for lagged in (True,):
	random.seed(1)
	L.execute("TRUE.px, TRUE.py, TRUE.heading = 2463.3, 10098.4, 1.45")
	ns2 = L.eval("{}")
	for i in range(120):
		step(Trail, target, 1/60, lagged)
	snaps = []
	total = 0
	for i in range(150):
		dt = random.uniform(0.007, 0.012)
		snaps.append(L.eval("SNAP()"))
		step(Trail, target, dt, lagged)
		if len(snaps) >= 2:
			total += L.eval("JERK")(snaps[-2], snaps[-1])
	print(f"marker drawn with {'previous' if lagged else 'current'} frame's position: mean jerk {total / 149:.3f} UI units |", Trail.Status().split("|")[-1].strip())
