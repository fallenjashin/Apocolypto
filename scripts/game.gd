class_name Game
extends Node3D
## Game root: networking, spawning, the specimen ledger, and the test modes.
##
## Loot-as-data rule: a specimen is a physics object only while it's out in the
## building. Once it reaches the pen it is deleted and becomes a ledger entry
## (credits + count). Nothing piles up, nothing desyncs, nothing lags.

const PORT := 7777
const MAX_PLAYERS := 4
const POPULATION := {"skitter": 4, "brute": 2, "glimmer": 1}
const RESPAWN_DELAY := 20.0
const DEPTH_NAMES := ["ROOF (camp)", "DEPTH 1: Skitters", "DEPTH 2: Brutes", "DEPTH 3: Glimmers"]

# The run: DAYS days. Each day you must earn that day's quota before the clock runs out.
# Surplus earnings stay in the bank (to be spent in the store); the quota resets every day.
const DAYS := 4
const QUOTAS := [300, 500, 750, 1000]
const DAY_SECONDS := 300.0
const BRIEFING_SECONDS := 6.0
const FIRST_BRIEFING_SECONDS := 16.0   # day 1 waits for the opening cinematic
const SUMMARY_SECONDS := 12.0
enum Phase { BRIEFING, PLAYING, SUMMARY, WON, LOST }

var players_root: Node3D
var specimens_root: Node3D
var player_spawner: MultiplayerSpawner
var specimen_spawner: MultiplayerSpawner
var hud: Hud
var in_game := false
var credits := 0          # the bank: spendable
var earned_today := 0     # counts toward today's quota
var delivered := 0
var day := 1
var phase := Phase.BRIEFING
var phase_t := 0.0        # seconds left in a BRIEFING or SUMMARY
var time_left := 0.0      # seconds left on the day's clock
var clock_sync_t := 0.0
var upgrades := {}        # store upgrades, crew-wide: {"battery": 1, ...}
var daylight_bought := 0  # Floodlights bought today
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
	hud.run_changed("")
	var args := OS.get_cmdline_user_args()
	for a in ["--autotest-host", "--autotest-join", "--selftest", "--shot", "--shot-hud"]:
		if a in args:
			test_mode = a
	match test_mode:
		"--autotest-host": _autotest_host()
		"--autotest-join": _autotest_join()
		"--selftest": _selftest()
		"--shot": _shot()
		"--shot-hud": _shot_hud()


func _make_spawner(n: String, path: String, fn: Callable) -> MultiplayerSpawner:
	var s := MultiplayerSpawner.new()
	s.name = n
	add_child(s)
	s.spawn_path = NodePath(path)
	s.spawn_function = fn
	return s


func _setup_input() -> void:
	var keys := {"fwd": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D,
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "menu": KEY_ESCAPE, "restart": KEY_R,
		"shop": KEY_B}
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
	if not InputMap.has_action("grab"):
		InputMap.add_action("grab")
		var rb := InputEventMouseButton.new()
		rb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("grab", rb)


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
	new_run(FIRST_BRIEFING_SECONDS)


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
		set_run_state.rpc_id(id, _state_dict(), "You joined the crew.")


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
	p.position = roof_spawn(id)
	return p


func roof_spawn(id: int) -> Vector3:
	return Vector3(16.5 - (id % 4) * 1.3, 0.2, -16.6)   # at the NE railing, facing the crater


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
	return clampf(1.0 / (1.0 + m / (35.0 * s.held_by.size() * Shop.carry_strength(upgrades))), 0.35, 1.0)


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
	s.stun_left = float(s.spec.stun) * Shop.stun_mult(upgrades)
	s.on_stunned(p.peer_id)


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


# --- The run: days, quotas, win and lose -------------------------------------

static func quota_for(d: int) -> int:
	return QUOTAS[clampi(d - 1, 0, QUOTAS.size() - 1)]


func quota() -> int:
	return quota_for(day)


static func fmt_clock(sec: float) -> String:
	var t := maxi(0, ceili(sec))
	return "%d:%02d" % [t / 60, t % 60]


## Server only. Starts a brand-new run (day 1, empty bank).
func new_run(briefing := BRIEFING_SECONDS) -> void:
	day = 1
	credits = 0
	delivered = 0
	upgrades = {}
	_begin_day(briefing)


## Server only. Resets the building for a new day: fresh specimens, crew back on the roof.
func _begin_day(briefing: float) -> void:
	phase = Phase.BRIEFING
	phase_t = briefing
	time_left = DAY_SECONDS
	earned_today = 0
	daylight_bought = 0
	for s in specimens():
		s.queue_free()
	respawn_queue.clear()
	for sp in POPULATION:
		for i in POPULATION[sp]:
			spawn_specimen(sp)
	reset_players.rpc()
	_broadcast("Day %d of %d. Quota: $%d." % [day, DAYS, quota()])


## Runs on every peer: each one moves its own player back to camp.
@rpc("authority", "call_local", "reliable")
func reset_players() -> void:
	var p := local_player()
	if p:
		p.reset_for_day()


func _state_dict() -> Dictionary:
	return {"day": day, "phase": int(phase), "phase_t": phase_t, "time_left": time_left,
		"earned": earned_today, "bank": credits, "delivered": delivered,
		"upgrades": upgrades, "daylight": daylight_bought}


@rpc("authority", "call_local", "reliable")
func set_run_state(st: Dictionary, msg: String) -> void:
	day = st.day
	phase = st.phase
	phase_t = st.phase_t
	time_left = st.time_left
	earned_today = st.earned
	credits = st.bank
	delivered = st.delivered
	upgrades = st.upgrades.duplicate()
	daylight_bought = st.daylight
	hud.run_changed(msg)


## Small, frequent clock corrections. Clients count down on their own in between.
@rpc("authority", "unreliable_ordered")
func net_clock(pt: float, tl: float) -> void:
	phase_t = pt
	time_left = tl


func _broadcast(msg: String) -> void:
	set_run_state.rpc(_state_dict(), msg)


## Server only: advances the phases. Split out so tests can fast-forward it.
func tick_run(dt: float) -> void:
	match phase:
		Phase.BRIEFING:
			phase_t -= dt
			if phase_t <= 0.0:
				phase = Phase.PLAYING
				phase_t = 0.0
				_broadcast("The clock is running. Earn $%d before it hits zero." % quota())
		Phase.PLAYING:
			time_left -= dt
			if time_left <= 0.0:
				_end_day()
		Phase.SUMMARY:
			phase_t -= dt
			if phase_t <= 0.0:
				day += 1
				_begin_day(BRIEFING_SECONDS)


func _end_day() -> void:
	time_left = 0.0
	if earned_today < quota():
		phase = Phase.LOST
		_broadcast("OVERRUN. You missed the day %d quota." % day)
	elif day >= DAYS:
		phase = Phase.WON
		_broadcast("You made it. Every quota met.")
	else:
		phase = Phase.SUMMARY
		phase_t = SUMMARY_SECONDS
		_broadcast("Day %d complete. Quota met." % day)


# --- The store ---------------------------------------------------------------

func level_of(id: String) -> int:
	return daylight_bought if id == "daylight" else Shop.level_of(upgrades, id)


## Why `id` can't be bought right now ("" means it can). Shared by the server's
## check and the buttons in the store, so they always agree.
func buy_problem(id: String) -> String:
	if phase == Phase.WON or phase == Phase.LOST:
		return "The run is over."
	var lvl := level_of(id)
	if lvl >= Shop.max_level(id):
		return "%s: already maxed out." % Shop.ITEMS[id].title
	if id == "daylight" and phase != Phase.PLAYING:
		return "Floodlights only help while the clock is running."
	var price := Shop.cost(id, lvl)
	if credits < price:
		return "Not enough in the bank: %s costs $%d." % [Shop.ITEMS[id].title, price]
	return ""


@rpc("any_peer", "call_local", "reliable")
func request_buy(id: String) -> void:
	if not multiplayer.is_server() or not Shop.ITEMS.has(id):
		return
	var buyer := _sender()
	var p := get_player(buyer)
	var problem := ""
	if p == null or Level.floor_of(p.global_position.y) != 0:
		problem = "The store is on the roof."
	else:
		problem = buy_problem(id)
	if problem != "":
		notify.rpc_id(buyer, problem)
		return
	var lvl := level_of(id)
	credits -= Shop.cost(id, lvl)
	if id == "daylight":
		daylight_bought += 1
		time_left += Shop.DAYLIGHT_SECONDS
	else:
		upgrades[id] = lvl + 1
	_broadcast("%s bought %s%s." % [p.tag.text, Shop.ITEMS[id].title, "" if id == "daylight" else " (level %d)" % (lvl + 1)])


## A specimen shoved a player (Territorial slam). Only that player's own machine applies it.
@rpc("authority", "call_local", "reliable")
func shove(id: int, push: Vector3) -> void:
	var p := local_player()
	if p and p.peer_id == id:
		p.knock = Vector3(push.x, 0, push.z)
		p.velocity.y = 4.0
		p.release()


## A volatile specimen blew up. The loot is gone and comes back later like a delivered one.
func specimen_exploded(s: Specimen) -> void:
	respawn_queue.append([RESPAWN_DELAY, s.species])
	boom_fx.rpc(s.global_position)
	var lost: int = s.spec.value
	s.queue_free()
	_broadcast("A %s exploded! $%d of loot lost." % [s.spec.label, lost])


@rpc("authority", "call_local", "reliable")
func boom_fx(pos: Vector3) -> void:
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	var mat := Level.mat(Color(1.0, 0.85, 0.4, 0.8), 5.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.material = mat
	ball.mesh = sm
	add_child(ball)
	ball.global_position = pos
	ball.scale = Vector3.ONE * 0.5
	var tw := ball.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ball, "scale", Vector3.ONE * Specimen.BOOM_RADIUS, 0.35)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.chain().tween_callback(ball.queue_free)
	var snd := AudioStreamPlayer3D.new()
	snd.stream = Intro._noise_sound(1.2, false)
	snd.unit_size = 14.0
	add_child(snd)
	snd.global_position = pos
	snd.finished.connect(snd.queue_free)
	snd.play()


## A private message for one player (like a refused purchase).
@rpc("authority", "call_local", "reliable")
func notify(msg: String) -> void:
	hud.toast(msg)


func toggle_shop() -> void:
	if hud.shop_open:
		close_shop()
		return
	var p := local_player()
	if p == null or Level.floor_of(p.global_position.y) != 0:
		hud.toast("The store is up on the roof. Bring your catch up first.")
		return
	if phase == Phase.WON or phase == Phase.LOST:
		return
	hud.open_shop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_shop() -> void:
	hud.close_shop()
	capture_mouse()


@rpc("any_peer", "call_local", "reliable")
func request_restart() -> void:
	if not multiplayer.is_server() or _sender() != 1:
		return   # only the host restarts
	if phase != Phase.WON and phase != Phase.LOST:
		return
	new_run()


func _unhandled_input(event: InputEvent) -> void:
	if in_game and event.is_action_pressed("restart") and (phase == Phase.WON or phase == Phase.LOST):
		request_restart.rpc_id(1)


# --- Server loop: clock, deliveries and respawns -----------------------------

func _process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return
	# Clients keep their own copy of the clock ticking between the server's corrections.
	if phase == Phase.PLAYING:
		time_left = maxf(0.0, time_left - delta)
	elif phase == Phase.BRIEFING or phase == Phase.SUMMARY:
		phase_t = maxf(0.0, phase_t - delta)


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	tick_run(delta)
	clock_sync_t += delta
	if clock_sync_t >= 0.5:
		clock_sync_t = 0.0
		net_clock.rpc(phase_t, time_left)
	var run_over := phase == Phase.WON or phase == Phase.LOST
	for s in specimens():
		if Level.in_pen(s.global_position):
			if not run_over:
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
	earned_today += value
	delivered += 1
	respawn_queue.append([RESPAWN_DELAY, s.species])
	s.queue_free()
	var msg := "%s delivered to the military: +$%d" % [s.spec.label, value]
	if earned_today >= quota() and earned_today - value < quota():
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
	await _wait(1.0)
	credits = 500
	request_buy.rpc_id(1, "battery")   # the host buys from the roof; the client must see it
	print("[host] bought a Prod Battery, bank = %d" % credits)
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
	if day != 1 or quota() != QUOTAS[0] or earned_today != credits or phase_t > FIRST_BRIEFING_SECONDS:
		print("AUTOTEST JOIN: FAIL (run state did not sync: day %d, quota $%d, earned %d, bank %d)" % [
			day, quota(), earned_today, credits])
		get_tree().quit(1)
		return
	print("[join] run state synced: day %d of %d, quota $%d, earned today $%d" % [day, DAYS, quota(), earned_today])
	while level_of("battery") < 1:
		await get_tree().process_frame
	if credits != 500 - Shop.cost("battery", 0):
		print("AUTOTEST JOIN: FAIL (store purchase synced with the wrong bank: %d)" % credits)
		get_tree().quit(1)
		return
	print("[join] store purchase synced: Prod Battery level %d, bank $%d" % [level_of("battery"), credits])
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
	print("Run structure:")
	var total := 0
	for sp in POPULATION:
		total += POPULATION[sp]
	_check(earned_today == 40, "a delivery also counts toward today's quota (earned_today=%d)" % earned_today)
	var qs := [quota_for(1), quota_for(2), quota_for(3), quota_for(4)]
	_check(qs == QUOTAS and qs[0] < qs[1] and qs[1] < qs[2] and qs[2] < qs[3], "quotas rise every day %s" % str(qs))
	new_run(0.1)
	_check(day == 1 and phase == Phase.BRIEFING and credits == 0 and earned_today == 0 and delivered == 0,
		"a new run starts at day 1 with an empty bank")
	_check(specimens().size() == total, "the building is fully stocked (%d specimens)" % specimens().size())
	tick_run(0.2)
	_check(phase == Phase.PLAYING and time_left == DAY_SECONDS, "after the briefing the clock starts at %s" % fmt_clock(DAY_SECONDS))
	tick_run(10.0)
	_check(is_equal_approx(time_left, DAY_SECONDS - 10.0), "the clock counts down")
	earned_today = quota() - 1
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.LOST, "one dollar short of the quota at the buzzer: overrun")
	specimen_spawner.spawn(["T2", "skitter", Vector3(9.5, 1.0, 9.5)])
	var bank_before := credits
	await _wait(0.3)
	var t2 := specimens_root.get_node_or_null("T2")
	_check(credits == bank_before and t2 != null and not t2.is_queued_for_deletion(), "no payouts once the run is over")
	request_restart.rpc_id(1)
	await get_tree().physics_frame
	_check(day == 1 and phase == Phase.BRIEFING and credits == 0 and specimens().size() == total,
		"the host can restart a finished run")
	phase = Phase.PLAYING
	earned_today = quota()
	credits = 340
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.SUMMARY and day == 1, "quota met: the day ends with a summary")
	p.global_position = Vector3(0, Level.level_y(2) + 0.05, 0)   # the crew is still down in the building
	p.charges = 0
	tick_run(SUMMARY_SECONDS + 0.1)
	_check(day == 2 and phase == Phase.BRIEFING and earned_today == 0 and quota() == QUOTAS[1],
		"day 2 starts fresh with a bigger quota ($%d)" % quota())
	_check(credits == 340, "the bank carries over between days")
	_check(specimens().size() == total, "the building is restocked for the new day")
	_check(Level.floor_of(p.global_position.y) == 0 and p.charges == p.max_charges(),
		"the crew is back on the roof with full prods")
	day = DAYS
	phase = Phase.PLAYING
	earned_today = quota()
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.WON, "meeting the final quota wins the run")
	net_clock(5.0, 77.0)
	_check(phase_t == 5.0 and time_left == 77.0, "clock corrections from the host are applied")
	print("Specimen tempers:")
	new_run(0.1)
	tick_run(0.2)
	p.global_position = Vector3(0, 0.2, 0)
	p.rotation = Vector3.ZERO
	p.head.rotation = Vector3.ZERO
	_check(Specimen.skittish_radius(1) < Specimen.skittish_radius(2), "Skittish: a lone player can get closer than a group can")
	_check(not Specimen.shy_frozen(1) and Specimen.shy_frozen(2), "Shy: one watcher isn't enough, two freeze it")
	var skit := specimen_spawner.spawn(["K1", "skitter", Vector3(0, 0.5, 3.0)]) as Specimen
	await get_tree().physics_frame
	_check(skit._plan_skittish().x != INF and skit._plan_skittish().z > 0.0, "Skittish: one player at 3m still makes it run (directly away)")
	skit.global_position = Vector3(0, 0.5, 6.5)
	_check(skit._plan_skittish().x == INF, "Skittish: one player at 6.5m does not scare it (you can walk up alone)")
	var p2 := player_spawner.spawn([2]) as Player
	p2.global_position = Vector3(2, 0.2, 0)
	await get_tree().physics_frame
	_check(skit._plan_skittish().x != INF, "Skittish: with two players at 6.5m it bolts")
	p2.queue_free()
	await get_tree().physics_frame
	skit.queue_free()
	var bru := specimen_spawner.spawn(["K2", "brute", Vector3(0, 0.7, 2.0)]) as Specimen
	await get_tree().physics_frame
	_check(bru._plan_territorial(0.1).x == INF and bru.provoked_by == 0, "Territorial: ignores a player standing right next to it")
	request_stun.rpc_id(1, "K2")
	_check(bru.provoked_by == 1, "Territorial: the player who stunned it becomes its target")
	bru.stun_left = 0.0
	bru.global_position = Vector3(0, 0.7, 8.0)
	var charge := bru._plan_territorial(0.1)
	_check(charge.z < 0.0 and bru.mood == 1, "Territorial: once awake it charges at the stunner (enraged)")
	_check(charge.length() > float(Specimen.SPECIES.brute.speed), "Territorial: it charges faster than it normally walks")
	_check(charge.length() < Player.WALK, "Territorial: but a walking player can still outrun a charge (%.1f vs %.1f)" % [charge.length(), Player.WALK])
	bru.global_position = Vector3(0, 0.7, 1.0)
	bru._plan_territorial(0.1)
	_check(p.knock.length() > 1.0 and bru.provoked_by == 0, "Territorial: it slams the stunner on contact, then calms down")
	p.knock = Vector3.ZERO
	bru.queue_free()
	var gl := specimen_spawner.spawn(["K3", "glimmer", Vector3(0, 1.8, -6.0)]) as Specimen
	await get_tree().physics_frame
	_check(gl.watchers() == 1, "Shy: a player looking straight at it counts as one watcher")
	_check(gl._plan_shy().x != INF and gl._plan_shy().length() > 1.0 and gl.mood == 0, "Shy: with one watcher it still runs away")
	p2 = player_spawner.spawn([2]) as Player
	p2.global_position = Vector3(1, 0.2, 0)
	p2.rotation = Vector3.ZERO
	p2.head.rotation = Vector3.ZERO
	await get_tree().physics_frame
	_check(gl.watchers() == 2, "Shy: two players looking at it are two watchers")
	_check(gl._plan_shy() == Vector3.ZERO and gl.mood == 2, "Shy: two watchers freeze it solid")
	p.head.rotation.y = PI
	_check(gl.watchers() == 1 and gl._plan_shy().length() > 1.0, "Shy: one watcher looks away and it runs again")
	p.head.rotation = Vector3.ZERO
	p2.queue_free()
	gl.queue_free()
	await get_tree().physics_frame
	print("Glimmer chase, explosion, and homing:")
	p.global_position = Vector3(13.0, 0.2, 0.0)
	var runner := specimen_spawner.spawn(["K6", "glimmer", Vector3(16.5, 0.5, 0.0)]) as Specimen
	await get_tree().physics_frame
	await get_tree().physics_frame
	var heading := runner.open_heading(Vector3.RIGHT)
	_check(heading.x < 0.5 and heading.length() > 0.99, "a fleeing specimen with a roof edge right ahead turns along it (heading x = %.2f, not 1.0)" % heading.x)
	_check(float(Specimen.SPECIES.glimmer.speed) > Player.SPRINT * 1.2, "the Glimmer is faster than a sprint (%.0f vs %.0f)" % [Specimen.SPECIES.glimmer.speed, Player.SPRINT])
	runner.queue_free()
	p.global_position = Vector3(0, 0.2, 0)
	var gb := specimen_spawner.spawn(["K4", "glimmer", Vector3(0, 1.0, 2.0)]) as Specimen
	await get_tree().physics_frame
	gb._server_tick(0.1)
	_check(gb.fuse_t == 0.0, "a Glimmer that hasn't been stunned has no fuse")
	gb.stun_left = 0.05
	gb._server_tick(0.1)
	_check(is_equal_approx(gb.fuse_t, Specimen.FUSE_TIME), "when its stun wears off the %.0fs fuse starts" % Specimen.FUSE_TIME)
	gb.on_stunned(1)
	_check(gb.fuse_t == 0.0, "stunning it again defuses it")
	gb.stun_left = 0.05
	gb._server_tick(0.1)
	var queued := respawn_queue.size()
	p.knock = Vector3.ZERO
	gb._server_tick(Specimen.FUSE_TIME + 0.1)
	_check(gb.is_queued_for_deletion(), "left alone, it explodes and the loot is gone")
	_check(respawn_queue.size() == queued + 1, "a replacement Glimmer is queued")
	_check(p.knock.length() > 1.0, "the blast throws nearby players back (knock %.1f)" % p.knock.length())
	p.knock = Vector3.ZERO
	var hs := specimen_spawner.spawn(["K5", "skitter", Vector3(0, Level.level_y(1) + 1.0, 3.0)]) as Specimen
	await get_tree().physics_frame
	hs.global_position = hs.home + Vector3(12, 0, 0)
	_check(hs.homesick() and hs._wander_plan(0.1).x < 0.0, "a specimen far from its spawn spot walks back toward it")
	hs.global_position = hs.home + Vector3(3, 0, 0)
	_check(not hs.homesick(), "close to home it wanders freely")
	hs.global_position = Vector3(12, Level.level_y(2) + 1.0, 3)
	_check(not hs.homesick(), "on a different floor from home it just wanders (no cross-floor pathing yet)")
	hs.queue_free()
	await get_tree().physics_frame
	print("Store:")
	var sane := Shop.ORDER.size() == Shop.ITEMS.size()
	for id in Shop.ORDER:
		var prev := 0
		for c in Shop.ITEMS[id].costs:
			if c <= 0 or c < prev:
				sane = false
			prev = c
	_check(sane, "every store item has positive, non-decreasing prices")
	new_run(0.1)
	tick_run(0.2)
	_check(upgrades.is_empty() and phase == Phase.PLAYING, "a new run starts with no upgrades")
	p.global_position = Vector3(0, Level.level_y(1) + 0.05, 0)
	credits = 1000
	request_buy.rpc_id(1, "coils")
	_check(credits == 1000 and level_of("coils") == 0, "the store refuses you when you're down in the building")
	p.global_position = roof_spawn(1)
	request_buy.rpc_id(1, "battery")
	_check(credits == 1000 - Shop.cost("battery", 0) and level_of("battery") == 1, "buying a Prod Battery costs $%d" % Shop.cost("battery", 0))
	_check(p.max_charges() == Player.MAX_CHARGES + 2, "it adds 2 prod charges (now %d)" % p.max_charges())
	credits = 100
	request_buy.rpc_id(1, "battery")
	_check(credits == 100 and level_of("battery") == 1, "you can't buy what you can't afford")
	credits = 5000
	request_buy.rpc_id(1, "battery")
	request_buy.rpc_id(1, "battery")
	var bank_at_max := credits
	request_buy.rpc_id(1, "battery")
	_check(level_of("battery") == Shop.max_level("battery") and credits == bank_at_max, "upgrades stop at their maximum level")
	_check(buy_problem("battery") != "" and buy_problem("harness") == "", "the store buttons use the same rule as the host")
	request_buy.rpc_id(1, "coils")
	var rock := specimen_spawner.spawn(["T3", "skitter", p.get_hold_point()]) as Specimen
	await get_tree().physics_frame
	request_stun.rpc_id(1, "T3")
	_check(is_equal_approx(rock.stun_left, float(Specimen.SPECIES.skitter.stun) * 1.3), "Stun Coils lengthen the stun (%.1fs instead of %.1fs)" % [
		rock.stun_left, float(Specimen.SPECIES.skitter.stun)])
	rock.queue_free()
	var heavy := specimen_spawner.spawn(["T4", "brute", p.get_hold_point()]) as Specimen
	await get_tree().physics_frame
	heavy.held_by = PackedInt32Array([1])
	var slow := carry_speed_factor(1)
	request_buy.rpc_id(1, "harness")
	request_buy.rpc_id(1, "harness")
	_check(carry_speed_factor(1) > slow, "the Carry Harness makes a Brute easier to haul (speed x%.2f -> x%.2f)" % [slow, carry_speed_factor(1)])
	heavy.queue_free()
	_check(is_equal_approx(Shop.sprint_mult({"boots": 1}), 1.12), "Sprint Boots add 12% per level")
	p.charges = 0
	var battery_level := level_of("battery")
	earned_today = quota()
	time_left = 0.1
	tick_run(0.2)
	tick_run(SUMMARY_SECONDS + 0.1)
	_check(day == 2 and level_of("battery") == battery_level and p.charges == p.max_charges(),
		"upgrades carry into the next day and the prod comes back fully charged (%d)" % p.max_charges())
	credits = 1000
	request_buy.rpc_id(1, "daylight")
	_check(daylight_bought == 0 and credits == 1000, "Floodlights can't be bought while the clock isn't running")
	tick_run(BRIEFING_SECONDS + 0.1)
	var clock_before := time_left
	request_buy.rpc_id(1, "daylight")
	_check(is_equal_approx(time_left, clock_before + Shop.DAYLIGHT_SECONDS) and daylight_bought == 1,
		"Floodlights add %d seconds to the clock" % int(Shop.DAYLIGHT_SECONDS))
	request_buy.rpc_id(1, "daylight")
	var capped := credits
	request_buy.rpc_id(1, "daylight")
	_check(daylight_bought == 2 and credits == capped, "Floodlights are limited to twice a day")
	earned_today = quota()
	time_left = 0.1
	tick_run(0.2)
	tick_run(SUMMARY_SECONDS + 0.1)
	_check(day == 3 and daylight_bought == 0, "the daily Floodlight limit resets each day")
	new_run()
	_check(upgrades.is_empty(), "a new run clears every upgrade")
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


## Screenshots of the HUD in each phase of a run (for checking the layout).
func _shot_hud() -> void:
	host()
	var dir := OS.get_environment("SHOT_DIR")
	var p := local_player()
	p.global_position = Vector3(-2, 0.05, 2)
	p.rotation.y = atan2(-95.0, 70.0)
	p.head.rotation.x = -0.05
	var states := [
		["hud0", Phase.BRIEFING, {"day": 2, "earned": 0, "credits": 340, "phase_t": 5.0, "time_left": 300.0}],
		["hud1", Phase.PLAYING, {"day": 2, "earned": 210, "credits": 550, "phase_t": 0.0, "time_left": 142.0}],
		["hud2", Phase.PLAYING, {"day": 2, "earned": 380, "credits": 720, "phase_t": 0.0, "time_left": 18.0}],
		["hud3", Phase.SUMMARY, {"day": 2, "earned": 540, "credits": 880, "phase_t": 9.0, "time_left": 0.0}],
		["hud4", Phase.LOST, {"day": 3, "earned": 610, "credits": 910, "phase_t": 0.0, "time_left": 0.0}],
		["hud5", Phase.WON, {"day": 4, "earned": 1040, "credits": 1500, "phase_t": 0.0, "time_left": 0.0}],
	]
	for st in states:
		hud.close_shop()
		phase = st[1]
		day = st[2].day
		earned_today = st[2].earned
		credits = st[2].credits
		phase_t = st[2].phase_t
		time_left = st[2].time_left
		await _wait(0.5)
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, st[0]])
	phase = Phase.PLAYING
	day = 2
	earned_today = 210
	credits = 400
	time_left = 120.0
	upgrades = {"battery": 1, "boots": 2}
	daylight_bought = 1
	hud.open_shop()
	await _wait(0.5)
	get_viewport().get_texture().get_image().save_png("%s/store.png" % dir)
	get_tree().quit(0)


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
