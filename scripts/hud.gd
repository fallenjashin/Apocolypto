class_name Hud
extends CanvasLayer
## Host/Join menu plus the in-game HUD, built in code.

signal host_pressed
signal join_pressed(ip: String)

var game: Game
var menu: Control
var ip_edit: LineEdit
var status_lbl: Label
var game_ui: Control
var top_lbl: Label
var toast_lbl: Label
var toast_t := 0.0
var cross_lbl: Label
var zap_t := 0.0
var target_lbl: Label
var bottom_lbl: Label
var flash_rect: ColorRect
var hurt_rect: ColorRect
var death_lbl: Label
var dim_rect: ColorRect
var banner_lbl: Label
var shop_root: Control
var shop_list: VBoxContainer
var shop_bank_lbl: Label
var shop_open := false
var elevator_root: Control
var elevator_list: VBoxContainer
var elevator_title: Label
var elevator_open := false


func _ready() -> void:
	menu = _build_menu()
	add_child(menu)
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 0.92, 0.75, 0.0)
	add_child(flash_rect)
	hurt_rect = ColorRect.new()
	hurt_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	hurt_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hurt_rect.color = Color(0.8, 0.0, 0.0, 0.0)
	add_child(hurt_rect)
	game_ui = Control.new()
	game_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	game_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_ui.visible = false
	add_child(game_ui)
	dim_rect = ColorRect.new()   # darkens the world on the win / lose screens
	dim_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim_rect.color = Color(0, 0, 0, 0.0)
	game_ui.add_child(dim_rect)
	death_lbl = _label(44, true)
	death_lbl.anchor_top = 0.5
	death_lbl.anchor_bottom = 0.5
	death_lbl.offset_top = -80
	death_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_lbl.modulate = Color(1.0, 0.4, 0.4)
	banner_lbl = _label(40, true)
	banner_lbl.anchor_top = 0.0
	banner_lbl.offset_top = 150
	banner_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top_lbl = _label(22)
	top_lbl.position = Vector2(16, 12)
	toast_lbl = _label(26, true)
	toast_lbl.anchor_top = 0.0
	toast_lbl.offset_top = 70
	cross_lbl = _label(28, true)
	cross_lbl.text = "+"
	cross_lbl.anchor_top = 0.5
	cross_lbl.anchor_bottom = 0.5
	cross_lbl.offset_top = -20
	target_lbl = _label(20, true)
	target_lbl.anchor_top = 0.5
	target_lbl.anchor_bottom = 0.5
	target_lbl.offset_top = 28
	bottom_lbl = _label(20)
	bottom_lbl.anchor_top = 1.0
	bottom_lbl.anchor_bottom = 1.0
	bottom_lbl.offset_left = 16
	bottom_lbl.offset_top = -150
	var help := _label(16)
	help.anchor_left = 1.0
	help.anchor_right = 1.0
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_left = -330
	help.offset_top = -120
	help.text = "WASD move  ·  Shift sprint  ·  Space jump\nLeft click: stun prod\nHold right click: grab / carry\nB (on the roof): military store\nE inside the elevator: use its panel\nEsc: free the mouse"
	help.offset_top = -175
	_build_shop()
	_build_elevator()


func _build_shop() -> void:
	shop_root = CenterContainer.new()
	shop_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_root.visible = false
	add_child(shop_root)
	var panel := PanelContainer.new()
	shop_root.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	margin.add_child(v)
	var title := Label.new()
	title.text = "MILITARY STORE"
	title.add_theme_font_size_override("font_size", 34)
	v.add_child(title)
	shop_bank_lbl = Label.new()
	shop_bank_lbl.add_theme_font_size_override("font_size", 22)
	v.add_child(shop_bank_lbl)
	shop_list = VBoxContainer.new()
	shop_list.add_theme_constant_override("separation", 8)
	v.add_child(shop_list)
	var foot := Label.new()
	foot.text = "Upgrades are shared by the whole crew and last the whole run.   B or Esc to close."
	foot.add_theme_font_size_override("font_size", 14)
	foot.modulate = Color(1, 1, 1, 0.7)
	v.add_child(foot)


func _build_elevator() -> void:
	elevator_root = CenterContainer.new()
	elevator_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	elevator_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	elevator_root.visible = false
	add_child(elevator_root)
	var panel := PanelContainer.new()
	elevator_root.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	margin.add_child(v)
	elevator_title = Label.new()
	elevator_title.add_theme_font_size_override("font_size", 34)
	v.add_child(elevator_title)
	elevator_list = VBoxContainer.new()
	elevator_list.add_theme_constant_override("separation", 8)
	v.add_child(elevator_list)
	var foot := Label.new()
	foot.text = "Everyone standing inside rides together, and so does any loot in there with them.   E or Esc to close."
	foot.add_theme_font_size_override("font_size", 14)
	foot.modulate = Color(1, 1, 1, 0.7)
	v.add_child(foot)


func open_elevator() -> void:
	elevator_open = true
	elevator_root.visible = true
	refresh_elevator()


func close_elevator() -> void:
	elevator_open = false
	elevator_root.visible = false


func refresh_elevator() -> void:
	var p := game.local_player()
	if p == null:
		return
	var where := game.cab_of(p.global_position)
	for c in elevator_list.get_children():
		elevator_list.remove_child(c)
		c.queue_free()
	if where == 0:
		elevator_title.text = "ELEVATOR  ·  roof"
		for f in Floors.LIST.size():
			var d: Dictionary = Floors.LIST[f]
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 18)
			var info := VBoxContainer.new()
			info.custom_minimum_size.x = 520
			var name_lbl := Label.new()
			name_lbl.text = "Floor %d   ·   %d specimens   ·   avg $%d each" % [d.number, d.count, roundi(Floors.average_value(f))]
			name_lbl.add_theme_font_size_override("font_size", 20)
			info.add_child(name_lbl)
			var mix := Label.new()
			mix.text = Floors.mix_text(f)
			mix.add_theme_font_size_override("font_size", 14)
			mix.modulate = Color(1, 1, 1, 0.7)
			info.add_child(mix)
			row.add_child(info)
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(130, 40)
			btn.text = "Descend"
			var problem := game.travel_problem(p, f)
			btn.disabled = problem != ""
			btn.tooltip_text = problem
			btn.pressed.connect(func(): game.request_travel.rpc_id(1, f))
			row.add_child(btn)
			elevator_list.add_child(row)
	elif where == 1:
		elevator_title.text = "ELEVATOR  ·  floor %d" % int(Floors.LIST[game.active_floor].number)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(260, 44)
		btn.text = "Ride up to the roof"
		var problem := game.travel_problem(p, -1)
		btn.disabled = problem != ""
		btn.tooltip_text = problem
		btn.pressed.connect(func(): game.request_travel.rpc_id(1, -1))
		elevator_list.add_child(btn)
	if where >= 0:
		var closed: bool = game.doors[where]
		var dbtn := Button.new()
		dbtn.custom_minimum_size = Vector2(260, 44)
		dbtn.text = "Open the doors" if closed else "Close the doors"
		dbtn.pressed.connect(func(): game.request_doors.rpc_id(1, not closed))
		elevator_list.add_child(dbtn)


func open_shop() -> void:
	shop_open = true
	shop_root.visible = true
	refresh_shop()


func close_shop() -> void:
	shop_open = false
	shop_root.visible = false


## Rebuilds the rows. The buttons use the same rule the host uses to accept a purchase.
func refresh_shop() -> void:
	shop_bank_lbl.text = "Bank: $%d" % game.credits
	for c in shop_list.get_children():
		shop_list.remove_child(c)
		c.queue_free()
	for id in Shop.ORDER:
		var item: Dictionary = Shop.ITEMS[id]
		var lvl := game.level_of(id)
		var maxed := lvl >= Shop.max_level(id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		var info := VBoxContainer.new()
		info.custom_minimum_size.x = 420
		var name_lbl := Label.new()
		var tag := "  (bought today: %d / %d)" % [lvl, Shop.max_level(id)] if id == "daylight" \
			else "  Lv %d / %d" % [lvl, Shop.max_level(id)]
		name_lbl.text = item.title + tag
		name_lbl.add_theme_font_size_override("font_size", 20)
		info.add_child(name_lbl)
		var desc := Label.new()
		desc.text = item.desc
		desc.add_theme_font_size_override("font_size", 14)
		desc.modulate = Color(1, 1, 1, 0.7)
		info.add_child(desc)
		row.add_child(info)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(130, 40)
		if maxed:
			btn.text = "MAX"
			btn.disabled = true
		else:
			btn.text = "Buy  $%d" % Shop.cost(id, lvl)
			var problem := game.buy_problem(id)
			btn.disabled = problem != ""
			btn.tooltip_text = problem
			btn.pressed.connect(func(): game.request_buy.rpc_id(1, id))
		row.add_child(btn)
		shop_list.add_child(row)


func _label(size: int, centered := false) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if centered:
		l.anchor_left = 0.0
		l.anchor_right = 1.0
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_ui.add_child(l)
	return l


func _build_menu() -> Control:
	var root := ColorRect.new()
	root.color = Color(0, 0, 0, 0.55)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	margin.add_child(v)
	var title := Label.new()
	title.text = "ROOFTOP"
	title.add_theme_font_size_override("font_size", 48)
	v.add_child(title)
	var sub := Label.new()
	sub.text = "Prototype 1: capture & haul  ·  build 11"
	v.add_child(sub)
	var desc := Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc.custom_minimum_size.x = 480
	desc.text = "Stun aliens with your prod, grab them, and haul them up to the pen on the roof. " \
		+ "Deeper floors hold rarer specimens. An awake specimen breaks free from one person; it takes two to hold it."
	v.add_child(desc)
	var row := HBoxContainer.new()
	var ip_lbl := Label.new()
	ip_lbl.text = "Host IP"
	row.add_child(ip_lbl)
	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.custom_minimum_size.x = 220
	row.add_child(ip_edit)
	v.add_child(row)
	var buttons := HBoxContainer.new()
	var host_btn := Button.new()
	host_btn.text = "  Host  "
	host_btn.pressed.connect(func(): host_pressed.emit())
	buttons.add_child(host_btn)
	var join_btn := Button.new()
	join_btn.text = "  Join  "
	join_btn.pressed.connect(func(): join_pressed.emit(ip_edit.text.strip_edges()))
	buttons.add_child(join_btn)
	v.add_child(buttons)
	status_lbl = Label.new()
	v.add_child(status_lbl)
	var tip := Label.new()
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD
	tip.custom_minimum_size.x = 480
	tip.add_theme_font_size_override("font_size", 13)
	tip.modulate = Color(1, 1, 1, 0.7)
	tip.text = "Testing alone? In the editor: Debug > Customize Run Instances > Enable Multiple Instances, set 2. " \
		+ "Host in one window, Join in the other. Friends on another network need port 7777 forwarded for now (Steam lobbies come later)."
	v.add_child(tip)
	return root


func status(text: String) -> void:
	status_lbl.text = text


func show_game() -> void:
	menu.visible = false
	game_ui.visible = true


func toast(text: String) -> void:
	if text == "":
		return
	toast_lbl.text = text
	toast_t = 4.0


## The white-out when the asteroid hits. Fades over about 1.5 seconds.
func flash_screen() -> void:
	flash_rect.color.a = 0.85


## The red flash when you take damage (or die).
func hurt() -> void:
	hurt_rect.color.a = 0.5


func zap() -> void:
	zap_t = 0.15


## Called whenever the server sends a new run state. The numbers themselves are drawn every frame.
func run_changed(msg: String) -> void:
	toast(msg)
	if shop_open:
		if game.phase == Game.Phase.WON or game.phase == Game.Phase.LOST:
			game.close_shop()
		else:
			refresh_shop()
	if elevator_open:
		refresh_elevator()


func _top_text() -> String:
	var g := game
	var clock := ""
	match g.phase:
		Game.Phase.BRIEFING: clock = "starts in %d" % ceili(g.phase_t)
		Game.Phase.PLAYING: clock = "%s  (%s left)" % [Game.clock_text(g.day_progress()), Game.fmt_clock(g.time_left)]
		Game.Phase.SUMMARY: clock = "day over"
		_: clock = "run over"
	var met := "   QUOTA MET" if g.earned_today >= g.quota() else ""
	var crew := g.players_root.get_child_count()
	var alive := g.alive_players().size()
	return "DAY %d / %d   ·   %s\nQuota today: $%d / $%d%s\nBank: $%d   ·   Delivered: %d   ·   Crew alive: %d/%d" % [
		g.day, Game.DAYS, clock, g.earned_today, g.quota(), met, g.credits, g.delivered, alive, crew]


func _banner_text() -> String:
	var g := game
	var host_hint := "Host: press R for a new run" if g.multiplayer.is_server() else "Waiting for the host to start a new run"
	match g.phase:
		Game.Phase.BRIEFING:
			if g.phase_t > Game.BRIEFING_SECONDS:
				return ""   # day 1's long wait is for the opening cinematic: keep the view clear
			return "DAY %d  ·  QUOTA $%d\nThe clock starts in %d" % [g.day, g.quota(), ceili(g.phase_t)]
		Game.Phase.SUMMARY:
			return "DAY %d COMPLETE\nEarned $%d  (quota $%d)\nBank: $%d  ·  Day %d starts in %d" % [
				g.day, g.earned_today, g.quota(), g.credits, g.day + 1, ceili(g.phase_t)] + ("\n" + g.day_note if g.day_note != "" else "")
		Game.Phase.WON:
			return "YOU MADE IT\nAll %d quotas met. %d specimens delivered.\nBank: $%d\n%s%s" % [
				Game.DAYS, g.delivered, g.credits, g.day_note + "\n" if g.day_note != "" else "", host_hint]
		Game.Phase.LOST:
			return "RUN OVER  ·  DAY %d\n%s\n%d specimens delivered.\n%s" % [
				g.day, g.lost_reason, g.delivered, host_hint]
	return ""


func _process(delta: float) -> void:
	toast_t = maxf(0.0, toast_t - delta)
	toast_lbl.modulate.a = clampf(toast_t, 0.0, 1.0)
	zap_t = maxf(0.0, zap_t - delta)
	flash_rect.color.a = maxf(0.0, flash_rect.color.a - delta * 0.6)
	hurt_rect.color.a = maxf(0.0, hurt_rect.color.a - delta * 1.2)
	cross_lbl.modulate = Color(0.5, 0.8, 1.0) if zap_t > 0.0 else Color.WHITE
	if not game_ui.visible or game == null:
		return
	top_lbl.text = _top_text()
	var low_clock: bool = game.phase == Game.Phase.PLAYING and game.time_left < 30.0
	top_lbl.modulate = Color(1.0, 0.55, 0.5) if low_clock else Color.WHITE
	banner_lbl.text = _banner_text()
	var run_over: bool = game.phase == Game.Phase.WON or game.phase == Game.Phase.LOST
	dim_rect.color.a = 0.5 if run_over else 0.0
	cross_lbl.visible = not run_over
	var p := game.local_player()
	if p == null:
		return
	var is_dead := game.is_dead(p.peer_id)
	death_lbl.text = "YOU DIED\nIf anyone gets back to the roof by midnight the day still counts.\nYou're back tomorrow." if is_dead and game.phase == Game.Phase.PLAYING else ""
	var hp_now := game.hp_of(p.peer_id)
	var hp_bar := "#".repeat(ceili(hp_now / 10.0)) + "-".repeat(10 - ceili(hp_now / 10.0))
	var bar := "#".repeat(p.charges) + "-".repeat(maxi(0, p.max_charges() - p.charges))
	var where := Level.floor_of(p.global_position.y)
	var recharge := "  (recharging)" if where == 0 and p.charges < p.max_charges() else ""
	var store_hint := "\nPress B to open the store" if where == 0 and not shop_open else ""
	if game.cab_of(p.global_position) >= 0 and not elevator_open:
		store_hint += "\nPress E to use the elevator"
	bottom_lbl.text = "%s\nHealth [%s] %d\nProd charges [%s]%s%s" % [game.location_name(p), hp_bar, ceili(hp_now), bar, recharge, store_hint]
	var held := game.held_spec_of(p.peer_id)
	if held:
		var n := held.held_by.size()
		var state := ""
		if held.is_stunned():
			state = "stunned %.1fs" % held.stun_left
		elif n >= 2:
			state = "STRUGGLING. Hold on together!"
		else:
			state = "STRUGGLING. It will break free! Re-stun it or get help."
		target_lbl.text = "Carrying %s ($%d), %d holding: %s\nBring it up to the pen on the roof." % [
			held.spec.label, held.spec.value, n, state]
		return
	var t := p.look_target(Player.GRAB_RANGE + 1.0)
	if t == null:
		target_lbl.text = ""
	elif bool(t.spec.get("hostile", false)):
		if t.is_stunned():
			target_lbl.text = "STALKER  STUNNED %.1fs. Get away or get to the elevator!" % t.stun_left
		else:
			target_lbl.text = "STALKER  hunts you, hits hard\nLeft click to stun it for a few seconds. It can't be captured."
	elif t.is_stunned():
		target_lbl.text = "%s  $%d  STUNNED %.1fs. Hold right click to grab" % [t.spec.label, t.spec.value, t.stun_left]
	elif t.fuse_t > 0.0:
		target_lbl.text = "%s  UNSTABLE! Explodes in %.1fs. Left click to stun it again!" % [t.spec.label, t.fuse_t]
	else:
		var temper: Dictionary = Specimen.TEMPERS[t.spec.temper]
		target_lbl.text = "%s  $%d  [%s] awake. Left click to stun\n%s" % [t.spec.label, t.spec.value, temper.name, temper.hint]
