class_name Player
extends CharacterBody3D
## First-person crew member. Each client owns its own movement (synced to others);
## stun and grab are requests the server checks.

const WALK := 5.0
const SPRINT := 8.0
const ACCEL := 12.0
const JUMP_V := 5.5
const GRAVITY := 16.0
const MOUSE_SENS := 0.0025
const MAX_CHARGES := 6
const PROD_RANGE := 3.5
const GRAB_RANGE := 3.5
const PROD_COOLDOWN := 0.6
const RECHARGE_TIME := 0.8
const AIM_ASSIST_DEG := 10.0

var peer_id := 1
var game: Game
var head: Node3D
var cam: Camera3D
var body_mesh: MeshInstance3D
var visor: MeshInstance3D
var tag: Label3D
var charges := MAX_CHARGES
var prod_cd := 0.0
var recharge_t := 0.0
var grabbing := ""
var knock := Vector3.ZERO   # a shove from a specimen; fades out quickly


func setup(id: int, g: Game) -> void:
	peer_id = id
	game = g
	name = str(id)
	floor_max_angle = deg_to_rad(50)
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	shape.shape = cap
	shape.position.y = 0.9
	add_child(shape)
	body_mesh = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.35
	cm.height = 1.8
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.from_hsv(fmod(float(id) * 0.618, 1.0), 0.55, 0.95)
	cm.material = m
	body_mesh.mesh = cm
	body_mesh.position.y = 0.9
	add_child(body_mesh)
	head = Node3D.new()
	head.name = "Head"
	head.position.y = 1.6
	add_child(head)
	visor = MeshInstance3D.new()
	var vm := BoxMesh.new()
	vm.size = Vector3(0.5, 0.15, 0.2)
	vm.material = Level.mat(Color(0.1, 0.1, 0.12))
	visor.mesh = vm
	visor.position = Vector3(0, 0, -0.3)
	head.add_child(visor)
	cam = Camera3D.new()
	cam.name = "Cam"
	cam.fov = 80
	cam.near = 0.05
	head.add_child(cam)
	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0.25, -0.2, 0)
	lamp.spot_range = 20
	lamp.spot_angle = 30
	lamp.light_energy = 3.0
	lamp.light_color = Color(1, 0.95, 0.85)
	head.add_child(lamp)
	tag = Label3D.new()
	tag.text = "Host" if id == 1 else "P%d" % (id % 1000)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position.y = 2.15
	tag.font_size = 40
	tag.pixel_size = 0.006
	tag.outline_size = 8
	add_child(tag)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	var cfg := SceneReplicationConfig.new()
	for path in [NodePath(".:position"), NodePath(".:rotation"), NodePath("Head:rotation")]:
		cfg.add_property(path)
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = cfg
	add_child(sync)
	set_multiplayer_authority(id)


func _process(_delta: float) -> void:
	var alive := not game.is_dead(peer_id)
	if not is_multiplayer_authority():
		body_mesh.visible = alive
		visor.visible = alive
		tag.visible = alive


func _ready() -> void:
	var mine := is_multiplayer_authority()
	cam.current = mine
	body_mesh.visible = not mine
	visor.visible = not mine
	tag.visible = not mine


## A new day: back to camp with a full prod and empty hands.
func reset_for_day() -> void:
	global_position = game.roof_spawn(peer_id)
	velocity = Vector3.ZERO
	charges = max_charges()
	prod_cd = 0.0
	grabbing = ""


func max_charges() -> int:
	return Shop.max_charges(game.upgrades)


func look_dir() -> Vector3:
	return -cam.global_basis.z


func get_hold_point() -> Vector3:
	return head.global_position - head.global_basis.z * 2.0


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or not game.in_game:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		rotate_y(-mm.relative.x * MOUSE_SENS)
		head.rotation.x = clampf(head.rotation.x - mm.relative.y * MOUSE_SENS, -1.45, 1.45)
	elif event.is_action_pressed("menu"):
		if game.hud.shop_open:
			game.close_shop()
		elif game.hud.elevator_open:
			game.close_elevator()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("shop"):
		game.toggle_shop()
	elif event.is_action_pressed("interact"):
		game.toggle_elevator()
	elif event.is_action_pressed("prod"):
		if game.hud.shop_open or game.hud.elevator_open:
			return   # clicking the world shouldn't close a panel by accident
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			game.capture_mouse()
		else:
			try_prod()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	var can_move := game.in_game and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not game.is_dead(peer_id)
	var input := Vector2.ZERO
	if can_move:
		input = Input.get_vector("left", "right", "fwd", "back")
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = JUMP_V
	var dir := (transform.basis * Vector3(input.x, 0, input.y)).normalized()
	var sprint_speed := SPRINT * Shop.sprint_mult(game.upgrades)
	var speed := (sprint_speed if can_move and Input.is_action_pressed("sprint") else WALK) * game.carry_speed_factor(peer_id)
	var k := minf(1.0, ACCEL * delta)
	velocity.x = lerpf(velocity.x, dir.x * speed, k)
	velocity.z = lerpf(velocity.z, dir.z * speed, k)
	velocity.x += knock.x
	velocity.z += knock.z
	knock = knock.move_toward(Vector3.ZERO, 18.0 * delta)
	move_and_slide()

	prod_cd = maxf(0.0, prod_cd - delta)
	if Level.floor_of(global_position.y) == 0 and charges < max_charges():
		recharge_t += delta
		if recharge_t >= RECHARGE_TIME:
			recharge_t = 0.0
			charges += 1
	if can_move:
		if Input.is_action_just_pressed("grab"):
			try_grab()
		elif Input.is_action_just_released("grab"):
			release()


func try_prod() -> void:
	if game.is_dead(peer_id):
		return
	if charges <= 0:
		game.hud.toast("Prod is empty - recharge it on the roof")
		return
	if prod_cd > 0.0:
		return
	charges -= 1
	prod_cd = PROD_COOLDOWN
	game.hud.zap()
	var t := look_target(PROD_RANGE)
	if t:
		game.request_stun.rpc_id(1, String(t.name))


func try_grab() -> void:
	if game.is_dead(peer_id):
		return
	var t := look_target(GRAB_RANGE)
	if t:
		grabbing = String(t.name)
		game.request_grab.rpc_id(1, grabbing, true)


func release() -> void:
	if grabbing != "":
		game.request_grab.rpc_id(1, grabbing, false)
		grabbing = ""


## What the crosshair is on: a raycast, plus a small cone of aim assist.
func look_target(reach: float) -> Specimen:
	var from := cam.global_position
	var fwd := -cam.global_basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * reach)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and hit.collider is Specimen:
		return hit.collider
	var best: Specimen = null
	var best_ang := deg_to_rad(AIM_ASSIST_DEG)
	for s in game.specimens():
		var to := s.global_position - from
		if to.length() > reach + 0.5:
			continue
		var ang := fwd.angle_to(to)
		if ang < best_ang:
			best_ang = ang
			best = s
	return best
