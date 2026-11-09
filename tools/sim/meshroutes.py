exec(open("meshtest.py").read())
tests = [("garden -> temple", 2402.0, 10706.3 - 1000, 2550.5, 9631.9),
	("player bridge -> earlier Darnassus spot", 2418.4, 10024.2, 2314, 10089),
	("player bridge -> Dolanaar", 2418.4, 10024.2, 950, 9850),
	("Dolanaar -> Shadowglen", 950, 9850, 830, 10300),
	("bridge east of Darnassus", 1700, 10130, 1420, 10100),
	("path near Rellian", 2463.3, 10098.4, 2534.3, 10085.6)]
for name, px, py, tx, ty in tests:
	print(name, end=": ")
	route(px, py, tx, ty)
