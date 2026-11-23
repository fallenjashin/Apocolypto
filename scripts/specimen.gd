class_name Specimen
extends RigidBody3D
## An alien specimen. The server owns its physics and AI; clients just follow
## the synced position. Holding works like a spring from each holder's hands.
## One holder's spring is weaker than an awake specimen's struggle, two are stronger:
## that is the whole co-op rule, and it comes out of the physics, not a script check.

## Tune these freely. struggle vs HOLD_FORCE decides how many people it takes.
const SPECIES := {
	"skitter": {"label": "Skitter", "color": Color(0.55, 0.9, 0.3), "size": 0.6, "mass": 15.0,
		"speed": 5.0, "stun": 6.0, "struggle": 1300.0, "value": 40, "temper": "skittish"},
	"brute": {"label": "Brute", "color": Color(0.85, 0.35, 0.25), "size": 1.3, "mass": 70.0,
		"speed": 2.5, "stun": 9.0, "struggle": 1700.0, "value": 150, "temper": "territorial"},
	"glimmer": {"label": "Glimmer", "color": Color(0.5, 0.6, 1.0), "size": 0.5, "mass": 10.0,
		"speed": 10.0, "stun": 3.5, "struggle": 1500.0, "value": 350, "temper": "shy", "volatile": true, "blinker": true},
	# Not loot: a hunter that stalks the crew. It can be stunned but never captured or sold.
	"stalker": {"label": "Stalker", "color": Color(0.16, 0.1, 0.2), "size": 1.1, "mass": 60.0,
		"speed": 5.4, "stun": 4.0, "struggle": 0.0, "value": 0, "temper": "hunter", "hostile": true},
}
## Each species has a temper: a rule that changes what the crew has to do.
## "hint" is shown on the crosshair readout so players can learn it.
const TEMPERS := {
	"skittish": {"name": "SKITTISH", "hint": "Lets one person walk up. Bolts from a group."},
	"territorial": {"name": "TERRITORIAL", "hint": "Ignores you until stunned, then hunts whoever stunned it."},
	"hunter": {"name": "HUNTER", "hint": "Hunts the crew and hits hard. A prod stuns it for 4 s. It can't be captured."},
	"shy": {"name": "SHY", "hint": "Blinks away when you close in. 2+ watchers freeze it (no blinking). Blows up if it wakes un-stunned."},
}
const STALK_DAMAGE := 25.0    # four hits kill
const STALK_REACH := 1.8
const STALK_COOLDOWN := 1.2
const HUNT_RANGE := 45.0
const BRUTE_DAMAGE := 20.0
const BOOM_DAMAGE := 35.0     # at point-blank range; falls off with distance
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
const FUSE_TIME := 3.0        # volatile specimens: seconds from waking up to exploding
const BOOM_RADIUS := 7.0
const BOOM_PUSH := 14.0
const HOME_RADIUS := 6.0      # how far from its spawn spot a specimen drifts before heading home
const BLINK_TRIGGER := 9.0    # a blinker teleports when a player gets this close...
const BLINK_TELL := 0.25      # ...after this warning flicker (a stun in time cancels it)
const BLINK_COOLDOWN := 5.0
const BLINK_MIN_DIST := 10.0  # it lands at least this far from every player
const FLEE_LOOK := 5.0        # how far ahead a fleeing specimen checks for walls
const FLEE_ANGLES := [0.0, 35.0, -35.0, 70.0, -70.0, 105.0, -105.0, 140.0, -140.0]
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
var attack_cd := 0.0        # server: a hunter's time until its next hit
var blink_t := 0.0           # server: >0 while the warning flicker plays
var blink_cd := 0.0
var fuse_t := 0.0           # synced: >0 means about to explode (volatile species only)
var home := Vector3.ZERO

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
	home = pos
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
	for path in [NodePath(".:net_pos"), NodePath(".:net_yaw"), NodePath(".:stun_left"), NodePath(".:held_by"), NodePath(".:mood"), NodePath(".:fuse_t")]:
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
		if global_position.distance_to(net_pos) > 5.0:
			global_position = net_pos   # a blink: jump, don't slide across the floor
		global_position = global_position.lerp(net_pos, k)
		yaw = lerp_angle(yaw, net_yaw, k)
	pivot.rotation.y = yaw
	_update_visual()


func is_stunned() -> bool:
	return stun_left > 0.0


## Volatile specimens that wake up and aren't stunned again blow up: everyone close is
## thrown back (and drops what they carry) and the loot is gone.
func _explode() -> void:
	for p in _players_within(BOOM_RADIUS):
		var away := p.global_position - global_position
		away.y = 0.0
		var d := away.length()
		if d < 0.1:
			away = Vector3(randf() - 0.5, 0, randf() - 0.5)
		var falloff := 1.0 - clampf(d / BOOM_RADIUS, 0.0, 1.0) * 0.6
		game.shove.rpc(p.peer_id, away.normalized() * BOOM_PUSH * falloff)
		game.damage_player(p.peer_id, BOOM_DAMAGE * falloff, "an exploding Glimmer")
	game.specimen_exploded(self)


## Called by the host when a player's prod lands.
func on_stunned(by: int) -> void:
	fuse_t = 0.0   # a fresh stun defuses a volatile specimen
	blink_t = 0.0  # ...and cancels a blink that was about to happen
	if str(spec.temper) == "territorial":
		provoked_by = by
		charge_t = CHARGE_TIME


static func skittish_radius(players_near: int) -> float:
	return SKITTISH_ALONE if players_near <= 1 else SKITTISH_GROUP


static func shy_frozen(watchers: int) -> bool:
	return watchers >= SHY_WATCHERS


func _server_tick(delta: float) -> void:
	var was_stunned := stun_left > 0.0
	stun_left = maxf(0.0, stun_left - delta)
	if bool(spec.get("volatile", false)):
		if was_stunned and stun_left <= 0.0:
			fuse_t = FUSE_TIME     # it just woke up: the clock starts
		elif fuse_t > 0.0:
			fuse_t -= delta
			if fuse_t <= 0.0:
				_explode()
				return
	var holders: Array = []
	var kept := PackedInt32Array()
	for id in held_by:
		var p := game.get_player(id)
		if p == null or game.is_dead(id):
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
		blink_t = 0.0


func _ai(delta: float) -> void:
	mood = 0
	var plan := NO_PLAN
	match str(spec.temper):
		"skittish": plan = _plan_skittish()
		"territorial": plan = _plan_territorial(delta)
		"shy": plan = _plan_shy(delta)
		"hunter": plan = _plan_hunter(delta)
	var desired := plan if plan.x != INF else _wander_plan(delta)
	var v := linear_velocity
	v.y = 0.0
	apply_central_force(((desired - v) * mass * 4.0).limit_length(mass * 30.0))
	if desired.length() > 0.1:
		yaw = lerp_angle(yaw, atan2(-desired.x, -desired.z), minf(1.0, 6.0 * delta))


## True when it has strayed from its spawn spot, on the same floor, so it can walk back.
func homesick() -> bool:
	if Level.floor_of(global_position.y) != Level.floor_of(home.y):
		return false   # no pathing between floors yet
	var flat := global_position - home
	flat.y = 0.0
	return flat.length() > HOME_RADIUS


func _wander_plan(delta: float) -> Vector3:
	if homesick():
		var goal := home
		if not game.floor_info.is_empty():
			goal = Floors.next_step(game.floor_info.maze, global_position, home)   # around the walls
		var back := goal - global_position
		back.y = 0.0
		wander_t = 0.0
		return back.normalized() * float(spec.speed) * 0.5
	wander_t -= delta
	if wander_t <= 0.0:
		wander_t = randf_range(1.5, 3.5)
		var a := randf() * TAU
		wander_dir = Vector3(cos(a), 0, sin(a)) * (0.0 if randf() < 0.3 else 1.0)
	return wander_dir * float(spec.speed) * 0.4


## Of several headings around `away`, the one with the most open space ahead
## (with a preference for straight away), so it doesn't run into walls or off edges.
func open_heading(away: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0, 0.3, 0)
	var best := away
	var best_score := -INF
	for deg in FLEE_ANGLES:
		var dir := away.rotated(Vector3.UP, deg_to_rad(deg))
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * FLEE_LOOK)
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		var clear := FLEE_LOOK if hit.is_empty() else from.distance_to(hit.position)
		# Also avoid running off an edge or down a hole: is there floor 1.5 m and 3 m ahead?
		for reach in [1.5, 3.0]:
			var ahead: Vector3 = from + dir * reach
			var gq := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3.DOWN * 3.0)
			gq.exclude = [get_rid()]
			if space.intersect_ray(gq).is_empty():
				clear = minf(clear, reach * 0.5)
		var score := clear / FLEE_LOOK + 0.4 * cos(deg_to_rad(deg))
		if score > best_score:
			best_score = score
			best = dir
	return best


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
		return open_heading(away.normalized()) * float(spec.speed) * speed_mult
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
		game.damage_player(provoked_by, BRUTE_DAMAGE, "a Brute")
		provoked_by = 0
		return Vector3.ZERO
	return to.normalized() * float(spec.speed) * CHARGE_SPEED


## The nearest living player on this level who isn't hiding behind closed elevator doors.
func _hunt_target() -> Player:
	var best: Player = null
	var best_d := HUNT_RANGE
	for p in game.alive_players():
		if Level.floor_of(p.global_position.y) != Level.floor_of(global_position.y):
			continue
		if game.doors[1] and Floors.in_zone(game.floor_info.get("cab", {}), p.global_position):
			continue
		var d := p.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## Hunter: follows the maze route to the nearest exposed player and hits them. If everyone
## left is shut in the elevator, it waits outside the doors (and the game lets it force them).
func _plan_hunter(delta: float) -> Vector3:
	attack_cd = maxf(0.0, attack_cd - delta)
	var maze: Dictionary = game.floor_info.get("maze", {})
	var goal := NO_PLAN
	var target := _hunt_target()
	if target != null:
		goal = target.global_position
		var to := goal - global_position
		to.y = 0.0
		mood = 1
		if to.length() < STALK_REACH:
			if attack_cd <= 0.0:
				attack_cd = STALK_COOLDOWN
				game.shove.rpc(target.peer_id, to.normalized() * 5.0)
				game.damage_player(target.peer_id, STALK_DAMAGE, "a Stalker")
			return Vector3.ZERO
	elif game.doors[1] and not maze.is_empty():
		goal = game.floor_info.cab.door.global_position + Vector3(2.0, 0.0, 0.0)
		mood = 1
	if goal.x == INF:
		return NO_PLAN
	var step := goal
	if not maze.is_empty():
		step = Floors.next_step(maze, global_position, goal)
	var dir := step - global_position
	dir.y = 0.0
	if dir.length() < 0.5:
		return Vector3.ZERO
	return dir.normalized() * float(spec.speed)


## How many players have this specimen near the middle of their view.
func watchers() -> int:
	var n := 0
	for p in _players_within(SHY_RANGE):
		var to := global_position - p.cam.global_position
		if p.look_dir().angle_to(to) < deg_to_rad(SHY_CONE_DEG):
			n += 1
	return n


## Shy: runs like normal, but freezes solid while two or more players are looking at it.
func _plan_shy(delta := 0.0) -> Vector3:
	if shy_frozen(watchers()):
		mood = 2
		blink_t = 0.0   # watched by two players: it can't blink either
		return Vector3.ZERO
	if bool(spec.get("blinker", false)):
		blink_cd = maxf(0.0, blink_cd - delta)
		if blink_t > 0.0:
			blink_t -= delta
			mood = 3
			if blink_t <= 0.0:
				blink_t = 0.0
				blink()
				blink_cd = BLINK_COOLDOWN
		elif blink_cd <= 0.0 and not _players_within(BLINK_TRIGGER).is_empty():
			blink_t = BLINK_TELL
			mood = 3
	return _flee_plan(FLEE_RADIUS, 1.0)


## Where a blink lands: an open maze cell that's far from every player.
func blink_target() -> Vector3:
	var options: Array[Vector3] = []
	var best := global_position
	var best_d := -1.0
	var cells: Array = game.floor_info.get("cells", [])
	for pt in cells:
		var nearest := INF
		for c in game.players_root.get_children():
			nearest = minf(nearest, (c as Node3D).global_position.distance_to(pt))
		if nearest >= BLINK_MIN_DIST and pt.distance_to(global_position) > 6.0:
			options.append(pt)
		if nearest > best_d:
			best_d = nearest
			best = pt
	return options.pick_random() if not options.is_empty() else best


func blink() -> void:
	var from := global_position
	var to := blink_target()
	global_position = to
	linear_velocity = Vector3.ZERO
	game.blink_fx.rpc(from, to)


func _update_visual() -> void:
	var status := ""
	if is_stunned():
		var flick := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02)
		body_mat.emission = Color(0.4, 0.7, 1.0)
		body_mat.emission_energy_multiplier = 0.25 + 0.5 * flick
		status = "STUNNED %.1fs" % stun_left
	elif fuse_t > 0.0:
		var blink := 0.5 + 0.5 * sin(Time.get_ticks_msec() * (0.01 + 0.03 / maxf(fuse_t, 0.3)))
		body_mat.emission = Color(1.0, 0.9, 0.3)
		body_mat.emission_energy_multiplier = 0.5 + 2.5 * blink
		status = "UNSTABLE %.1fs - STUN IT!" % fuse_t
	elif mood == 3:
		body_mat.emission = Color(0.6, 0.9, 1.0)
		body_mat.emission_energy_multiplier = 2.5
		status = "BLINKING!"
	elif mood == 1:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.015)
		body_mat.emission = Color(1.0, 0.15, 0.1)
		body_mat.emission_energy_multiplier = 0.8 + 1.2 * pulse
		status = "HUNTING!" if bool(spec.get("hostile", false)) else "ENRAGED!"
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
	pivot.visible = not (mood == 3 and (Time.get_ticks_msec() / 40) % 2 == 0)   # flicker while about to blink
	if bool(spec.get("hostile", false)):
		tag.text = "%s  [%s]\n%s" % [spec.label, TEMPERS[spec.temper].name, status]
	else:
		tag.text = "%s  $%d  [%s]\n%s" % [spec.label, spec.value, TEMPERS[spec.temper].name, status]
