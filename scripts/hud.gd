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
var dim_rect: ColorRect
var banner_lbl: Label


func _ready() -> void:
	menu = _build_menu()
	add_child(menu)
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 0.92, 0.75, 0.0)
	add_child(flash_rect)
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
	bottom_lbl.offset_top = -120
	var help := _label(16)
	help.anchor_left = 1.0
	help.anchor_right = 1.0
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_left = -330
	help.offset_top = -120
	help.text = "WASD move  ·  Shift sprint  ·  Space jump\nLeft click: stun prod\nHold E: grab / carry\nEsc: free the mouse"


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
	sub.text = "Prototype 1: capture & haul  ·  build 5"
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


func zap() -> void:
	zap_t = 0.15


## Called whenever the server sends a new run state. The numbers themselves are drawn every frame.
func run_changed(msg: String) -> void:
	toast(msg)


func _top_text() -> String:
	var g := game
	var clock := ""
	match g.phase:
		Game.Phase.BRIEFING: clock = "starts in %d" % ceili(g.phase_t)
		Game.Phase.PLAYING: clock = Game.fmt_clock(g.time_left)
		Game.Phase.SUMMARY: clock = "day over"
		_: clock = "run over"
	var met := "   QUOTA MET" if g.earned_today >= g.quota() else ""
	return "DAY %d / %d   ·   %s\nQuota today: $%d / $%d%s\nBank: $%d   ·   Delivered: %d" % [
		g.day, Game.DAYS, clock, g.earned_today, g.quota(), met, g.credits, g.delivered]


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
				g.day, g.earned_today, g.quota(), g.credits, g.day + 1, ceili(g.phase_t)]
		Game.Phase.WON:
			return "YOU MADE IT\nAll %d quotas met. %d specimens delivered.\nBank: $%d\n%s" % [
				Game.DAYS, g.delivered, g.credits, host_hint]
		Game.Phase.LOST:
			return "OVERRUN  ·  DAY %d\nYou earned $%d of the $%d quota.\n%d specimens delivered.\n%s" % [
				g.day, g.earned_today, g.quota(), g.delivered, host_hint]
	return ""


func _process(delta: float) -> void:
	toast_t = maxf(0.0, toast_t - delta)
	toast_lbl.modulate.a = clampf(toast_t, 0.0, 1.0)
	zap_t = maxf(0.0, zap_t - delta)
	flash_rect.color.a = maxf(0.0, flash_rect.color.a - delta * 0.6)
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
	var bar := "#".repeat(p.charges) + "-".repeat(Player.MAX_CHARGES - p.charges)
	var where := Level.floor_of(p.global_position.y)
	var recharge := "  (recharging)" if where == 0 and p.charges < Player.MAX_CHARGES else ""
	bottom_lbl.text = "%s\nProd charges [%s]%s" % [Game.DEPTH_NAMES[where], bar, recharge]
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
	elif t.is_stunned():
		target_lbl.text = "%s  $%d  STUNNED %.1fs. Hold E to grab" % [t.spec.label, t.spec.value, t.stun_left]
	else:
		target_lbl.text = "%s  $%d  awake. Left click to stun" % [t.spec.label, t.spec.value]
