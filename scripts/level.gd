class_name Level
extends RefCounted
## Builds the roof (the camp), the building's outer shell and the city, in code so
## every peer gets identical geometry without syncing anything. The expedition
## floors you reach by elevator are built by Floors.

const HALF := 15.0          # building is 30 x 30 m
const ROOF_HALF := 18.0     # the roof deck overhangs the walls: 36 x 36 m of camp
const GROUND_Y := -18.6     # street level
const FLOOR_H := 6.0        # floor-to-floor height
const SLAB := 0.5
const DEEPEST := 3
const PEN_MIN := Vector3(6.0, -0.5, 6.0)
const PEN_MAX := Vector3(13.0, 5.0, 13.0)
const CRATER_POS := Vector3(95, -14, -70)
## The elevator on the roof: door middle (the cab extends west from here).
const ROOF_CAB_FRONT := Vector3(12.0, 0.0, -4.0)

static var _mats := {}
static var roof_cab := {}   # the roof elevator: {door, zone_c, zone_h, panel}


static func level_y(l: int) -> float:
	return -FLOOR_H * l


## 0 on the roof (camp), 1 anywhere else (down on an expedition floor).
static func floor_of(y: float) -> int:
	return 0 if y > -3.0 else 1


## Height of the walkable surface under something at height y.
static func ground_y(y: float) -> float:
	return 0.0 if y > -3.0 else Floors.EXP_Y


## True when something has fallen out of the world (off the roof, or through a floor).
static func fell_out(y: float) -> bool:
	return (y < -28.0 and y > -90.0) or y < Floors.EXP_Y - 12.0


static func in_pen(p: Vector3) -> bool:
	return p.x > PEN_MIN.x and p.x < PEN_MAX.x and p.z > PEN_MIN.z and p.z < PEN_MAX.z \
		and p.y > PEN_MIN.y and p.y < PEN_MAX.y


static func mat(c: Color, emit := 0.0) -> StandardMaterial3D:
	var key := "%s|%s" % [c.to_html(), emit]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emit
	_mats[key] = m
	return m


static func box(root: Node, center: Vector3, size: Vector3, color: Color, collide := true,
		rot := Vector3.ZERO, emit := 0.0) -> Node3D:
	var n: Node3D
	if collide:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		sb.add_child(cs)
		n = sb
	else:
		n = Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat(color, emit)
	mi.mesh = bm
	if not collide:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(mi)
	n.position = center
	n.rotation = rot
	root.add_child(n)
	return n


static func label(root: Node, text: String, pos: Vector3, size := 64, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = size
	l.pixel_size = 0.006
	l.outline_size = 10
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(l)
	return l


static func build(root: Node3D) -> void:
	var world := Node3D.new()
	world.name = "World"
	root.add_child(world)
	_environment(world)
	var floor_c := Color(0.32, 0.32, 0.34)
	var wall_c := Color(0.5, 0.48, 0.45)
	# The roof deck: the building's top plus an overhang.
	box(world, Vector3(0, -SLAB / 2, 0), Vector3(HALF * 2, SLAB, HALF * 2), floor_c)
	var extra := ROOF_HALF - HALF
	for sz in [-1.0, 1.0]:
		box(world, Vector3(0, -SLAB / 2, sz * (HALF + extra / 2)), Vector3(ROOF_HALF * 2, SLAB, extra), floor_c)
		box(world, Vector3(sz * (HALF + extra / 2), -SLAB / 2, 0), Vector3(extra, SLAB, HALF * 2), floor_c)
	_roof(world)
	_shell(world, wall_c)
	_city(world)


## The building seen from outside: just walls. What's inside the elevator is its own
## world (see Floors) and doesn't have to match.
static func _shell(world: Node3D, wc: Color) -> void:
	var h := -level_y(DEEPEST) - SLAB + 0.5
	var cy := -SLAB - h / 2
	box(world, Vector3(0, cy, -HALF - 0.25), Vector3(31, h, 0.5), wc)
	box(world, Vector3(0, cy, HALF + 0.25), Vector3(31, h, 0.5), wc)
	box(world, Vector3(-HALF - 0.25, cy, 0), Vector3(0.5, h, 31), wc)
	box(world, Vector3(HALF + 0.25, cy, 0), Vector3(0.5, h, 31), wc)
	box(world, Vector3(0, cy, 0), Vector3(HALF * 2, h, HALF * 2), wc.darkened(0.3))
	for l in range(1, DEEPEST + 1):   # dark window bands so it still reads as floors
		for sgn in [-1.0, 1.0]:
			box(world, Vector3(0, level_y(l) + 2.2, sgn * (HALF + 0.52)), Vector3(28, 1.4, 0.05), Color(0.05, 0.06, 0.1), false, Vector3.ZERO, 0.2)
			box(world, Vector3(sgn * (HALF + 0.52), level_y(l) + 2.2, 0), Vector3(0.05, 1.4, 28), Color(0.05, 0.06, 0.1), false, Vector3.ZERO, 0.2)


static func _roof(world: Node3D) -> void:
	var par := Color(0.55, 0.52, 0.5)
	# A see-through railing instead of a solid wall, so you can watch the street from the roof.
	# Note: small specimens can slip under it. Don't drop your catch off the roof!
	var span := ROOF_HALF * 2 + 0.5
	for sgn in [-1.0, 1.0]:
		var e: float = sgn * (ROOF_HALF + 0.1)
		box(world, Vector3(0, 1.05, e), Vector3(span, 0.12, 0.12), par)      # top rail
		box(world, Vector3(e, 1.05, 0), Vector3(0.12, 0.12, span), par)
		box(world, Vector3(0, 0.08, e), Vector3(span, 0.16, 0.3), par)       # curb
		box(world, Vector3(e, 0.08, 0), Vector3(0.3, 0.16, span), par)
		var post := -ROOF_HALF
		while post <= ROOF_HALF + 0.01:
			box(world, Vector3(post, 0.55, e), Vector3(0.1, 1.0, 0.1), par)
			box(world, Vector3(e, 0.55, post), Vector3(0.1, 1.0, 0.1), par)
			post += 3.0
	# Specimen pen (military pickup)
	var pen_c := Color(0.95, 0.75, 0.2)
	box(world, Vector3(9.5, 0.03, 9.5), Vector3(7, 0.06, 7), pen_c, false, Vector3.ZERO, 0.5)
	for cx in [PEN_MIN.x, PEN_MAX.x]:
		for cz in [PEN_MIN.z, PEN_MAX.z]:
			box(world, Vector3(cx, 0.6, cz), Vector3(0.2, 1.2, 0.2), pen_c, true, Vector3.ZERO, 1.5)
	label(world, "SPECIMEN PEN\nmilitary pickup", Vector3(9.5, 2.6, 9.5), 64, pen_c)
	# The interrupted dinner
	box(world, Vector3(-5, 0.4, 7), Vector3(2.4, 0.8, 1.2), Color(0.45, 0.3, 0.2))
	for cx in [-5.6, -4.4]:
		box(world, Vector3(cx, 0.88, 7), Vector3(0.08, 0.16, 0.08), Color(1, 0.6, 0.2), false, Vector3.ZERO, 4.0)
	label(world, "dinner (interrupted)", Vector3(-5, 1.6, 7), 40)
	box(world, Vector3(4, 0.4, -8), Vector3(1.2, 0.8, 0.8), Color(0.25, 0.35, 0.2))
	label(world, "MILITARY RADIO", Vector3(4, 1.4, -8), 40, Color(0.6, 1, 0.6))
	roof_cab = Floors.build_cab(world, ROOF_CAB_FRONT, Color(0.45, 0.45, 0.5))
	label(world, "ELEVATOR DOWN", ROOF_CAB_FRONT + Vector3(-2.0, 3.9, 0), 56, Color(1, 0.85, 0.4))
	var string_light := OmniLight3D.new()
	string_light.position = Vector3(-6, 3.5, 5)
	string_light.light_color = Color(1, 0.8, 0.55)
	string_light.light_energy = 1.2
	string_light.omni_range = 20
	world.add_child(string_light)


static func _environment(world: Node3D) -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.07, 0.05, 0.12)
	psm.sky_horizon_color = Color(0.75, 0.35, 0.18)
	psm.ground_horizon_color = Color(0.4, 0.18, 0.1)
	psm.ground_bottom_color = Color(0.05, 0.03, 0.03)
	sky.sky_material = psm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.18
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.45, 0.25, 0.18)
	env.fog_density = 0.0025
	env.glow_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1, 0.6, 0.4)
	sun.light_energy = 0.7
	sun.rotation_degrees = Vector3(-25, 140, 0)
	sun.shadow_enabled = true
	world.add_child(sun)


## The burning city and the asteroid crater, visible from the roof.
## Keep a clear sightline from the roof to the crater so you can watch the impact
## and always see the alien glow from camp.
static func _blocks_crater_view(pos: Vector3, w: float) -> bool:
	var to := Vector2(CRATER_POS.x, CRATER_POS.z)
	var p := Vector2(pos.x, pos.z)
	var along := p.dot(to.normalized())
	if along < 0.0 or along > to.length() + 20.0:
		return false
	var closest := to.normalized() * along
	return p.distance_to(closest) < 18.0 + w * 0.5


static func _city(world: Node3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var ground := GROUND_Y
	const CELL := 48.0    # one city block plus its road
	const BLOCK := 36.0   # the sidewalk square inside it; roads are 12 m wide
	box(world, Vector3(0, ground - 0.1, 0), Vector3(700, 0.2, 700), Color(0.2, 0.2, 0.21), false)
	var line_c := Color(0.7, 0.6, 0.25)
	for k in range(-5, 5):
		var r := CELL * k + CELL / 2
		box(world, Vector3(r, ground + 0.02, 0), Vector3(0.3, 0.04, 470), line_c, false)
		box(world, Vector3(0, ground + 0.02, r), Vector3(470, 0.04, 0.3), line_c, false)
	var walk := Color(0.4, 0.39, 0.38)
	var crater2 := Vector2(CRATER_POS.x, CRATER_POS.z)
	for i in range(-4, 5):
		for j in range(-4, 5):
			var c := Vector3(i * CELL, 0, j * CELL)
			if Vector2(c.x, c.z).distance_to(crater2) < 40.0:
				continue  # the asteroid flattened this block
			box(world, Vector3(c.x, ground + 0.15, c.z), Vector3(BLOCK, 0.3, BLOCK), walk, false)
			if i == 0 and j == 0:
				continue  # our building's block
			var dist := Vector2(c.x, c.z).length()
			for lot in 4:
				if rng.randf() < 0.25:
					continue
				var lc := c + Vector3((lot % 2 - 0.5) * BLOCK / 2, 0, (lot / 2 - 0.5) * BLOCK / 2)
				var w := rng.randf_range(10, 16)
				var d := rng.randf_range(10, 16)
				var h := rng.randf_range(12, 30) + rng.randf() * minf(dist, 200.0) * 0.3
				var pos := lc + Vector3(0, ground + 0.3 + h / 2, 0)
				if _blocks_crater_view(pos, maxf(w, d)):
					continue
				box(world, pos, Vector3(w, h, d), Color(0.16, 0.15, 0.16).lightened(rng.randf() * 0.15), false)
				if rng.randf() < 0.2:
					box(world, pos + Vector3(0, h / 2 + 0.8, 0), Vector3(w * 0.6, 1.6, d * 0.6),
						Color(1.0, 0.45, 0.1), false, Vector3.ZERO, 3.0)
	# Abandoned and burning cars on the roads
	var lights := 0
	for n in 45:
		var road := CELL * rng.randi_range(-4, 3) + CELL / 2 + rng.randf_range(-3.0, 3.0)
		var along := rng.randf_range(-190, 190)
		var on_x := rng.randf() < 0.5
		var pos := Vector3(road, ground + 0.65, along) if on_x else Vector3(along, ground + 0.65, road)
		if Vector2(pos.x, pos.z).distance_to(crater2) < 45.0:
			continue
		var yaw := (0.0 if on_x else PI / 2) + rng.randf_range(-0.5, 0.5)
		var roll := PI / 2 if rng.randf() < 0.15 else 0.0
		var car_c := Color.from_hsv(rng.randf(), 0.35, rng.randf_range(0.25, 0.5))
		box(world, pos, Vector3(2.0, 1.3, 4.4), car_c, false, Vector3(0, yaw, roll))
		if rng.randf() < 0.25:
			box(world, pos + Vector3(0, 1.1, 0), Vector3(1.4, 0.9, 2.5), Color(1.0, 0.45, 0.1), false, Vector3(0, yaw, 0), 3.5)
			if lights < 5 and pos.length() < 120.0:
				lights += 1
				var o := OmniLight3D.new()
				o.position = pos + Vector3(0, 3, 0)
				o.light_color = Color(1.0, 0.5, 0.2)
				o.light_energy = 2.0
				o.omni_range = 18
				world.add_child(o)
	# Scorched ground and rubble around the impact; revealed when the asteroid hits
	var scorch := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 44
	cm.bottom_radius = 44
	cm.height = 0.3
	cm.material = mat(Color(0.05, 0.04, 0.04))
	scorch.mesh = cm
	scorch.position = Vector3(CRATER_POS.x, ground + 0.1, CRATER_POS.z)
	world.add_child(scorch)
	scorch.add_to_group("crater")
	for n in 26:
		var a := rng.randf() * TAU
		var r := rng.randf_range(18, 40)
		var sz := Vector3(rng.randf_range(2, 6), rng.randf_range(1, 4), rng.randf_range(2, 6))
		box(world, Vector3(CRATER_POS.x + cos(a) * r, ground + sz.y / 2, CRATER_POS.z + sin(a) * r), sz,
			Color(0.2, 0.18, 0.17), false, Vector3(rng.randf(), rng.randf() * TAU, rng.randf())).add_to_group("crater")
	var crater_pos := CRATER_POS
	var rock := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 14
	sm.height = 28
	sm.material = mat(Color(0.12, 0.1, 0.1))
	rock.mesh = sm
	rock.position = crater_pos
	world.add_child(rock)
	rock.add_to_group("crater")
	var glow := MeshInstance3D.new()
	var gm := SphereMesh.new()
	gm.radius = 24
	gm.height = 6
	gm.material = mat(Color(0.3, 1.0, 0.45), 2.5)
	glow.mesh = gm
	glow.position = crater_pos + Vector3(0, -3, 0)
	world.add_child(glow)
	glow.add_to_group("crater")
	# A column of alien light rising out of the crater: the landmark you see from the roof.
	box(world, crater_pos + Vector3(0, 60, 0), Vector3(3, 150, 3), Color(0.35, 1.0, 0.5), false, Vector3.ZERO, 4.0).add_to_group("crater")
	var gl := OmniLight3D.new()
	gl.position = crater_pos + Vector3(0, 12, 0)
	gl.light_color = Color(0.4, 1.0, 0.5)
	gl.light_energy = 4.0
	gl.omni_range = 90
	world.add_child(gl)
	gl.add_to_group("crater")
