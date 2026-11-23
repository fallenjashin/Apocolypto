class_name Intro
extends Node3D
## Opening cinematic, played locally on each player's machine when they load in:
## your view turns to the city, an asteroid streaks down, it hits with a flash,
## a boom and screen shake, and the crater appears. Then something huge rises out
## of the crater and roars, and a pack of aliens pours out, runs across the streets
## and climbs the walls of OUR building. You can move the whole time.
## Pure visuals: nothing here is networked or affects gameplay.

const FALL_START := 0.3   # seconds after loading before it appears
const IMPACT := 4.0       # when it hits
const MOTHER_RISE := 1.5  # seconds after impact the giant starts rising
const SWARM_START := 3.0  # seconds after impact the pack starts pouring out
const SWARM_SIZE := 16
const END := 20.0         # when the intro cleans itself up

var game: Game
var t := 0.0
var start_pos: Vector3
var asteroid: Node3D
var trail: CPUParticles3D
var flash: MeshInstance3D
var flash_mat: StandardMaterial3D
var flash_light: OmniLight3D
var debris: CPUParticles3D
var rumble: AudioStreamPlayer
var boom: AudioStreamPlayer
var aimed := false
var impacted := false
var toasted := false
var toasted2 := false
var mother: Node3D
var roar: AudioStreamPlayer
var roared := false
var swarm: Array = []   # one Dictionary per creature: node, start, target, top_y, t0, speed


func setup(g: Game) -> void:
	game = g
	name = "Intro"


func _ready() -> void:
	for n in get_tree().get_nodes_in_group("crater"):
		n.visible = false
	# Start high in the sky, off to the left of where the roof looks toward the crater.
	var f := Vector3(Level.CRATER_POS.x, 0, Level.CRATER_POS.z).normalized()
	var left := Vector3(f.z, 0, -f.x)
	start_pos = Level.CRATER_POS + left * 130.0 + Vector3.UP * 230.0 + f * 40.0

	asteroid = Node3D.new()
	add_child(asteroid)
	asteroid.global_position = start_pos
	var rock := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 6
	sm.height = 12
	sm.material = Level.mat(Color(1.0, 0.55, 0.2), 6.0)
	rock.mesh = sm
	asteroid.add_child(rock)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.6, 0.3)
	glow.light_energy = 6.0
	glow.omni_range = 120
	asteroid.add_child(glow)

	trail = CPUParticles3D.new()
	trail.local_coords = false
	trail.amount = 160
	trail.lifetime = 1.2
	trail.direction = Vector3.UP
	trail.spread = 15
	trail.initial_velocity_min = 2
	trail.initial_velocity_max = 6
	trail.gravity = Vector3.ZERO
	trail.scale_amount_min = 2.0
	trail.scale_amount_max = 4.0
	var shrink := Curve.new()
	shrink.add_point(Vector2(0, 1))
	shrink.add_point(Vector2(1, 0))
	trail.scale_amount_curve = shrink
	var pm := SphereMesh.new()
	pm.radius = 1.5
	pm.height = 3
	pm.material = Level.mat(Color(1.0, 0.4, 0.1), 3.0)
	trail.mesh = pm
	asteroid.add_child(trail)

	flash = MeshInstance3D.new()
	var fm := SphereMesh.new()
	fm.radius = 1
	fm.height = 2
	flash_mat = StandardMaterial3D.new()
	flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_mat.albedo_color = Color(1.0, 0.95, 0.75, 1.0)
	fm.material = flash_mat
	flash.mesh = fm
	flash.visible = false
	add_child(flash)
	flash.global_position = Level.CRATER_POS
	flash_light = OmniLight3D.new()
	flash_light.light_color = Color(1.0, 0.8, 0.5)
	flash_light.omni_range = 250
	flash_light.light_energy = 0.0
	add_child(flash_light)
	flash_light.global_position = Level.CRATER_POS + Vector3(0, 20, 0)

	debris = CPUParticles3D.new()
	debris.emitting = false
	debris.one_shot = true
	debris.explosiveness = 1.0
	debris.amount = 70
	debris.lifetime = 4.0
	debris.direction = Vector3.UP
	debris.spread = 55
	debris.initial_velocity_min = 25
	debris.initial_velocity_max = 55
	debris.gravity = Vector3(0, -20, 0)
	debris.scale_amount_min = 0.6
	debris.scale_amount_max = 1.8
	var dm := BoxMesh.new()
	dm.size = Vector3.ONE * 1.5
	dm.material = Level.mat(Color(0.4, 1.0, 0.5), 2.0)
	debris.mesh = dm
	add_child(debris)
	debris.global_position = Level.CRATER_POS + Vector3(0, 6, 0)

	rumble = AudioStreamPlayer.new()
	rumble.stream = _noise_sound(IMPACT - FALL_START, true)
	rumble.volume_db = -8.0
	add_child(rumble)
	boom = AudioStreamPlayer.new()
	boom.stream = _noise_sound(3.5, false)
	add_child(boom)
	_build_mother()
	_build_swarm()
	roar = AudioStreamPlayer.new()
	roar.stream = _roar_sound(2.8)
	add_child(roar)
	rumble.play()


func _process(delta: float) -> void:
	advance(delta)


## Moves the cinematic forward by `dt` seconds. Split out so tests can fast-forward it.
func advance(dt: float) -> void:
	t += dt
	if not aimed:
		_aim()
	if not impacted:
		var k := clampf((t - FALL_START) / (IMPACT - FALL_START), 0.0, 1.0)
		asteroid.global_position = start_pos.lerp(Level.CRATER_POS, k * k)  # speeds up as it falls
		if t >= IMPACT:
			_impact()
	else:
		var s := t - IMPACT
		flash.scale = Vector3.ONE * minf(1.0 + s * 150.0, 120.0)
		flash_mat.albedo_color.a = clampf(1.0 - s / 1.2, 0.0, 1.0)
		flash.visible = flash_mat.albedo_color.a > 0.0
		flash_light.light_energy = 40.0 * exp(-s * 2.5)
		_shake(0.25 * exp(-s * 2.0) if s < 2.0 else 0.0)
		if s >= 2.0 and not toasted:
			toasted = true
			game.hud.toast("Something is crawling out of the crater...")
		if s >= 8.0 and not toasted2:
			toasted2 = true
			game.hud.toast("They're coming for our building.")
		_animate_mother(s)
		_animate_swarm(s)
	if t >= END:
		_shake(0.0)
		queue_free()


## A huge silhouette with glowing eyes. Rises, roars toward the roof, sinks back down.
func _build_mother() -> void:
	mother = Node3D.new()
	mother.visible = false
	add_child(mother)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(22, 60, 16)
	bm.material = Level.mat(Color(0.06, 0.08, 0.06))
	body.mesh = bm
	mother.add_child(body)
	for e in [Vector3(-5, 22, -8.1), Vector3(5, 22, -8.1), Vector3(-2, 25, -8.1), Vector3(2, 25, -8.1), Vector3(0, 19, -8.1)]:
		var eye := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3(2.6, 1.4, 0.4)
		em.material = Level.mat(Color(0.5, 1.0, 0.4), 8.0)
		eye.mesh = em
		eye.position = e
		mother.add_child(eye)
	for side in [-1.0, 1.0]:   # two long arms gripping the crater rim
		var arm := MeshInstance3D.new()
		var am := BoxMesh.new()
		am.size = Vector3(4, 40, 4)
		am.material = Level.mat(Color(0.08, 0.1, 0.07))
		arm.mesh = am
		arm.position = Vector3(side * 17, 2, -4)
		arm.rotation.z = side * 0.6
		mother.add_child(arm)
	var d := -Level.CRATER_POS
	mother.rotation.y = atan2(-d.x, -d.z)   # face the roof
	mother.global_position = Vector3(Level.CRATER_POS.x, Level.GROUND_Y - 32.0, Level.CRATER_POS.z)


func _animate_mother(s: float) -> void:
	var low := Level.GROUND_Y - 32.0          # fully underground
	var high := Level.GROUND_Y + 22.0         # towers over the skyline
	var y := low
	if s >= MOTHER_RISE:
		mother.visible = true
		var up := clampf((s - MOTHER_RISE) / 3.0, 0.0, 1.0)
		var down := clampf((s - MOTHER_RISE - 9.0) / 3.0, 0.0, 1.0)
		y = lerpf(low, high, up * up * (3.0 - 2.0 * up)) - (high - low) * down
		mother.visible = down < 1.0
		if up >= 0.7 and not roared:
			roared = true
			roar.play()
		if roared and s < MOTHER_RISE + 6.0:
			_shake(0.06)
	mother.global_position = Vector3(Level.CRATER_POS.x, y, Level.CRATER_POS.z)


## The pack: each one runs from the crater rim to a wall of our building, climbs it,
## and slips inside through a window on one of the floors you'll be exploring.
func _build_swarm() -> void:
	var to_us := Vector3(-Level.CRATER_POS.x, 0, -Level.CRATER_POS.z).normalized()
	var base_a := atan2(to_us.z, to_us.x)
	for i in SWARM_SIZE:
		var big := i % 5 == 4
		var c := Color(0.85, 0.35, 0.25) if big else Color(0.55, 0.9, 0.3)
		var size := 3.0 if big else 1.6
		var n := _creature(c, size)
		var a := base_a + randf_range(-0.9, 0.9)
		var start := Vector3(Level.CRATER_POS.x + cos(a) * 16, Level.GROUND_Y + size / 2, Level.CRATER_POS.z + sin(a) * 16)
		var target: Vector3
		if randf() < 0.5:
			target = Vector3(Level.HALF + 0.6, Level.GROUND_Y + size / 2, randf_range(-12, 12))   # east wall
		else:
			target = Vector3(randf_range(-12, 12), Level.GROUND_Y + size / 2, -Level.HALF - 0.6)  # north wall
		n.global_position = start
		swarm.append({"node": n, "start": start, "target": target, "size": size,
			"top_y": Level.level_y(randi_range(1, Level.DEEPEST)) + 2.0,
			"t0": SWARM_START + i * 0.35 + randf() * 0.3, "speed": randf_range(14, 20) * (0.7 if big else 1.0)})


func _creature(c: Color, size: float) -> Node3D:
	var n := Node3D.new()
	n.visible = false
	add_child(n)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size, size * 0.7, size * 1.3)
	bm.material = Level.mat(c, 0.9)
	body.mesh = bm
	n.add_child(body)
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3.ONE * size * 0.2
		em.material = Level.mat(Color(1, 1, 0.7), 6.0)
		eye.mesh = em
		eye.position = Vector3(side * size * 0.25, size * 0.15, -size * 0.66)
		n.add_child(eye)
	return n


func _animate_swarm(s: float) -> void:
	for c in swarm:
		var n: Node3D = c.node
		var local: float = s - c.t0
		if local < 0.0:
			continue
		var start: Vector3 = c.start
		var target: Vector3 = c.target
		var run_time: float = start.distance_to(target) / c.speed
		var climb_time: float = (c.top_y - target.y) / 7.0
		if local < run_time:
			n.visible = true
			var p := start.lerp(target, local / run_time)
			p.y += absf(sin(local * 14.0)) * c.size * 0.3   # scuttle bob
			n.global_position = p
			var dir := target - start
			n.rotation = Vector3(0, atan2(-dir.x, -dir.z), 0)
		elif local < run_time + climb_time:
			n.visible = true
			var up: float = (local - run_time) / climb_time
			n.global_position = Vector3(target.x, lerpf(target.y, c.top_y, up), target.z)
			var wall_out := Vector3(signf(target.x), 0, 0) if absf(target.x) > Level.HALF else Vector3(0, 0, signf(target.z))
			n.rotation = Vector3(0, atan2(wall_out.x, wall_out.z), 0)
			n.rotation.x = -PI / 2   # belly against the wall, head up
		elif local < run_time + climb_time + 0.4:
			n.scale = Vector3.ONE * (1.0 - (local - run_time - climb_time) / 0.4)   # squeezes in a window
		else:
			n.visible = false


func _aim() -> void:
	var p := game.local_player()
	if p == null:
		if t > 1.0:
			aimed = true  # player never showed up in time; skip the camera turn
		return
	var d := Level.CRATER_POS - p.global_position
	p.rotation.y = atan2(-d.x, -d.z)
	p.head.rotation.x = -0.12   # slightly down, so the street is in view
	aimed = true


func _impact() -> void:
	impacted = true
	asteroid.visible = false
	trail.emitting = false
	flash.visible = true
	debris.emitting = true
	for n in get_tree().get_nodes_in_group("crater"):
		n.visible = true
	boom.play()
	game.hud.flash_screen()


func _shake(amount: float) -> void:
	var p := game.local_player()
	if p == null:
		return
	p.cam.h_offset = randf_range(-amount, amount)
	p.cam.v_offset = randf_range(-amount, amount)


## A low, wobbling growl for the giant.
static func _roar_sound(seconds: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(seconds * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	var y := 0.0
	for i in n:
		var tt := float(i) / rate
		var env := minf(1.0, tt / 0.3) * minf(1.0, (seconds - tt) / 1.0)
		var freq := 55.0 + 25.0 * sin(tt * 3.0) + 8.0 * sin(tt * 37.0)
		phase += freq / rate
		var saw := 2.0 * (phase - floorf(phase)) - 1.0
		y += 0.08 * (randf() * 2.0 - 1.0 - y)
		var v := (saw * 0.55 + y * 2.5) * env
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w


## Builds a sound from filtered noise so the project needs no audio files.
## rising=true: a rumble that swells as the asteroid gets closer.
## rising=false: the impact boom (sharp hit, low thump, long decay).
static func _noise_sound(seconds: float, rising: bool) -> AudioStreamWAV:
	var rate := 22050
	var n := int(seconds * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var y := 0.0
	for i in n:
		var tt := float(i) / rate
		var env: float
		var cutoff: float
		if rising:
			env = pow(tt / seconds, 2.0)
			cutoff = lerpf(80.0, 400.0, tt / seconds)
		else:
			env = minf(1.0, tt / 0.01) * exp(-tt / 0.9)
			cutoff = lerpf(1200.0, 90.0, minf(1.0, tt / 1.5))
		var a := 1.0 - exp(-TAU * cutoff / rate)
		y += a * (randf() * 2.0 - 1.0 - y)
		var v := y * env * 4.0
		if not rising:
			v += sin(TAU * 42.0 * tt) * exp(-tt / 0.45) * 0.7
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
