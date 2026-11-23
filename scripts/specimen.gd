class_name Specimen
extends RigidBody3D
## An alien specimen. The server owns its physics and AI; clients just follow
## the synced position. Holding works like a spring from each holder's hands.
## One holder's spring is weaker than an awake specimen's struggle, two are stronger:
## that is the whole co-op rule, and it comes out of the physics, not a script check.

## Tune these freely. struggle vs HOLD_FORCE decides how many people it takes.
const SPECIES := {
	"skitter": {"label": "Skitter", "color": Color(0.55, 0.9, 0.3), "size": 0.6, "mass": 15.0,
		"speed": 5.0, "stun": 6.0, "struggle": 1300.0, "value": 40, "floor": 1, "temper": "skittish"},
	"brute": {"label": "Brute", "color": Color(0.85, 0.35, 0.25), "size": 1.3, "mass": 70.0,
		"speed": 2.5, "stun": 9.0, "struggle": 1700.0, "value": 150, "floor": 2, "temper": "territorial"},
	"glimmer": {"label": "Glimmer", "color": Color(0.5, 0.6, 1.0), "size": 0.5, "mass": 10.0,
		"speed": 8.0, "stun": 3.5, "struggle": 1500.0, "value": 350, "floor": 3, "temper": "shy"},
}
## Each species has a temper: a rule that changes what the crew has to do.
## "hint" is shown on the crosshair readout so players can learn it.
const TEMPERS := {
	"skittish": {"name": "SKITTISH", "hint": "Lets one person walk up. Bolts from a group."},
	"territorial": {"name": "TERRITORIAL", "hint": "Ignores you until stunned, then hunts whoever stunned it."},
	"shy": {"name": "SHY", "hint": "Runs. Freezes only while 2+ players are looking at it."},
}
const SKITTISH_ALONE := 4.5   # flee radius when only one player is near
const SKITTISH_GROUP := 8.0   # flee radius (and speed-up) when two or more are near
const SKITTISH_GROUP_SPEED := 1.4
const CHARGE_SPEED := 1.8     # a provoked Brute's speed multiplier (it is slower than a sprint)
const CHARGE_TIME := 10.0     # how long it hunts before calming down
const SLAM_DIST := 1.6
const SLAM_PUSH := 9.0
const SHY_RANGE := 16.0       # how far away a look still counts
const SHY_WATCHERS := 2       # how many pairs of eyes freeze a Shy specimen
const SHY_CONE_DEG := 30.0
const NO_PLAN := Vector3(INF, 0, 0)   # "no special plan, wander instead"
const HOLD_FORCE := 1000.0   # max pull per holder (newtons)
const SPRING_K := 600.0
const BREAK_DIST := 3.0      # holder lets go if the specimen gets this far from their hands
const FLEE_RADIUS := 7.0

# Synced from the server
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var stun_left := 0.0
var held_by := PackedInt32Array()
var mood := 0               # synced tell: 0 calm, 1 enraged and hunting, 2 frozen by watchers
var provoked_by := 0        # server only: who a Territorial specimen is hunting (0 = nobody)
var charge_t := 0.0

var species := "skitter"
var spec: Dictionary
var game: Game
var yaw := 0.0
var wander_dir := Vector3.ZERO
var wander_t := 0.0
var pivot: Node3D
var body_mat: StandardMaterial3D
var tag: Label3D


func setup(n: String, sp: String, pos: Vector3, g: Game) -> void:
	name = n
	species = sp
	spec = SPECIES[sp]
	game = g
	position = pos
	net_pos = pos
	mass = spec.mass
	linear_damp = 0.6
	lock_rotation = true
	var size: float = spec.size
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3.ONE * size
	cs.shape = sh
	add_child(cs)
	pivot = Node3D.new()
	add_child(pivot)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * size
	body_mat = StandardMaterial3D.new()
	body_mat.albedo_color = spec.color
	body_mat.emission_enabled = true
	body_mat.emission = spec.color
	body_mat.emission_energy_multiplier = 0.3
	bm.material = body_mat
	mi.mesh = bm
	pivot.add_child(mi)
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3.ONE * size * 0.18
		em.material = Level.mat(Color(1, 1, 0.7), 4.0)
		eye.mesh = em
		eye.position = Vector3(side * size * 0.22, size * 0.15, -size * 0.5 - 0.01)
		pivot.add_child(eye)
	tag = Label3D.new()
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position.y = size * 0.5 + 0.45
	tag.font_size = 36
	tag.pixel_size = 0.005
	tag.outline_size = 8
	add_child(tag)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	var cfg := SceneReplicationConfig.new()
	for path in [NodePath(".:net_pos"), NodePath(".:net_yaw"), NodePath(".:stun_left"), NodePath(".:held_by"), NodePath(".:mood")]:
		cfg.add_property(path)
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = cfg
	add_child(sync)


func _ready() -> void:
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_server_tick(delta)
		net_pos = global_position
		net_yaw = yaw
	else:
		var k := minf(1.0, 18.0 * delta)
		global_position = global_position.lerp(net_pos, k)
		yaw = lerp_angle(yaw, net_yaw, k)
	pivot.rotation.y = yaw
	_update_visual()


func is_stunned() -> bool:
	return stun_left > 0.0


## Called by the host when a player's prod lands.
func on_stunned(by: int) -> void:
	if str(spec.temper) == "territorial":
		provoked_by = by
		charge_t = CHARGE_TIME


static func skittish_radius(players_near: int) -> float:
	return SKITTISH_ALONE if players_near <= 1 else SKITTISH_GROUP


static func shy_frozen(watchers: int) -> bool:
	return watchers >= SHY_WATCHERS


func _server_tick(delta: float) -> void:
	stun_left = maxf(0.0, stun_left - delta)
	var holders: Array = []
	var kept := PackedInt32Array()
	for id in held_by:
		var p := game.get_player(id)
		if p == null:
			continue
		if global_position.distance_to(p.get_hold_point()) > BREAK_DIST:
			continue  # slipped out of this holder's hands
		kept.append(id)
		holders.append(p)
	if kept != held_by:
		held_by = kept
	if holders.size() > 0:
		var damping := 2.0 * sqrt(SPRING_K * mass) * 0.8 / holders.size()
		for p in holders:
			var f: Vector3 = (p.get_hold_point() - global_position) * SPRING_K - linear_velocity * damping
			apply_central_force(f.limit_length(HOLD_FORCE))
		if not is_stunned():
			var c := Vector3.ZERO
			for p in holders:
				c += p.global_position
			c /= holders.size()
			var away := global_position - c
			away.y = 0.0
			if away.length() < 0.1:
				away = Vector3(randf() - 0.5, 0, randf() - 0.5)
			var jitter := Vector3(randf_range(-1, 1), randf_range(0, 0.6), randf_range(-1, 1)) * 0.5
			apply_central_force((away.normalized() + jitter).normalized() * float(spec.struggle))
			yaw = atan2(away.x, away.z)
	elif not is_stunned():
		_ai(delta)
	if is_stunned() or held_by.size() > 0:
		mood = 0


func _ai(delta: float) -> void:
	mood = 0
	var plan := NO_PLAN
	match str(spec.temper):
		"skittish": plan = _plan_skittish()
		"territorial": plan = _plan_territorial(delta)
		"shy": plan = _plan_shy()
	var desired := Vector3.ZERO
	if plan.x != INF:
		desired = plan
	else:
		wander_t -= delta
		if wander_t <= 0.0:
			wander_t = randf_range(1.5, 3.5)
			var a := randf() * TAU
			wander_dir = Vector3(cos(a), 0, sin(a)) * (0.0 if randf() < 0.3 else 1.0)
		desired = wander_dir * float(spec.speed) * 0.4
	var v := linear_velocity
	v.y = 0.0
	apply_central_force(((desired - v) * mass * 4.0).limit_length(mass * 30.0))
	if desired.length() > 0.1:
		yaw = lerp_angle(yaw, atan2(-desired.x, -desired.z), minf(1.0, 6.0 * delta))


func _players_within(radius: float) -> Array[Player]:
	var out: Array[Player] = []
	for c in game.players_root.get_children():
		var p := c as Player
		if p and p.global_position.distance_to(global_position) <= radius:
			out.append(p)
	return out


## Run away from the nearest player if they're inside `radius`.
func _flee_plan(radius: float, speed_mult: float) -> Vector3:
	var nearest := game.nearest_player(global_position)
	if nearest and nearest.global_position.distance_to(global_position) < radius:
		var away := global_position - nearest.global_position
		away.y = 0.0
		return away.normalized() * float(spec.speed) * speed_mult
	return NO_PLAN


## Skittish: one person can walk right up to it. Two or more and it bolts, faster.
func _plan_skittish() -> Vector3:
	var near := _players_within(SKITTISH_GROUP).size()
	return _flee_plan(skittish_radius(near), SKITTISH_GROUP_SPEED if near >= 2 else 1.0)


## Territorial: never flees. Once stunned it hunts the player who stunned it,
## shoves them on contact, then calms down.
func _plan_territorial(delta: float) -> Vector3:
	if provoked_by == 0:
		return NO_PLAN
	var target := game.get_player(provoked_by)
	charge_t -= delta
	if target == null or charge_t <= 0.0:
		provoked_by = 0
		return NO_PLAN
	var to := target.global_position - global_position
	to.y = 0.0
	mood = 1
	if to.length() < SLAM_DIST:
		game.shove.rpc(provoked_by, to.normalized() * SLAM_PUSH)
		provoked_by = 0
		return Vector3.ZERO
	return to.normalized() * float(spec.speed) * CHARGE_SPEED


## How many players have this specimen near the middle of their view.
func watchers() -> int:
	var n := 0
	for p in _players_within(SHY_RANGE):
		var to := global_position - p.cam.global_position
		if p.look_dir().angle_to(to) < deg_to_rad(SHY_CONE_DEG):
			n += 1
	return n


## Shy: runs like normal, but freezes solid while two or more players are looking at it.
func _plan_shy() -> Vector3:
	if shy_frozen(watchers()):
		mood = 2
		return Vector3.ZERO
	return _flee_plan(FLEE_RADIUS, 1.0)


func _update_visual() -> void:
	var status := ""
	if is_stunned():
		var flick := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02)
		body_mat.emission = Color(0.4, 0.7, 1.0)
		body_mat.emission_energy_multiplier = 0.25 + 0.5 * flick
		status = "STUNNED %.1fs" % stun_left
	elif mood == 1:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.015)
		body_mat.emission = Color(1.0, 0.15, 0.1)
		body_mat.emission_energy_multiplier = 0.8 + 1.2 * pulse
		status = "ENRAGED!"
	elif mood == 2:
		body_mat.emission = Color(1, 1, 1)
		body_mat.emission_energy_multiplier = 0.9
		status = "FROZEN (watched)"
	else:
		body_mat.emission = spec.color
		body_mat.emission_energy_multiplier = 0.3
		if held_by.size() > 0:
			status = "STRUGGLING!"
	if held_by.size() > 0:
		status += "  [held x%d]" % held_by.size()
	tag.text = "%s  $%d  [%s]\n%s" % [spec.label, spec.value, TEMPERS[spec.temper].name, status]
