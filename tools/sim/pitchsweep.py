exec(open("sparksim.py").read().split("status = lambda")[0])
L.execute("QUANT = true")
cam = Trail.Camera()
run(Trail, target, 120, 1/60, None)
print("start: probe", Trail.Status().split("probe ")[-1], "pitch %.2f" % cam.pitch)
def tilt(to, frames=60):
	L.execute(f"TILT = function() TRUE.pitch = TRUE.pitch + ({to} - TRUE.pitch) * 0.15 end")
	dists = set()
	for i in range(frames):
		run(Trail, target, 1, 1/60, L.eval("TILT"))
		dists.add(Trail.Status().split("probe ")[-1])
	st = Trail.Status()
	print(f"tilt to {to:+.2f}: true pitch {L.eval('TRUE.pitch'):.2f}, solved {cam.pitch:.2f}, valid {cam.valid}, probe distances used {sorted(dists)}, sparkles {st.split('sparkles ')[1].split(' |')[0]}")
for p in (0.6, 1.4, 0.45, -0.7):
	tilt(p)
