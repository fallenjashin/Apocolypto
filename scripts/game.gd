class_name Game
extends Node3D
## Game root: networking, spawning, the specimen ledger, and the test modes.
##
## Loot-as-data rule: a specimen is a physics object only while it's out in the
## building. Once it reaches the pen it is deleted and becomes a ledger entry
## (credits + count). Nothing piles up, nothing desyncs, nothing lags.

const PORT := 7777
const MAX_PLAYERS := 4
const QUOTA := 600
const POPULATION := {"skitter": 4, "brute": 2, "glimmer": 1}
const RESPAWN_DELAY := 20.0
const DEPTH_NAMES := ["ROOF (camp)", "DEPTH 1: Skitters", "DEPTH 2: Brutes", "DEPTH 3: Glimmers"]

var players_root: Node3D
var specimens_root: Node3D
var player_spawner: MultiplayerSpawner
var specimen_spawner: MultiplayerSpawner
var hud: Hud
var in_game := false
var credits := 0
var delivered := 0
var next_spec_id := 0
var respawn_queue: Array = []   # [[seconds_left, species], ...] (server only)
var test_mode := ""
var test_failures := 0


func _ready() -> void:
	_setup_input()
	Level.build(self)
	players_root = Node3D.new()
	players_root.name = "Players"
	add_child(players_root)
	specimens_root = Node3D.new()
	specimens_root.name = "Specimens"
	add_child(specimens_root)
	player_spawner = _make_spawner("PlayerSpawner", "../Players", _spawn_player_node)
	specimen_spawner = _make_spawner("SpecimenSpawner", "../Specimens", _spawn_specimen_node)
	hud = Hud.new()
	hud.name = "Hud"
	hud.game = self
	add_child(hud)
	hud.host_pressed.connect(host)
	hud.join_pressed.connect(join)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_start_game)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	hud.ledger(0, 0, QUOTA, "")
	var args := OS.get_cmdline_user_args()
	for a in ["--autotest-host", "--autotest-join", "--selftest", "--shot"]:
		if a in args:
			test_mode = a
	match test_mode:
		"--autotest-host": _autotest_host()
		"--autotest-join": _autotest_join()
		"--selftest": _selftest()
		"--shot": _shot()


func _make_spawner(n: String, path: String, fn: Callable) -> MultiplayerSpawner:
	var s := MultiplayerSpawner.new()
	s.name = n
	add_child(s)
	s.spawn_path = NodePath(path)
	s.spawn_function = fn
	return s


func _setup_input() -> void:
	var keys := {"fwd": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D,
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "grab": KEY_E, "menu": KEY_ESCAPE}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action]
			InputMap.action_add_event(action, ev)
	if not InputMap.has_action("prod"):
		InputMap.add_action("prod")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("prod", mb)


# --- Networking --------------------------------------------------------------

func host() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		hud.status("Could not host on port %d (%s)" % [PORT, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer
	_start_game()
	player_spawner.spawn([1])
	for sp in POPULATION:
		for i in POPULATION[sp]:
			spawn_specimen(sp)
	_broadcast("Shift started. The military wants live specimens.")


func join(ip: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip if ip != "" else "127.0.0.1", PORT)
	if err != OK:
		hud.status("Could not start client (%s)" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	hud.status("Connecting to %s..." % ip)


func _start_game() -> void:
	in_game = true
	hud.show_game()
	capture_mouse()
	if test_mode == "" or test_mode == "--shot":
		play_intro()


func play_intro() -> Intro:
	var intro := Intro.new()
	intro.setup(self)
	add_child(intro)
	return intro


func capture_mouse() -> void:
	if DisplayServer.get_name() != "headless" and test_mode == "":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		player_spawner.spawn([id])
		set_ledger.rpc_id(id, credits, delivered, "You joined the crew.")


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		var p := get_player(id)
		if p:
			p.queue_free()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	hud.status("Could not connect. Is the host running and is port %d open?" % PORT)


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	get_tree().reload_current_scene.call_deferred()


# --- Spawning ----------------------------------------------------------------

func _spawn_player_node(data: Variant) -> Node:
	var id: int = data[0]
	var p := Player.new()
	p.setup(id, self)
	p.position = Vector3(16.5 - (id % 4) * 1.3, 0.2, -16.6)   # at the NE railing, facing the crater
	return p


func _spawn_specimen_node(data: Variant) -> Node:
	var s := Specimen.new()
	s.setup(data[0], data[1], data[2], self)
	return s


func spawn_specimen(sp: String) -> void:
	var floor_l: int = Specimen.SPECIES[sp].floor
	var pts := Level.spawn_points(floor_l)
	var pos: Vector3 = pts.pick_random()
	for attempt in 10:
		var clear := true
		for s in specimens():
			if s.global_position.distance_to(pos) < 2.0:
				clear = false
		if clear:
			break
		pos = pts.pick_random()
	next_spec_id += 1
	specimen_spawner.spawn(["S%d" % next_spec_id, sp, pos])


# --- Queries used by players, specimens, HUD ---------------------------------

func get_player(id: int) -> Player:
	return players_root.get_node_or_null(str(id)) as Player


func local_player() -> Player:
	if multiplayer.multiplayer_peer == null:
		return null
	return get_player(multiplayer.get_unique_id())


func specimens() -> Array[Specimen]:
	var out: Array[Specimen] = []
	for c in specimens_root.get_children():
		if c is Specimen and not c.is_queued_for_deletion():
			out.append(c)
	return out


func nearest_player(pos: Vector3) -> Player:
	var best: Player = null
	var best_d := INF
	for c in players_root.get_children():
		var p := c as Player
		if p == null:
			continue
		var d := p.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = p
	return best


func held_spec_of(id: int) -> Specimen:
	for s in specimens():
		if id in s.held_by:
			return s
	return null


## Carrying slows you down; heavy specimens a lot, unless you share the load.
func carry_speed_factor(id: int) -> float:
	var s := held_spec_of(id)
	if s == null:
		return 1.0
	var m: float = s.spec.mass
	return clampf(1.0 / (1.0 + m / (35.0 * s.held_by.size())), 0.35, 1.0)


# --- Requests from clients (server decides) ----------------------------------

func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


@rpc("any_peer", "call_local", "reliable")
func request_stun(spec_name: String) -> void:
	if not multiplayer.is_server():
		return
	var s := specimens_root.get_node_or_null(spec_name) as Specimen
	var p := get_player(_sender())
	if s == null or p == null or p.global_position.distance_to(s.global_position) > 5.0:
		return
	s.stun_left = float(s.spec.stun)


@rpc("any_peer", "call_local", "reliable")
func request_grab(spec_name: String, on: bool) -> void:
	if not multiplayer.is_server():
		return
	var id := _sender()
	var s := specimens_root.get_node_or_null(spec_name) as Specimen
	if s == null:
		return
	if on:
		var p := get_player(id)
		if p == null or p.global_position.distance_to(s.global_position) > 5.0:
			return
		for other in specimens():   # one specimen per player
			if other != s and id in other.held_by:
				_remove_holder(other, id)
		if not id in s.held_by:
			var h := s.held_by
			h.append(id)
			s.held_by = h
	else:
		_remove_holder(s, id)


func _remove_holder(s: Specimen, id: int) -> void:
	var h := PackedInt32Array()
	for x in s.held_by:
		if x != id:
			h.append(x)
	s.held_by = h


@rpc("authority", "call_local", "reliable")
func set_ledger(c: int, d: int, msg: String) -> void:
	credits = c
	delivered = d
	hud.ledger(c, d, QUOTA, msg)


func _broadcast(msg: String) -> void:
	set_ledger.rpc(credits, delivered, msg)


# --- Server loop: deliveries and respawns ------------------------------------

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	for s in specimens():
		if Level.in_pen(s.global_position):
			_deliver(s)
		elif s.global_position.y < Level.level_y(Level.DEEPEST) - 10.0:
			respawn_queue.append([2.0, s.species])
			s.queue_free()
	for entry in respawn_queue:
		entry[0] -= delta
	while respawn_queue.size() > 0 and respawn_queue[0][0] <= 0.0:
		spawn_specimen(respawn_queue.pop_front()[1])


func _deliver(s: Specimen) -> void:
	var value: int = s.spec.value
	credits += value
	delivered += 1
	respawn_queue.append([RESPAWN_DELAY, s.species])
	s.queue_free()
	var msg := "%s delivered to the military: +$%d" % [s.spec.label, value]
	if credits >= QUOTA and credits - value < QUOTA:
		msg += ". QUOTA MET!"
	_broadcast(msg)


# --- Test modes (run from the command line, see README) ----------------------

func _wait(t: float) -> Signal:
	return get_tree().create_timer(t).timeout


func _watchdog(t: float) -> void:
	get_tree().create_timer(t).timeout.connect(func():
		print("TEST FAIL: timed out in ", test_mode)
		get_tree().quit(1))


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		test_failures += 1


func _place_near(p: Player, s: Specimen) -> void:
	var at := s.global_position
	p.global_position = Vector3(at.x + 1.4, Level.level_y(Level.floor_of(at.y)) + 0.05, at.z)
	p.velocity = Vector3.ZERO
	p.rotation.y = atan2(-(at.x - p.global_position.x), -(at.z - p.global_position.z))
	p.head.rotation.x = -0.5


func _autotest_host() -> void:
	_watchdog(40.0)
	host()
	var target: Specimen = null
	while target == null:
		await get_tree().physics_frame
		for s in specimens():
			for id in s.held_by:
				if id != 1:
					target = s
	print("[host] client is holding %s (%s)" % [target.name, target.species])
	target.global_position = Vector3(9.5, 1.0, 9.5)
	target.linear_velocity = Vector3.ZERO
	while credits <= 0:
		await get_tree().physics_frame
	print("[host] delivered, credits = %d" % credits)
	await _wait(1.5)
	print("AUTOTEST HOST: PASS")
	get_tree().quit(0)


func _autotest_join() -> void:
	_watchdog(40.0)
	join("127.0.0.1")
	var total: int = 0
	for sp in POPULATION:
		total += POPULATION[sp]
	while local_player() == null or specimens().size() < total:
		await get_tree().process_frame
	print("[join] connected as %d, sees %d specimens and %d players" % [
		multiplayer.get_unique_id(), specimens().size(), players_root.get_child_count()])
	var s: Specimen = null
	for c in specimens():
		if c.species == "skitter":
			s = c
			break
	var p := local_player()
	while not s.is_stunned():   # retry like a player would: it may run off between tries
		_place_near(p, s)
		await _wait(0.25)
		request_stun.rpc_id(1, String(s.name))
		await _wait(0.5)
	print("[join] stun confirmed through sync (%.1fs)" % s.stun_left)
	while is_instance_valid(s) and not multiplayer.get_unique_id() in s.held_by:
		_place_near(p, s)
		await _wait(0.25)
		request_grab.rpc_id(1, String(s.name), true)
		await _wait(0.5)
	print("[join] grab confirmed through sync")
	while credits <= 0:
		await get_tree().process_frame
	print("[join] ledger synced: credits = %d, delivered = %d" % [credits, delivered])
	print("AUTOTEST JOIN: PASS")
	get_tree().quit(0)


func _selftest() -> void:
	_watchdog(40.0)
	host()
	await _wait(0.3)
	print("Population spawned:")
	var counts := {}
	for s in specimens():
		counts[s.species] = counts.get(s.species, 0) + 1
		_check(Level.floor_of(s.global_position.y) == int(s.spec.floor),
			"%s %s spawned on depth %d" % [s.species, s.name, s.spec.floor])
	_check(counts == POPULATION, "population matches %s" % str(POPULATION))
	for s in specimens():
		s.queue_free()
	await get_tree().physics_frame
	var p := local_player()
	p.global_position = Vector3(-5, Level.level_y(1) + 0.05, -3)
	p.rotation.y = 0.0
	p.head.rotation.x = -0.3
	await _wait(0.3)
	specimen_spawner.spawn(["T1", "skitter", p.get_hold_point()])
	await get_tree().physics_frame
	var s := specimens_root.get_node("T1") as Specimen
	print("Struggle rules (skitter):")
	s.stun_left = 6.0
	s.held_by = PackedInt32Array([1])
	await _wait(2.5)
	_check(1 in s.held_by, "a stunned specimen stays in one player's hands")
	_check(s.global_position.distance_to(p.get_hold_point()) < 1.0, "it hangs at the hold point (%.2fm off)"
		% s.global_position.distance_to(p.get_hold_point()))
	s.stun_left = 0.0
	var t := 0.0
	while 1 in s.held_by and t < 5.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	_check(not 1 in s.held_by, "awake, it breaks free from one player (took %.1fs)" % t)
	var buddy := Player.new()   # a second crew member who stands still
	buddy.setup(999, self)
	players_root.add_child(buddy)
	buddy.global_position = p.global_position + Vector3(0.7, 0, 0)
	buddy.rotation.y = 0.0
	buddy.head.rotation.x = -0.3
	await get_tree().physics_frame
	s.global_position = p.get_hold_point()
	s.linear_velocity = Vector3.ZERO
	s.stun_left = 0.0
	s.held_by = PackedInt32Array([1, 999])
	await _wait(3.0)
	_check(1 in s.held_by and 999 in s.held_by, "awake, two players can hold it")
	print("Roof:")
	var q := PhysicsRayQueryParameters3D.create(Vector3(Level.ROOF_HALF - 1.0, 5, 0), Vector3(Level.ROOF_HALF - 1.0, -5, 0))
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	_check(not hit.is_empty() and absf(hit.position.y) < 0.1,
		"the roof deck extends to %.0f m (was %.0f): you can stand at its new edge" % [Level.ROOF_HALF * 2, Level.HALF * 2])
	print("Ledger:")
	s.held_by = PackedInt32Array()
	s.stun_left = 5.0
	s.global_position = Vector3(9.5, 1.0, 9.5)
	await _wait(0.3)
	_check(credits == 40 and delivered == 1, "pen turns it into $40 in the ledger (credits=%d)" % credits)
	_check(not is_instance_valid(s) or s.is_queued_for_deletion(), "the physics object is gone after delivery")
	_check(respawn_queue.size() == 1, "a replacement skitter is queued")
	print("Intro cinematic:")
	var intro := play_intro()
	var crater := get_tree().get_nodes_in_group("crater")
	_check(crater.size() > 4 and crater.all(func(n): return not n.visible), "crater and rubble are hidden before the impact")
	intro.advance(Intro.IMPACT - 0.1)
	_check(not intro.impacted and intro.asteroid.global_position.y > Level.CRATER_POS.y,
		"asteroid is still falling just before impact")
	intro.advance(0.2)
	_check(intro.impacted and crater.all(func(n): return n.visible) and not intro.asteroid.visible,
		"on impact the asteroid vanishes and the crater appears")
	_check(hud.flash_rect.color.a > 0.5, "the screen flashes on impact")
	intro.advance(Intro.SWARM_START + 1.0)
	_check(intro.mother.visible and intro.mother.global_position.y > Level.GROUND_Y,
		"the giant has risen out of the crater")
	_check(intro.swarm.any(func(c): return c.node.visible), "the pack is pouring out of the crater")
	var climbing := false
	for step in 40:
		intro.advance(0.25)
		for c in intro.swarm:
			var n: Node3D = c.node
			if n.visible and n.global_position.y > Level.GROUND_Y + 4.0 and \
					(absf(n.global_position.x) > Level.HALF or absf(n.global_position.z) > Level.HALF):
				climbing = true
	_check(climbing, "aliens reach our building and climb its walls")
	intro.advance(Intro.END)
	_check(intro.swarm.all(func(c): return not c.node.visible) or intro.is_queued_for_deletion(),
		"every alien has gone inside by the end")
	_check(intro.is_queued_for_deletion() and p.cam.h_offset == 0.0, "intro cleans up and stops the screen shake")
	print("SELFTEST: %s" % ("PASS" if test_failures == 0 else "%d FAILED" % test_failures))
	get_tree().quit(0 if test_failures == 0 else 1)


func _shot() -> void:
	host()
	var dir := OS.get_environment("SHOT_DIR")
	if dir == "":
		dir = "user://"
	var views := [
		[Vector3(-2, 0.05, 2), atan2(-95.0, 70.0), -0.05],
		[Vector3(-13, 0.05, -13), PI, -0.45],
		[Vector3(-12, -5.95, 11), -PI / 2, -0.1],
	]
	var p := local_player()
	var i := 0
	for wait in [2.8, 1.25, 0.3, 1.0, 2.0, 2.5, 3.0, 2.0]:   # mid-fall, the impact flash, then once the intro settles
		await _wait(wait)
		get_viewport().get_texture().get_image().save_png("%s/intro%d.png" % [dir, i])
		i += 1
	await _wait(0.4)
	get_viewport().get_texture().get_image().save_png("%s/intro%d.png" % [dir, i])
	await _wait(6.0)
	i = 0
	for v in views:
		p.global_position = v[0]
		p.velocity = Vector3.ZERO
		p.rotation.y = v[1]
		p.head.rotation.x = v[2]
		await _wait(0.6)
		get_viewport().get_texture().get_image().save_png("%s/shot%d.png" % [dir, i])
		i += 1
	for sp in ["skitter", "brute"]:
		for s in specimens():
			if s.species == sp:
				s.stun_left = 3.0
				_place_near(p, s)
				p.global_position.x += 1.0
				p.head.rotation.x = -0.35
				break
		await _wait(0.6)
		get_viewport().get_texture().get_image().save_png("%s/shot%d.png" % [dir, i])
		i += 1
	get_tree().quit(0)
