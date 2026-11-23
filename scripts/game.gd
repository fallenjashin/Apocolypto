class_name Game
extends Node3D
## Game root: networking, spawning, the specimen ledger, and the test modes.
##
## Loot-as-data rule: a specimen is a physics object only while it's out in the
## building. Once it reaches the pen it is deleted and becomes a ledger entry
## (credits + count). Nothing piles up, nothing desyncs, nothing lags.

const PORT := 7777
const MAX_PLAYERS := 4
const RESPAWN_DELAY := 20.0

# The run: DAYS days. Each day you must earn that day's quota before the clock runs out.
# Surplus earnings stay in the bank (to be spent in the store); the quota resets every day.
const DAYS := 4
const QUOTAS := [300, 500, 750, 1000]
const DAY_SECONDS := 480.0   # one day, dawn (6 AM) to midnight, in real seconds
const MAX_HP := 100.0
const DEATH_CUT := 0.20          # each death costs this share of the bank at the end of the day
const ROOF_HEAL := 8.0           # health per second while on the roof
const CAB_HEAL := 4.0            # ...and while shut in an elevator
const DOOR_FORCE_SECONDS := 6.0  # a hunter pounding on closed doors this long tears them open
const DOOR_LOCK_SECONDS := 5.0   # after that the doors are jammed open for this long
const STALKER_INTERVAL := 4.0
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
var world_node: Node3D
var active_floor := -1        # which expedition floor exists right now (-1 = none)
var floor_seed := 0
var floor_info := {}          # what Floors.build returned for the active floor
var floor_runs := 0           # how many floors have been opened (makes each maze different)
var doors := [false, false]   # elevator doors closed? [roof, floor]
var hp := {}                  # peer id -> health. The host is the truth; others get copies
var dead := {}                # peer id -> true once killed (until the next day)
var deaths_today := 0         # host only
var door_lock := 0.0          # host only
var door_bash := 0.0          # host only
var stalker_t := 0.0          # host only
var lost_reason := ""         # why the run ended (shown on the loss screen)
var day_note := ""            # extra line for the day summary (deaths and the bank cut)
var test_mode := ""
var test_failures := 0


func _ready() -> void:
	_setup_input()
	Level.build(self)
	world_node = get_node("World")
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
		"shop": KEY_B, "interact": KEY_E}
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


## Server only. Puts one specimen on the active floor, on a random open cell away from
## the crew. Does nothing when no floor is open.
func spawn_specimen(sp: String, min_player_dist := 12.0) -> void:
	if active_floor < 0 or floor_info.is_empty():
		return
	var cells: Array = floor_info.cells
	var pos: Vector3 = cells.pick_random()
	for attempt in 12:
		var clear := true
		for s in specimens():
			if s.global_position.distance_to(pos) < 2.0:
				clear = false
		for c in players_root.get_children():
			if (c as Node3D).global_position.distance_to(pos) < min_player_dist:
				clear = false
		if clear:
			break
		pos = cells.pick_random()
	pos += Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
	next_spec_id += 1
	specimen_spawner.spawn(["S%d" % next_spec_id, sp, pos])


# --- The elevator and the floors ---------------------------------------------

func cab_of(pos: Vector3) -> int:
	if Floors.in_zone(Level.roof_cab, pos):
		return 0
	if Floors.in_zone(floor_info.get("cab", {}), pos):
		return 1
	return -1


func players_on_floor() -> int:
	var n := 0
	for c in players_root.get_children():
		if Level.floor_of((c as Node3D).global_position.y) != 0:
			n += 1
	return n


func location_name(p: Player) -> String:
	if Level.floor_of(p.global_position.y) == 0 or active_floor < 0:
		return "ROOF (camp)"
	return "FLOOR %d" % int(Floors.LIST[active_floor].number)


## Why `p` can't ride to `target` (-1 = the roof, 0.. = a floor) right now. "" means they can.
func travel_problem(p: Player, target: int) -> String:
	if phase != Phase.PLAYING:
		return "The elevator only runs while the day's clock is running."
	var where := cab_of(p.global_position)
	if where < 0:
		return "Stand inside the elevator first."
	if where == 0:
		if target < 0 or target >= Floors.LIST.size():
			return "Pick a floor."
		if active_floor >= 0 and active_floor != target and players_on_floor() > 0:
			return "The crew is down on floor %d. The elevator serves one floor at a time." % int(Floors.LIST[active_floor].number)
	elif target != -1:
		return "From a floor, the elevator only goes up to the roof."
	return ""


@rpc("any_peer", "call_local", "reliable")
func request_travel(target: int) -> void:
	if not multiplayer.is_server():
		return
	var id := _sender()
	var p := get_player(id)
	if p == null or is_dead(id):
		return
	var problem := travel_problem(p, target)
	if problem != "":
		notify.rpc_id(id, problem)
		return
	_travel(p, target)


## Server only. Rides everyone standing in the cab to the other end, plus any
## specimens in there with them (that is how you bring loot up).
func _travel(p: Player, target: int) -> void:
	var from_cab: Dictionary = Level.roof_cab if cab_of(p.global_position) == 0 else floor_info.cab
	var riders: Array[Player] = []
	for c in players_root.get_children():
		if Floors.in_zone(from_cab, (c as Node3D).global_position) and not is_dead((c as Player).peer_id):
			riders.append(c as Player)
	var cargo: Array[Specimen] = []
	for s in specimens():
		if Floors.in_zone(from_cab, s.global_position):
			cargo.append(s)
	if target >= 0 and active_floor != target:
		if active_floor >= 0:
			_deactivate_floor()
		_activate_floor(target)
	var to_cab: Dictionary = Level.roof_cab if target < 0 else floor_info.cab
	var src: Vector3 = from_cab.zone_c
	var dst: Vector3 = to_cab.zone_c
	for r in riders:
		var spot := dst + (r.global_position - src)
		spot.y = dst.y - 1.0 + 0.05
		teleport_player.rpc(r.peer_id, spot)
	for s in cargo:
		s.global_position = dst + (s.global_position - src)
		s.linear_velocity = Vector3.ZERO
	if target < 0 and players_on_floor() == 0:
		_deactivate_floor()
	if target >= 0:
		_broadcast("The crew rides down to floor %d." % int(Floors.LIST[target].number))
	else:
		_broadcast("The crew rides up to the roof.")


@rpc("authority", "call_local", "reliable")
func teleport_player(id: int, pos: Vector3) -> void:
	var p := local_player()
	if p and p.peer_id == id:
		p.global_position = pos
		p.velocity = Vector3.ZERO
		if hud.elevator_open:
			close_elevator()


## Server only: opens a floor, fills it with specimens in the floor's mix.
func _activate_floor(idx: int) -> void:
	floor_runs += 1
	var seed_v := hash([day, idx, floor_runs])
	set_active_floor.rpc(idx, seed_v)
	var counts := Floors.counts(idx)
	for sp in counts:
		for i in counts[sp]:
			spawn_specimen(sp)


## Server only: closes the floor. Anything still down there is lost, like loot left behind.
func _deactivate_floor() -> void:
	if active_floor < 0:
		return
	for s in specimens():
		if Level.floor_of(s.global_position.y) != 0:
			s.queue_free()
	respawn_queue.clear()
	set_active_floor.rpc(-1, 0)


@rpc("authority", "call_local", "reliable")
func set_active_floor(idx: int, seed_v: int) -> void:
	_build_floor(idx, seed_v)


## Runs on every peer: builds (or removes) the floor geometry from its seed.
func _build_floor(idx: int, seed_v: int) -> void:
	if floor_info.has("root") and is_instance_valid(floor_info.root):
		world_node.remove_child(floor_info.root)
		floor_info.root.queue_free()
	floor_info = {}
	active_floor = idx
	floor_seed = seed_v
	doors[1] = false
	if idx >= 0:
		floor_info = Floors.build(world_node, idx, seed_v)
	_apply_doors()


func _apply_doors() -> void:
	if Level.roof_cab.has("door"):
		Floors.set_door(Level.roof_cab.door, doors[0])
	if floor_info.has("cab"):
		Floors.set_door(floor_info.cab.door, doors[1])


@rpc("any_peer", "call_local", "reliable")
func request_doors(closed: bool) -> void:
	if not multiplayer.is_server():
		return
	var p := get_player(_sender())
	if p == null or is_dead(p.peer_id):
		return
	var where := cab_of(p.global_position)
	if where >= 0:
		if closed and where == 1 and door_lock > 0.0:
			notify.rpc_id(p.peer_id, "The doors are jammed for a few more seconds.")
			return
		set_door.rpc(where, closed)


@rpc("authority", "call_local", "reliable")
func set_door(where: int, closed: bool) -> void:
	doors[where] = closed
	_apply_doors()
	if hud.elevator_open:
		hud.refresh_elevator()


func toggle_elevator() -> void:
	if hud.elevator_open:
		close_elevator()
		return
	var p := local_player()
	if p == null or cab_of(p.global_position) < 0:
		hud.toast("Step inside the elevator and press E at its panel.")
		return
	if hud.shop_open:
		close_shop()
	hud.open_elevator()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_elevator() -> void:
	hud.close_elevator()
	capture_mouse()


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
	if s == null or p == null or is_dead(p.peer_id) or p.global_position.distance_to(s.global_position) > 5.0:
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
		if p == null or is_dead(id) or bool(s.spec.get("hostile", false)) or p.global_position.distance_to(s.global_position) > 5.0:
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
	hp.clear()
	dead.clear()
	deaths_today = 0
	door_lock = 0.0
	door_bash = 0.0
	stalker_t = 0.0
	lost_reason = ""
	day_note = ""
	for s in specimens():   # a new day: nothing left over, on the roof or below
		s.queue_free()
	_deactivate_floor()
	set_door.rpc(0, false)
	respawn_queue.clear()
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
		"upgrades": upgrades, "daylight": daylight_bought,
		"floor": active_floor, "fseed": floor_seed, "doors": doors,
		"hp": hp, "dead": dead, "lost": lost_reason, "note": day_note}


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
	if st.floor != active_floor or st.fseed != floor_seed:
		_build_floor(st.floor, st.fseed)
	doors = st.doors.duplicate()
	hp = st.hp.duplicate()
	dead = st.dead.duplicate()
	lost_reason = st.lost
	day_note = st.note
	_apply_doors()
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
			_tick_danger(dt)
			if time_left <= 0.0:
				_end_day()
		Phase.SUMMARY:
			phase_t -= dt
			if phase_t <= 0.0:
				day += 1
				_begin_day(BRIEFING_SECONDS)


## Midnight. Whoever is still down in the building doesn't make it. If at least one
## person got back to the roof alive, and the quota is met, the day counts, but the
## military docks the bank for every crew member lost.
func _end_day() -> void:
	time_left = 0.0
	var back: Array[Player] = []
	for p in alive_players():
		if Level.floor_of(p.global_position.y) == 0:
			back.append(p)
	if back.is_empty():
		_lose("Nobody made it back to the roof before midnight.")
		return
	for p in alive_players():
		if not back.has(p):
			kill_player(p.peer_id, "the night", false)
	if earned_today < quota():
		lost_reason = "You earned $%d of the $%d quota." % [earned_today, quota()]
		phase = Phase.LOST
		_broadcast("OVERRUN. You missed the day %d quota." % day)
		return
	day_note = ""
	if deaths_today > 0:
		var cut := mini(credits, roundi(credits * minf(1.0, DEATH_CUT * deaths_today)))
		credits -= cut
		day_note = "%d crew lost. The military docks $%d from the bank." % [deaths_today, cut]
	if day >= DAYS:
		phase = Phase.WON
		_broadcast("You made it. Every quota met. %s" % day_note)
	else:
		phase = Phase.SUMMARY
		phase_t = SUMMARY_SECONDS
		_broadcast("Day %d complete. Quota met. %s" % [day, day_note])


func _lose(reason: String) -> void:
	lost_reason = reason
	time_left = 0.0
	phase = Phase.LOST
	_broadcast(reason)


# --- Danger: health, death, hunters -----------------------------------------

func hp_of(id: int) -> float:
	return float(hp.get(id, MAX_HP))


func is_dead(id: int) -> bool:
	return bool(dead.get(id, false))


func alive_players() -> Array[Player]:
	var out: Array[Player] = []
	for c in players_root.get_children():
		var p := c as Player
		if p and not is_dead(p.peer_id):
			out.append(p)
	return out


func hunters() -> Array[Specimen]:
	var out: Array[Specimen] = []
	for s in specimens():
		if bool(s.spec.get("hostile", false)):
			out.append(s)
	return out


## How many hunters the floor should have by now: none in the morning, more as night
## falls, and more on the deeper floors.
static func stalker_target(progress: float, floor_idx: int) -> int:
	return mini(8, int(floor(smoothstep(0.35, 1.0, progress) * (2.0 + floor_idx))))


## Server only.
func damage_player(id: int, amount: float, source: String) -> void:
	if not multiplayer.is_server() or phase != Phase.PLAYING or is_dead(id) or get_player(id) == null:
		return
	hp[id] = maxf(0.0, hp_of(id) - amount)
	player_hurt.rpc(id, hp[id])
	if hp[id] <= 0.0:
		kill_player(id, source)


@rpc("authority", "call_local", "reliable")
func player_hurt(id: int, value: float) -> void:
	hp[id] = value
	var me := local_player()
	if me and me.peer_id == id:
		hud.hurt()


## Server only.
func kill_player(id: int, source: String, check_wipe := true) -> void:
	if is_dead(id):
		return
	deaths_today += 1
	var p := get_player(id)
	var who := p.tag.text if p else str(id)
	player_died.rpc(id, "%s was killed by %s." % [who, source])
	if check_wipe and alive_players().is_empty():
		_lose("The whole crew was lost.")


@rpc("authority", "call_local", "reliable")
func player_died(id: int, msg: String) -> void:
	dead[id] = true
	hp[id] = 0.0
	hud.toast(msg)
	var me := local_player()
	if me and me.peer_id == id:
		hud.hurt()
		if hud.shop_open:
			close_shop()
		if hud.elevator_open:
			close_elevator()


@rpc("authority", "unreliable_ordered")
func net_health(h: Dictionary) -> void:
	hp = h.duplicate()


## Server only, once per tick of the running day: healing, hunters arriving, doors being forced.
func _tick_danger(dt: float) -> void:
	door_lock = maxf(0.0, door_lock - dt)
	for p in alive_players():
		var cur := hp_of(p.peer_id)
		if cur >= MAX_HP:
			continue
		var rate := 0.0
		if Level.floor_of(p.global_position.y) == 0:
			rate = ROOF_HEAL
		elif doors[1] and Floors.in_zone(floor_info.get("cab", {}), p.global_position):
			rate = CAB_HEAL
		if rate > 0.0:
			hp[p.peer_id] = minf(MAX_HP, cur + rate * dt)
	if active_floor >= 0 and players_on_floor() > 0:
		stalker_t += dt
		if stalker_t >= STALKER_INTERVAL:
			stalker_t = 0.0
			if hunters().size() < stalker_target(day_progress(), active_floor):
				spawn_specimen("stalker", 18.0)
	if active_floor >= 0 and doors[1] and floor_info.has("cab"):
		var door_pos: Vector3 = floor_info.cab.door.global_position
		var pounding := false
		for h in hunters():
			if not h.is_stunned() and h.global_position.distance_to(door_pos) < 3.5:
				pounding = true
		door_bash = door_bash + dt if pounding else maxf(0.0, door_bash - dt)
		if door_bash >= DOOR_FORCE_SECONDS:
			door_bash = 0.0
			door_lock = DOOR_LOCK_SECONDS
			set_door.rpc(1, false)
			_broadcast("A Stalker tore the elevator doors open!")
	else:
		door_bash = 0.0


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
	if p == null or is_dead(buyer):
		return
	if Level.floor_of(p.global_position.y) != 0:
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
	_pulse_sphere(pos, Specimen.BOOM_RADIUS, Color(1.0, 0.85, 0.4, 0.8), 0.5)
	var snd := AudioStreamPlayer3D.new()
	snd.stream = Intro._noise_sound(1.2, false)
	snd.unit_size = 14.0
	add_child(snd)
	snd.global_position = pos
	snd.finished.connect(snd.queue_free)
	snd.play()


## A Glimmer teleported: a pale flash at both ends.
@rpc("authority", "call_local", "reliable")
func blink_fx(from: Vector3, to: Vector3) -> void:
	_pulse_sphere(from, 1.6, Color(0.6, 0.9, 1.0, 0.8), 0.35)
	_pulse_sphere(to, 1.6, Color(0.6, 0.9, 1.0, 0.8), 0.35)


func _pulse_sphere(pos: Vector3, radius: float, color: Color, secs: float) -> void:
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	var mat := Level.mat(color, 5.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.material = mat
	ball.mesh = sm
	add_child(ball)
	ball.global_position = pos
	ball.scale = Vector3.ONE * 0.3
	var tw := ball.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ball, "scale", Vector3.ONE * radius, secs * 0.7)
	tw.tween_property(mat, "albedo_color:a", 0.0, secs)
	tw.chain().tween_callback(ball.queue_free)


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
	if hud.elevator_open:
		close_elevator()
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

## How far through the day we are: 0 at dawn, 1 at midnight.
func day_progress() -> float:
	if not in_game:
		return 0.0
	return clampf(1.0 - time_left / DAY_SECONDS, 0.0, 1.0)


## 6:00 AM at progress 0 up to 12:00 AM at progress 1.
static func clock_text(progress: float) -> String:
	var minutes := roundi((6.0 + 18.0 * clampf(progress, 0.0, 1.0)) * 60.0)
	var h24 := (minutes / 60) % 24
	var h12 := h24 % 12
	if h12 == 0:
		h12 = 12
	return "%d:%02d %s" % [h12, minutes % 60, "AM" if h24 < 12 else "PM"]


## The sky and the floor lights follow the clock: the day gets darker and scarier.
func _update_light() -> void:
	var t := day_progress()
	Level.apply_time(t)
	if floor_info.has("lights"):
		var energy := Floors.light_energy(t)
		var col := Floors.light_color(active_floor, t)
		var late := smoothstep(0.7, 1.0, t)
		var now := Time.get_ticks_msec()
		var i := 0
		for l in floor_info.lights:
			var n := sin(now * 0.017 + i * 5.1) * sin(now * 0.0071 + i * 1.3)
			(l as OmniLight3D).light_energy = energy * (1.0 - 0.75 * late * smoothstep(0.5, 0.9, n))
			(l as OmniLight3D).light_color = col
			i += 1


func _process(delta: float) -> void:
	_update_light()
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
		net_health.rpc(hp)
	var run_over := phase == Phase.WON or phase == Phase.LOST
	for s in specimens():
		var hostile := bool(s.spec.get("hostile", false))
		if Level.in_pen(s.global_position) and not hostile:
			if not run_over:
				_deliver(s)
		elif Level.fell_out(s.global_position.y):
			if not hostile:
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
	p.global_position = Vector3(at.x + 1.4, Level.ground_y(at.y) + 0.05, at.z)
	p.velocity = Vector3.ZERO
	p.rotation.y = atan2(-(at.x - p.global_position.x), -(at.z - p.global_position.z))
	p.head.rotation.x = -0.5


func _autotest_host() -> void:
	_watchdog(40.0)
	host()
	_activate_floor(0)   # the crew "rode down" before the client joined: it must catch up on join
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
	var total: int = Floors.LIST[0].count
	while local_player() == null or specimens().size() < total or floor_info.is_empty():
		await get_tree().process_frame
	if active_floor != 0:
		print("AUTOTEST JOIN: FAIL (joined a crew on floor 0 but sees floor %d)" % active_floor)
		get_tree().quit(1)
		return
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
	print("Floor data:")
	var p := local_player()
	var data_ok := true
	var avgs: Array[float] = []
	for f in Floors.LIST.size():
		var d: Dictionary = Floors.LIST[f]
		var share := 0.0
		for sp in d.mix:
			share += float(d.mix[sp])
		var n := 0
		var cnt := Floors.counts(f)
		for sp in cnt:
			n += int(cnt[sp])
		if not is_equal_approx(share, 1.0) or n != int(d.count):
			data_ok = false
		avgs.append(Floors.average_value(f))
	_check(data_ok, "every floor's mix adds up to 100% and its specimen counts add up to its total")
	_check(Floors.counts(0) == {"skitter": 10, "brute": 3, "glimmer": 1}, "floor 10 (75/20/5) holds 10 skitters, 3 brutes, 1 glimmer")
	_check(Floors.counts(2) == {"skitter": 4, "brute": 4, "glimmer": 6}, "floor 8 (30/30/40) holds 4 skitters, 4 brutes, 6 glimmers")
	var rising := true
	for i in range(1, avgs.size()):
		if avgs[i] <= avgs[i - 1]:
			rising = false
	_check(rising, "deeper floors pay more per specimen on average (%s)" % ", ".join(avgs.map(func(a): return "$%d" % roundi(a))))
	print("Mazes:")
	var m1 := Floors.generate(123, 8, 8)
	var m2 := Floors.generate(123, 8, 8)
	var m3 := Floors.generate(124, 8, 8)
	_check(m1.e == m2.e and m1.s == m2.s, "the same seed always grows the same maze (so every peer builds the same floor)")
	_check(m1.e != m3.e or m1.s != m3.s, "a different seed grows a different maze")
	var connected := true
	for f in Floors.LIST.size():
		for sd in 20:
			var mz := Floors.generate(sd * 7 + f, Floors.LIST[f].cells.x, Floors.LIST[f].cells.y)
			if Floors.reachable_cells(mz) != int(mz.w) * int(mz.h):
				connected = false
	_check(connected, "every cell of every floor can be reached from the elevator (100 mazes checked)")
	var route := Floors.path(m1, Vector2i(0, 0), Vector2i(7, 7))
	var steps_ok := route.size() > 1 and route[0] == Vector2i(0, 0) and route[-1] == Vector2i(7, 7)
	for i in range(1, route.size()):
		if not Floors.open_between(m1, route[i - 1], route[i] - route[i - 1]):
			steps_ok = false
	_check(steps_ok, "pathfinding finds a route through open doorways (%d cells)" % route.size())
	var nxt := Floors.next_step(m1, Floors.cell_center(Vector2i(0, 0)), Floors.cell_center(Vector2i(7, 7)))
	_check(nxt == Floors.cell_center(route[1]), "specimens heading home step to the next cell on the route")
	print("Elevator:")
	var stand: Vector3 = Level.roof_cab.zone_c + Vector3(0, -0.95, 0)
	p.global_position = Vector3(-5, 0.05, -3)
	request_travel.rpc_id(1, 0)
	_check(active_floor == -1 and Level.floor_of(p.global_position.y) == 0, "standing outside the elevator, the button does nothing")
	p.global_position = stand
	request_travel.rpc_id(1, 0)
	_check(active_floor == -1 and Level.floor_of(p.global_position.y) == 0, "it won't run until the day's clock starts")
	tick_run(FIRST_BRIEFING_SECONDS + 1.0)
	_check(phase == Phase.PLAYING, "the day starts after the briefing")
	_check(specimens().size() == 0 and active_floor == -1, "before anyone rides down no floor exists and no specimens are out")
	request_travel.rpc_id(1, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(active_floor == 0 and Level.floor_of(p.global_position.y) == 1 and Floors.in_zone(floor_info.cab, p.global_position),
		"the crew rides down and arrives inside floor 10's elevator")
	var counts := {}
	var on_floor := true
	for s in specimens():
		counts[s.species] = counts.get(s.species, 0) + 1
		if absf(s.global_position.y - (Floors.EXP_Y + 1.0)) > 1.5:
			on_floor = false
	_check(counts == Floors.counts(0), "the floor is stocked with its mix %s" % str(counts))
	_check(on_floor, "every specimen starts standing on the floor")
	var ray := PhysicsRayQueryParameters3D.create(floor_info.cells[3] + Vector3(0, 2, 0), floor_info.cells[3] + Vector3(0, -2, 0))
	var floor_hit := get_world_3d().direct_space_state.intersect_ray(ray)
	_check(not floor_hit.is_empty() and absf(floor_hit.position.y - Floors.EXP_Y) < 0.1, "there is solid floor under the maze")
	_check(travel_problem(p, 1) != "" and travel_problem(p, -1) == "", "from a floor the elevator only goes up")
	var buddy2 := player_spawner.spawn([2]) as Player
	buddy2.global_position = stand
	_check(travel_problem(buddy2, 1) != "" and travel_problem(buddy2, 0) == "",
		"someone on the roof can't open a second floor while the crew is on this one")
	buddy2.queue_free()
	await get_tree().physics_frame
	request_doors.rpc_id(1, true)
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(doors[1] and not (floor_info.cab.door.get_child(0) as CollisionShape3D).disabled and floor_info.cab.door.visible,
		"closing the doors makes a solid door")
	request_doors.rpc_id(1, false)
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(not doors[1] and (floor_info.cab.door.get_child(0) as CollisionShape3D).disabled, "opening them clears the way")
	var cargo := specimen_spawner.spawn(["C1", "skitter", floor_info.cab.zone_c + Vector3(0.5, -0.3, 0.4)]) as Specimen
	var left_behind := specimen_spawner.spawn(["C2", "skitter", floor_info.cells[5]]) as Specimen
	await get_tree().physics_frame
	request_travel.rpc_id(1, -1)
	await get_tree().physics_frame
	_check(Level.floor_of(p.global_position.y) == 0 and Floors.in_zone(Level.roof_cab, p.global_position),
		"riding up puts the crew in the roof elevator")
	_check(Floors.in_zone(Level.roof_cab, cargo.global_position) and not cargo.is_queued_for_deletion(),
		"loot that was in the elevator comes up with them")
	_check(active_floor == -1 and (not is_instance_valid(left_behind) or left_behind.is_queued_for_deletion()) and floor_info.is_empty(),
		"everything left on the floor is gone, and the floor is closed")
	cargo.queue_free()
	for s in specimens():
		s.queue_free()
	await get_tree().physics_frame
	p.global_position = Vector3(-5, 0.05, -3)
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
	_check(earned_today == 40, "a delivery also counts toward today's quota (earned_today=%d)" % earned_today)
	var qs := [quota_for(1), quota_for(2), quota_for(3), quota_for(4)]
	_check(qs == QUOTAS and qs[0] < qs[1] and qs[1] < qs[2] and qs[2] < qs[3], "quotas rise every day %s" % str(qs))
	new_run(0.1)
	_check(day == 1 and phase == Phase.BRIEFING and credits == 0 and earned_today == 0 and delivered == 0,
		"a new run starts at day 1 with an empty bank")
	_check(specimens().size() == 0 and active_floor == -1, "a new run starts with the elevator parked on the roof")
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
	_check(day == 1 and phase == Phase.BRIEFING and credits == 0 and specimens().size() == 0,
		"the host can restart a finished run")
	phase = Phase.PLAYING
	earned_today = quota()
	credits = 340
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.SUMMARY and day == 1, "quota met: the day ends with a summary")
	p.global_position = Vector3(0, Floors.EXP_Y + 0.05, 0)   # the crew is still down in the building
	p.charges = 0
	tick_run(SUMMARY_SECONDS + 0.1)
	_check(day == 2 and phase == Phase.BRIEFING and earned_today == 0 and quota() == QUOTAS[1],
		"day 2 starts fresh with a bigger quota ($%d)" % quota())
	_check(credits == 340, "the bank carries over between days")
	_check(specimens().size() == 0 and active_floor == -1, "the next day starts with the floors closed")
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
	_check(gl._plan_shy().x != INF and gl._plan_shy().length() > 1.0 and gl.mood != 2, "Shy: with one watcher it still runs away (not frozen)")
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
	_activate_floor(1)
	await get_tree().physics_frame
	var maze: Dictionary = floor_info.maze
	var hs := specimen_spawner.spawn(["K5", "skitter", Floors.cell_center(Vector2i(1, 1), Floors.EXP_Y + 1.0)]) as Specimen
	await get_tree().physics_frame
	hs.global_position = Floors.cell_center(Vector2i(6, 6), Floors.EXP_Y + 1.0)
	var here := Floors.cell_of(maze, hs.global_position)
	var there := Floors.cell_of(maze, hs.home)
	var plan := hs._wander_plan(0.1)
	var next_cell := Floors.cell_of(maze, Floors.next_step(maze, hs.global_position, hs.home))
	_check(hs.homesick() and plan.length() > 0.5 and Floors.path(maze, next_cell, there).size() < Floors.path(maze, here, there).size(),
		"a specimen far from its spawn spot walks back along the maze route")
	hs.global_position = hs.home + Vector3(3, 0, 0)
	_check(not hs.homesick(), "close to home it wanders freely")
	hs.global_position = Vector3(12, 1.0, 3)
	_check(not hs.homesick(), "on a different level from home (the roof) it just wanders")
	hs.queue_free()
	await get_tree().physics_frame
	print("Glimmer blink:")
	var spot: Vector3 = floor_info.cells[0]
	p.global_position = spot + Vector3(3, -0.8, 0)
	var bl := specimen_spawner.spawn(["K7", "glimmer", spot]) as Specimen
	await get_tree().physics_frame
	bl._plan_shy(0.05)
	_check(bl.blink_t > 0.0 and bl.mood == 3, "a player closing in starts a blink warning (flicker)")
	bl.on_stunned(1)
	_check(bl.blink_t == 0.0, "a stun during the warning cancels the blink")
	bl._plan_shy(0.05)
	var before := bl.global_position
	bl._plan_shy(Specimen.BLINK_TELL + 0.1)
	var jumped := bl.global_position.distance_to(before)
	var from_player := bl.global_position.distance_to(p.global_position)
	_check(jumped > 6.0 and from_player >= Specimen.BLINK_MIN_DIST, "it teleports away (%.0f m), landing %.0f m from the player" % [jumped, from_player])
	_check(bl.blink_cd > 0.0, "it has a cooldown before it can blink again")
	bl.global_position = before
	bl._plan_shy(0.1)
	_check(bl.blink_t == 0.0, "during the cooldown it only runs; no new warning")
	bl.blink_cd = 0.0
	p.global_position = Vector3(spot.x, spot.y - 0.8, spot.z + 6.0)
	bl.global_position = Vector3(spot.x, spot.y + 0.8, spot.z)
	p.rotation = Vector3.ZERO
	p.head.rotation = Vector3.ZERO
	p2 = player_spawner.spawn([2]) as Player
	p2.global_position = p.global_position + Vector3(0.8, 0, 0)
	p2.rotation = Vector3.ZERO
	p2.head.rotation = Vector3.ZERO
	await get_tree().physics_frame
	bl._plan_shy(0.1)
	_check(bl.mood == 2 and bl.blink_t == 0.0, "two watchers freeze it: no warning and no blink even with players close")
	p2.queue_free()
	bl.queue_free()
	await get_tree().physics_frame
	print("Danger:")
	var spare := get_player(999)
	if spare:
		spare.queue_free()
	await get_tree().physics_frame
	var mate := player_spawner.spawn([2]) as Player
	new_run(0.1)
	tick_run(0.2)
	time_left = DAY_SECONDS
	p.global_position = Vector3(-5, 0.05, -3)
	mate.global_position = Vector3(-7, 0.05, -3)
	damage_player(1, 30.0, "a test")
	_check(is_equal_approx(hp_of(1), 70.0) and not is_dead(1), "damage lowers health (%d left)" % int(hp_of(1)))
	tick_run(1.0)
	_check(hp_of(1) > 77.0 and hp_of(1) <= 78.01, "the roof heals you (%.0f health after a second)" % hp_of(1))
	p.global_position = Vector3(0, Floors.EXP_Y + 0.05, 0)
	var hp_below := hp_of(1)
	tick_run(1.0)
	_check(hp_of(1) == hp_below, "down on a floor you don't heal")
	p.global_position = Vector3(-5, 0.05, -3)
	for i in 4:
		damage_player(1, 40.0, "a test")
	_check(is_dead(1) and phase == Phase.PLAYING, "enough damage kills; the crew carries on while someone lives")
	credits = 1000
	request_buy.rpc_id(1, "coils")
	_check(credits == 1000 and level_of("coils") == 0, "the dead can't shop")
	request_travel.rpc_id(1, 0)
	_check(active_floor == -1, "the dead can't use the elevator")
	tick_run(2.0)
	_check(is_dead(1), "healing doesn't bring the dead back")
	var corpse_grab := specimen_spawner.spawn(["D1", "skitter", p.get_hold_point()]) as Specimen
	await get_tree().physics_frame
	request_grab.rpc_id(1, "D1", true)
	request_stun.rpc_id(1, "D1")
	_check(corpse_grab.held_by.size() == 0 and not corpse_grab.is_stunned(), "the dead can't stun or grab")
	corpse_grab.queue_free()
	new_run(0.1)
	tick_run(0.2)
	_check(not is_dead(1) and hp_of(1) == MAX_HP, "a new day brings everyone back at full health")
	p.global_position = Vector3(-5, 0.05, -3)
	var bru2 := specimen_spawner.spawn(["D2", "brute", Vector3(-5, 0.7, -2)]) as Specimen
	await get_tree().physics_frame
	bru2.provoked_by = 1
	bru2.charge_t = 5.0
	bru2._plan_territorial(0.1)
	_check(is_equal_approx(hp_of(1), MAX_HP - Specimen.BRUTE_DAMAGE), "a Brute's slam hurts (%d health)" % int(hp_of(1)))
	bru2.queue_free()
	hp[1] = MAX_HP
	var boomer := specimen_spawner.spawn(["D3", "glimmer", Vector3(-5, 0.6, -1)]) as Specimen
	await get_tree().physics_frame
	boomer._explode()
	_check(hp_of(1) < MAX_HP - 20.0 and hp_of(1) > MAX_HP - Specimen.BOOM_DAMAGE, "a Glimmer's explosion hurts (%d health)" % int(hp_of(1)))
	print("Stalkers:")
	_check(stalker_target(0.0, 0) == 0 and stalker_target(0.3, 4) == 0, "no hunters in the morning")
	_check(stalker_target(0.6, 2) < stalker_target(1.0, 2) and stalker_target(1.0, 0) < stalker_target(1.0, 4), "more hunters as night falls and on deeper floors (%d, %d, %d)" % [
		stalker_target(0.6, 2), stalker_target(1.0, 2), stalker_target(1.0, 4)])
	_check(stalker_target(1.0, 99) == 8, "never more than 8")
	new_run(0.1)
	tick_run(0.2)
	time_left = DAY_SECONDS
	p.global_position = Vector3(-5, 0.05, -3)
	mate.global_position = Vector3(-7, 0.05, -3)
	_activate_floor(0)
	await get_tree().physics_frame
	for h2 in hunters():
		h2.queue_free()
	var maze2: Dictionary = floor_info.maze
	var hunt_at: Vector3 = floor_info.cells[3]
	p.global_position = Vector3(hunt_at.x, Floors.EXP_Y + 0.05, hunt_at.z)
	var far: Vector3 = floor_info.cells[floor_info.cells.size() - 1]
	var st := specimen_spawner.spawn(["Z1", "stalker", far]) as Specimen
	await get_tree().physics_frame
	var dg_plan := st._plan_hunter(0.1)
	var want := Floors.next_step(maze2, st.global_position, p.global_position) - st.global_position
	want.y = 0.0
	_check(dg_plan.length() > 5.0 and dg_plan.normalized().dot(want.normalized()) > 0.99 and st.mood == 1,
		"a Stalker follows the maze route toward the nearest player")
	st.global_position = Vector3(hunt_at.x + 1.2, Floors.EXP_Y + 1.0, hunt_at.z)
	dg_plan = st._plan_hunter(0.1)
	_check(is_equal_approx(hp_of(1), MAX_HP - Specimen.STALK_DAMAGE) and dg_plan == Vector3.ZERO, "up close it hits for %d" % int(Specimen.STALK_DAMAGE))
	st._plan_hunter(0.1)
	_check(is_equal_approx(hp_of(1), MAX_HP - Specimen.STALK_DAMAGE), "and has to wait between hits")
	st._plan_hunter(Specimen.STALK_COOLDOWN + 0.1)
	_check(is_equal_approx(hp_of(1), MAX_HP - 2.0 * Specimen.STALK_DAMAGE), "then hits again")
	request_grab.rpc_id(1, "Z1", true)
	_check(st.held_by.size() == 0, "it can't be grabbed")
	var bank_now := credits
	st.global_position = Vector3(9.5, 1.0, 9.5)
	await _wait(0.3)
	_check(credits == bank_now and is_instance_valid(st) and not st.is_queued_for_deletion(), "and it's never sold, even if it wanders into the pen")
	st.global_position = Vector3(hunt_at.x + 1.2, Floors.EXP_Y + 1.0, hunt_at.z)
	st.linear_velocity = Vector3.ZERO
	var cab_spot: Vector3 = floor_info.cab.zone_c + Vector3(0, -0.95, 0)
	p.global_position = cab_spot
	hp[1] = MAX_HP
	request_doors.rpc_id(1, true)
	_check(doors[1], "closing the doors works from inside")
	_check(st._hunt_target() == null, "a player shut in the elevator can't be hunted")
	var lurk := st._plan_hunter(0.1)
	_check(lurk.x != INF and st.mood == 1, "the Stalker heads for the elevator doors and waits there")
	tick_run(2.0)
	_check(hp_of(1) == MAX_HP and doors[1], "inside, the doors hold for now")
	hp[1] = 50.0
	tick_run(1.0)
	_check(hp_of(1) > 50.0, "and you heal slowly in there (%d)" % int(hp_of(1)))
	st.global_position = floor_info.cab.door.global_position + Vector3(1.5, -0.3, 0)
	st.linear_velocity = Vector3.ZERO
	tick_run(DOOR_FORCE_SECONDS + 0.5)
	_check(not doors[1] and door_lock > 0.0, "a Stalker pounding on the doors for %d seconds forces them open" % int(DOOR_FORCE_SECONDS))
	request_doors.rpc_id(1, true)
	_check(not doors[1], "and they're jammed for a few seconds, so you can't just re-close them")
	st.queue_free()
	for h2 in hunters():
		h2.queue_free()
	await get_tree().physics_frame
	stalker_t = STALKER_INTERVAL
	time_left = 60.0
	p.global_position = Vector3(hunt_at.x, Floors.EXP_Y + 0.05, hunt_at.z)
	tick_run(0.1)
	_check(hunters().size() >= 1, "late in the day a hunter turns up on the floor (%d)" % hunters().size())
	print("Midnight:")
	for h2 in specimens():
		h2.queue_free()
	_deactivate_floor()
	var roof_a := Vector3(-5, 0.05, -3)
	var roof_b := Vector3(-7, 0.05, -3)
	var down := Vector3(0, Floors.EXP_Y + 0.05, 0)
	new_run(0.1)
	tick_run(0.2)
	earned_today = quota()
	credits = 1000
	p.global_position = roof_a
	mate.global_position = roof_b
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.SUMMARY and credits == 1000 and day_note == "", "everyone back alive: the day counts and the bank is untouched")
	new_run(0.1)
	tick_run(0.2)
	earned_today = quota()
	credits = 1000
	p.global_position = roof_a
	mate.global_position = roof_b
	kill_player(2, "a test")
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.SUMMARY and credits == 800 and day_note.begins_with("1 crew lost"),
		"one death, one survivor back: the day counts, bank cut 20%% ($1000 -> $%d)" % credits)
	tick_run(SUMMARY_SECONDS + 0.1)
	_check(day == 2 and not is_dead(2) and hp_of(2) == MAX_HP and day_note == "", "next day the dead return")
	new_run(0.1)
	tick_run(0.2)
	earned_today = quota()
	credits = 1000
	p.global_position = roof_a
	mate.global_position = down
	time_left = 0.1
	tick_run(0.2)
	_check(is_dead(2) and phase == Phase.SUMMARY and credits == 800, "someone still down in the building at midnight doesn't make it")
	new_run(0.1)
	tick_run(0.2)
	earned_today = quota()
	credits = 1000
	p.global_position = down
	mate.global_position = down
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.LOST and lost_reason.begins_with("Nobody"), "if nobody made it back, the run is lost even with the quota met")
	new_run(0.1)
	tick_run(0.2)
	earned_today = quota() - 1
	p.global_position = roof_a
	mate.global_position = roof_b
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.LOST and lost_reason.begins_with("You earned"), "back alive but short of the quota: still lost")
	new_run(0.1)
	tick_run(0.2)
	kill_player(1, "a test")
	_check(phase == Phase.PLAYING, "one death doesn't end the run")
	kill_player(2, "a test")
	_check(phase == Phase.LOST and lost_reason.begins_with("The whole crew"), "the whole crew dying ends it at once")
	new_run(0.1)
	tick_run(0.2)
	day = DAYS
	earned_today = quota()
	credits = 2000
	p.global_position = roof_a
	mate.global_position = roof_b
	kill_player(2, "a test")
	time_left = 0.1
	tick_run(0.2)
	_check(phase == Phase.WON and credits == 1600, "winning on the last day still costs the bank for a death ($2000 -> $%d)" % credits)
	mate.queue_free()
	new_run(0.1)
	await get_tree().physics_frame
	print("Day clock:")
	_check(clock_text(0.0) == "6:00 AM" and clock_text(0.5) == "3:00 PM" and clock_text(1.0) == "12:00 AM",
		"the clock runs from %s to %s" % [clock_text(0.0), clock_text(1.0)])
	_check(clock_text(0.25) == "10:30 AM" and clock_text(0.75) == "7:30 PM", "and passes through %s and %s" % [clock_text(0.25), clock_text(0.75)])
	new_run(0.1)
	tick_run(0.2)
	time_left = DAY_SECONDS
	var at_dawn := day_progress()
	time_left = DAY_SECONDS / 2.0
	var at_mid := day_progress()
	time_left = 0.0
	_check(at_dawn == 0.0 and is_equal_approx(at_mid, 0.5) and day_progress() == 1.0, "the day starts at dawn and ends at midnight (progress %.1f, %.1f, %.1f)" % [at_dawn, at_mid, day_progress()])
	Level.apply_time(0.0)
	var dawn_sun: float = Level._sun.light_energy
	var dawn_ambient: float = Level._env.ambient_light_energy
	Level.apply_time(1.0)
	_check(Level._sun.light_energy < dawn_sun * 0.2 and Level._env.ambient_light_energy < dawn_ambient * 0.5,
		"by midnight the sun is nearly out (%.2f -> %.2f) and ambient light is down (%.2f -> %.2f)" % [
			dawn_sun, Level._sun.light_energy, dawn_ambient, Level._env.ambient_light_energy])
	Level.apply_time(0.0)
	_check(Floors.light_energy(1.0) < Floors.light_energy(0.0) * 0.4, "the floor lights dim as the day goes on (%.1f -> %.1f)" % [Floors.light_energy(0.0), Floors.light_energy(1.0)])
	_check(Floors.light_color(2, 1.0).g < Floors.light_color(2, 0.0).g, "and turn redder")
	_check(Floors.cell_name(Vector2i(0, 0)) == "A1" and Floors.cell_name(Vector2i(3, 4)) == "D5", "maze cells have grid names the crew can call out (A1 is the elevator)")
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
	p.global_position = Vector3(0, Floors.EXP_Y + 0.05, 0)
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
	hud.close_shop()
	p.global_position = Level.roof_cab.zone_c + Vector3(0, -0.95, 0)
	hud.open_elevator()
	await _wait(0.5)
	get_viewport().get_texture().get_image().save_png("%s/elevator.png" % dir)
	get_tree().quit(0)


func _shot() -> void:
	host()
	var dir := OS.get_environment("SHOT_DIR")
	if dir == "":
		dir = "user://"
	var views := [
		[Vector3(-2, 0.05, 2), atan2(-95.0, 70.0), -0.05],
		[Vector3(2, 0.05, -4), -PI / 2, -0.1],     # facing the roof elevator
		[Vector3(7.5, 0.05, 1.5), -PI / 2 - 0.9, -0.25],   # inside the cab, looking at its panel
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
	_activate_floor(2)   # floor 8: the biggest of the three in the design
	await _wait(0.6)
	var cell: Vector3 = floor_info.cells[floor_info.cells.size() / 2]
	p.global_position = Vector3(Floors.CELL * 0.5, Floors.EXP_Y + 0.05, Floors.CELL * 0.5)
	p.velocity = Vector3.ZERO
	p.rotation.y = -PI / 2
	p.head.rotation.x = -0.05
	await _wait(0.8)
	get_viewport().get_texture().get_image().save_png("%s/shot%d.png" % [dir, i])   # in the maze, by the elevator
	i += 1
	for sp in ["skitter", "brute", "glimmer"]:
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
	time_left = 40.0   # late evening
	p.global_position = Vector3(Floors.CELL * 1.5, Floors.EXP_Y + 0.05, Floors.CELL * 0.5)
	p.rotation.y = -PI / 2
	p.head.rotation.x = -0.05
	await _wait(0.8)
	get_viewport().get_texture().get_image().save_png("%s/shot%d.png" % [dir, i])   # the maze near midnight
	i += 1
	p.global_position = Vector3(2, 0.05, -4)
	p.rotation.y = -PI / 2
	await _wait(0.8)
	get_viewport().get_texture().get_image().save_png("%s/shot%d.png" % [dir, i])   # the roof near midnight
	get_tree().quit(0)
