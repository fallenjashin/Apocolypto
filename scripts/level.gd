class_name Level
extends RefCounted
## Builds the gray-box building in code so every peer gets identical geometry
## without syncing anything. Level 0 is the roof (the camp); levels 1-3 go down.
## Ramps alternate sides, so every floor makes you cross the building.

const HALF := 15.0          # building is 30 x 30 m
const FLOOR_H := 6.0        # floor-to-floor height
const SLAB := 0.5
const DEEPEST := 3
const RAMP_HALF_LEN := 7.0  # ramp holes span z = -7..7
const PEN_MIN := Vector3(6.0, -0.5, 6.0)
const PEN_MAX := Vector3(13.0, 5.0, 13.0)
const CRATER_POS := Vector3(95, -14, -70)

static var _mats := {}


static func level_y(l: int) -> float:
	return -FLOOR_H * l


## X centre of the hole in slab `l` (the ramp from level l down to l+1).
static func hole_x(l: int) -> float:
	return -13.0 if l % 2 == 0 else 13.0


## Odd floors use the layout as written, even floors are mirrored in X.
static func mirror(l: int) -> float:
	return 1.0 if l % 2 == 1 else -1.0


static func floor_of(y: float) -> int:
	return clampi(ceili(-y / FLOOR_H - 0.01), 0, DEEPEST)


static func in_pen(p: Vector3) -> bool:
	return p.x > PEN_MIN.x and p.x < PEN_MAX.x and p.z > PEN_MIN.z and p.z < PEN_MAX.z \
		and p.y > PEN_MIN.y and p.y < PEN_MAX.y


static func spawn_points(l: int) -> Array:
	var m := mirror(l)
	var out := []
	for p in [Vector2(-5, -3), Vector2(5, 3), Vector2(-6, 12.5), Vector2(6, -12.5),
			Vector2(-5, 4), Vector2(5, -4), Vector2(-7, -12), Vector2(7, 12)]:
		out.append(Vector3(p.x * m, level_y(l) + 1.0, p.y))
	return out


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
	for l in range(0, DEEPEST + 1):
		var y := level_y(l)
		var fc := floor_c.darkened(0.12 * l)
		if l < DEEPEST:
			var hx := hole_x(l)
			var s := signf(hx)
			box(world, Vector3(-s * 2.0, y - SLAB / 2, 0), Vector3(26, SLAB, 30), fc)
			box(world, Vector3(hx, y - SLAB / 2, -11), Vector3(4, SLAB, 8), fc)
			box(world, Vector3(hx, y - SLAB / 2, 11), Vector3(4, SLAB, 8), fc)
			_ramp(world, hx, y, fc.lightened(0.15))
			# Railings: inner edge of the hole and its far end. Enter from the z = -7 end.
			var rail := Color(0.75, 0.6, 0.2)
			box(world, Vector3(hx - s * 2.0, y + 0.5, 0), Vector3(0.15, 1.0, 14), rail)
			box(world, Vector3(hx, y + 0.5, 7), Vector3(4, 1.0, 0.15), rail)
		else:
			box(world, Vector3(0, y - SLAB / 2, 0), Vector3(30, SLAB, 30), fc)
		if l == 0:
			_roof(world)
		else:
			_interior(world, l, wall_c.darkened(0.12 * l))
	_city(world)


static func _ramp(world: Node3D, hx: float, y: float, c: Color) -> void:
	var drop := FLOOR_H
	var run := RAMP_HALF_LEN * 2.0
	var ang := atan2(drop, run)
	var length := sqrt(drop * drop + run * run)
	var t := 0.4
	var n := Vector3(0, cos(ang), sin(ang))
	var center := Vector3(hx, y - drop / 2, 0) - n * (t / 2)
	box(world, center, Vector3(4, t, length), c, true, Vector3(ang, 0, 0))


static func _roof(world: Node3D) -> void:
	var par := Color(0.55, 0.52, 0.5)
	box(world, Vector3(0, 0.55, -HALF - 0.25), Vector3(31, 1.1, 0.5), par)
	box(world, Vector3(0, 0.55, HALF + 0.25), Vector3(31, 1.1, 0.5), par)
	box(world, Vector3(-HALF - 0.25, 0.55, 0), Vector3(0.5, 1.1, 31), par)
	box(world, Vector3(HALF + 0.25, 0.55, 0), Vector3(0.5, 1.1, 31), par)
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
	label(world, "STAIRS DOWN", Vector3(hole_x(0), 1.6, -9), 48, Color(1, 0.85, 0.4))
	var string_light := OmniLight3D.new()
	string_light.position = Vector3(0, 3.5, 4)
	string_light.light_color = Color(1, 0.8, 0.55)
	string_light.light_energy = 1.2
	string_light.omni_range = 20
	world.add_child(string_light)


static func _interior(world: Node3D, l: int, wc: Color) -> void:
	var y := level_y(l)
	var h := FLOOR_H - SLAB
	var cy := y + h / 2
	var m := mirror(l)
	box(world, Vector3(0, cy, -HALF - 0.25), Vector3(31, h, 0.5), wc)
	box(world, Vector3(0, cy, HALF + 0.25), Vector3(31, h, 0.5), wc)
	box(world, Vector3(-HALF - 0.25, cy, 0), Vector3(0.5, h, 31), wc)
	box(world, Vector3(HALF + 0.25, cy, 0), Vector3(0.5, h, 31), wc)
	# Wall A splits the floor in half; doors at z -9..-6 and 4..7
	for seg in [[-15.0, -9.0], [-6.0, 4.0], [7.0, 15.0]]:
		box(world, Vector3(0, cy, (seg[0] + seg[1]) / 2), Vector3(0.3, h, absf(seg[1] - seg[0])), wc)
	for seg in [[-10.0, -6.0], [-3.0, 0.0]]:
		_xwall(world, 9.0, seg[0] * m, seg[1] * m, cy, h, wc)
	for seg in [[0.0, 4.0], [7.0, 10.0]]:
		_xwall(world, -9.0, seg[0] * m, seg[1] * m, cy, h, wc)
	for p in [Vector2(-8, 0), Vector2(8, 5), Vector2(3, -13), Vector2(-3, 12)]:
		box(world, Vector3(p.x * m, y + 0.6, p.y), Vector3(1.2, 1.2, 1.2), Color(0.45, 0.35, 0.22))
	var t := (l - 1) / 2.0
	var col := Color(1.0, 0.85, 0.7).lerp(Color(1.0, 0.25, 0.2), t)
	for p in [Vector2(-7, -7), Vector2(7, -7), Vector2(-7, 7), Vector2(7, 7)]:
		var o := OmniLight3D.new()
		o.position = Vector3(p.x, y + 4.8, p.y)
		o.light_color = col
		o.light_energy = 1.3 - 0.35 * (l - 1)
		o.omni_range = 12
		world.add_child(o)
	label(world, "DEPTH %d" % l, Vector3(hole_x(l - 1) * 0.85, y + 2.6, 10), 72, col)


static func _xwall(world: Node3D, z: float, x0: float, x1: float, cy: float, h: float, c: Color) -> void:
	box(world, Vector3((x0 + x1) / 2, cy, z), Vector3(absf(x1 - x0), h, 0.3), c)


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
	var ground := -18.6
	box(world, Vector3(0, ground - 0.1, 0), Vector3(600, 0.2, 600), Color(0.08, 0.07, 0.07), false)
	for i in 90:
		var a := rng.randf() * TAU
		var r := rng.randf_range(34, 160)
		var w := rng.randf_range(8, 20)
		var h := rng.randf_range(10, 85)
		var c := Color(0.16, 0.15, 0.16).lightened(rng.randf() * 0.15)
		var pos := Vector3(cos(a) * r, ground + h / 2, sin(a) * r)
		if _blocks_crater_view(pos, w):
			continue
		box(world, pos, Vector3(w, h, w * rng.randf_range(0.7, 1.3)), c, false)
		if rng.randf() < 0.25:
			box(world, pos + Vector3(0, h / 2 + 0.8, 0), Vector3(w * 0.6, 1.6, w * 0.6),
				Color(1.0, 0.45, 0.1), false, Vector3.ZERO, 3.0)
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
