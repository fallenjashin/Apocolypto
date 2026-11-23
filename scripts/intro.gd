class_name Intro
extends Node3D
## Opening cinematic, played locally on each player's machine when they load in:
## your view turns to the city, an asteroid streaks down, it hits with a flash,
## a boom and screen shake, and the crater appears. You can move the whole time.
## Pure visuals: nothing here is networked or affects gameplay.

const FALL_START := 0.3   # seconds after loading before it appears
const IMPACT := 4.0       # when it hits
const END := 8.0          # when the intro cleans itself up

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
	if t >= END:
		_shake(0.0)
		queue_free()


func _aim() -> void:
	var p := game.local_player()
	if p == null:
		if t > 1.0:
			aimed = true  # player never showed up in time; skip the camera turn
		return
	var d := Level.CRATER_POS - p.global_position
	p.rotation.y = atan2(-d.x, -d.z)
	p.head.rotation.x = 0.15
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
