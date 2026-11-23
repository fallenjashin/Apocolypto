class_name Floors
extends RefCounted
## The expedition floors: what's down the elevator. Each floor is DATA (which specimens
## live there, how big it is) plus a maze grown from a seed. Every peer builds the same
## geometry from the same seed, so nothing about the maze is sent over the network.
## Only one floor exists at a time, far below the roof, and it has nothing to do with
## what the building looks like from the outside.

const EXP_Y := -100.0          # surface of the floor slab
const CELL := 6.0              # one maze cell is 6 x 6 m
const WALL_H := 3.4
const WALL_T := 0.4
const SLAB := 0.5
## The elevator on every floor: the cab sits west of the maze, door on its east side.
const CAB_FRONT := Vector3(0.0, EXP_Y, 3.0)
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## "mix" is the share of each species. Deeper floors are bigger and glimmer-heavy.
## Floors 10 to 8 are the design you asked for; 7 and 6 are my extrapolation. Tune freely.
const LIST := [
	{"number": 10, "cells": Vector2i(7, 7), "count": 14, "mix": {"skitter": 0.75, "brute": 0.20, "glimmer": 0.05}},
	{"number": 9, "cells": Vector2i(8, 8), "count": 14, "mix": {"skitter": 0.30, "brute": 0.50, "glimmer": 0.20}},
	{"number": 8, "cells": Vector2i(9, 9), "count": 14, "mix": {"skitter": 0.30, "brute": 0.30, "glimmer": 0.40}},
	{"number": 7, "cells": Vector2i(10, 10), "count": 14, "mix": {"skitter": 0.20, "brute": 0.30, "glimmer": 0.50}},
	{"number": 6, "cells": Vector2i(11, 11), "count": 14, "mix": {"skitter": 0.10, "brute": 0.30, "glimmer": 0.60}},
]
const SPECIES_ORDER := ["skitter", "brute", "glimmer"]


## How many of each species a floor holds. The shares rarely divide evenly, so the
## leftover specimens go to the largest remainders and the total is always exact.
static func counts(f: int) -> Dictionary:
	var d: Dictionary = LIST[f]
	var out := {}
	var rest: Array = []
	var assigned := 0
	for sp in SPECIES_ORDER:
		var exact: float = float(d.mix.get(sp, 0.0)) * int(d.count)
		var whole := int(floor(exact))
		out[sp] = whole
		assigned += whole
		rest.append([exact - whole, sp])
	rest.sort_custom(func(a, b): return a[0] > b[0])
	for i in int(d.count) - assigned:
		out[rest[i][1]] += 1
	return out


## Average payout of one specimen on this floor, in dollars.
static func average_value(f: int) -> float:
	var total := 0.0
	for sp in LIST[f].mix:
		total += float(LIST[f].mix[sp]) * float(Specimen.SPECIES[sp].value)
	return total


static func mix_text(f: int) -> String:
	var parts: Array[String] = []
	for sp in SPECIES_ORDER:
		var share: float = LIST[f].mix.get(sp, 0.0)
		if share > 0.0:
			parts.append("%d%% %s" % [roundi(share * 100.0), sp])
	return " / ".join(parts)


# --- Maze --------------------------------------------------------------------
# A maze is {"w", "h", "e", "s"}. e[y*w+x] = 1 when (x,y) is open to its east neighbour,
# s[y*w+x] = 1 when it is open to its south neighbour.

static func generate(seed_v: int, w: int, h: int, braid := 0.12) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var e := PackedByteArray()
	var s := PackedByteArray()
	var seen := PackedByteArray()
	e.resize(w * h)
	s.resize(w * h)
	seen.resize(w * h)
	var stack: Array[Vector2i] = [Vector2i(0, 0)]
	seen[0] = 1
	while not stack.is_empty():
		var c: Vector2i = stack[-1]
		var options: Array[Vector2i] = []
		for d in DIRS:
			var n := c + d
			if n.x >= 0 and n.x < w and n.y >= 0 and n.y < h and seen[n.y * w + n.x] == 0:
				options.append(d)
		if options.is_empty():
			stack.pop_back()
			continue
		var d: Vector2i = options[rng.randi_range(0, options.size() - 1)]
		if d.x == 1:
			e[c.y * w + c.x] = 1
		elif d.x == -1:
			e[c.y * w + c.x - 1] = 1
		elif d.y == 1:
			s[c.y * w + c.x] = 1
		else:
			s[(c.y - 1) * w + c.x] = 1
		var nxt := c + d
		seen[nxt.y * w + nxt.x] = 1
		stack.append(nxt)
	# A perfect maze has exactly one route between any two cells, which makes chases
	# miserable. Knock out some walls to make loops you can run around.
	for y in h:
		for x in w:
			if x < w - 1 and e[y * w + x] == 0 and rng.randf() < braid:
				e[y * w + x] = 1
			if y < h - 1 and s[y * w + x] == 0 and rng.randf() < braid:
				s[y * w + x] = 1
	return {"w": w, "h": h, "e": e, "s": s}


static func open_between(m: Dictionary, a: Vector2i, d: Vector2i) -> bool:
	var w: int = m.w
	var h: int = m.h
	var n := a + d
	if n.x < 0 or n.x >= w or n.y < 0 or n.y >= h:
		return false
	if d.x == 1:
		return m.e[a.y * w + a.x] == 1
	if d.x == -1:
		return m.e[n.y * w + n.x] == 1
	if d.y == 1:
		return m.s[a.y * w + a.x] == 1
	return m.s[n.y * w + n.x] == 1


static func cell_center(c: Vector2i, y := EXP_Y) -> Vector3:
	return Vector3((c.x + 0.5) * CELL, y, (c.y + 0.5) * CELL)


static func cell_of(m: Dictionary, pos: Vector3) -> Vector2i:
	return Vector2i(clampi(int(floor(pos.x / CELL)), 0, int(m.w) - 1), clampi(int(floor(pos.z / CELL)), 0, int(m.h) - 1))


## Shortest route between two cells (breadth-first search; the grid is tiny).
static func path(m: Dictionary, a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var w: int = m.w
	var prev := {}
	prev[a] = a
	var queue: Array[Vector2i] = [a]
	var head := 0
	while head < queue.size() and not prev.has(b):
		var c: Vector2i = queue[head]
		head += 1
		for d in DIRS:
			if open_between(m, c, d) and not prev.has(c + d):
				prev[c + d] = c
				queue.append(c + d)
	var out: Array[Vector2i] = []
	if not prev.has(b):
		return out
	var cur := b
	while cur != a:
		out.push_front(cur)
		cur = prev[cur]
	out.push_front(a)
	return out


## The next point to head for when walking from `from` to `to` through the maze.
static func next_step(m: Dictionary, from: Vector3, to: Vector3) -> Vector3:
	var route := path(m, cell_of(m, from), cell_of(m, to))
	if route.size() <= 1:
		return to
	return cell_center(route[1], from.y)


## How many cells can be reached from the elevator. Equals w*h for a good maze.
static func reachable_cells(m: Dictionary) -> int:
	var seen := {Vector2i(0, 0): true}
	var queue: Array[Vector2i] = [Vector2i(0, 0)]
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in DIRS:
			if open_between(m, c, d) and not seen.has(c + d):
				seen[c + d] = true
				queue.append(c + d)
	return seen.size()


# --- Geometry ----------------------------------------------------------------

## How bright and what colour the ceiling lights are, for floor `f` at `progress` through
## the day. They dim and redden as midnight approaches.
static func light_energy(progress: float) -> float:
	return 2.6 * lerpf(1.0, 0.3, smoothstep(0.3, 1.0, progress))


static func light_color(f: int, progress: float) -> Color:
	var col := Color(1.0, 0.85, 0.7).lerp(Color(1.0, 0.3, 0.25), float(f) / float(LIST.size() - 1))
	return col.lerp(Color(0.9, 0.1, 0.1), 0.5 * smoothstep(0.5, 1.0, progress))


## "A1" is the cell by the elevator. Columns are letters, rows are numbers.
static func cell_name(c: Vector2i) -> String:
	return "%s%d" % [char(65 + c.x), c.y + 1]


## Builds an elevator cab. `front` is the middle of its door; the cab extends west from it.
## Returns the door node, the zone that counts as "inside", and where the panel is.
static func build_cab(root: Node3D, front: Vector3, color: Color) -> Dictionary:
	var h := WALL_H - 0.6
	var cy := front.y + h / 2
	var steel := color.darkened(0.2)
	# Front wall on both sides of the door, and above it.
	for sgn in [-1.0, 1.0]:
		Level.box(root, Vector3(front.x, cy, front.z + sgn * 2.1), Vector3(WALL_T, h, 1.8), color)
	Level.box(root, Vector3(front.x, front.y + 2.9, front.z), Vector3(WALL_T, h - 2.6, 2.4), color)
	# Side walls, back wall, ceiling.
	for sgn in [-1.0, 1.0]:
		Level.box(root, Vector3(front.x - 2.0, cy, front.z + sgn * 2.1), Vector3(4.4, h, 0.2), steel)
	Level.box(root, Vector3(front.x - 4.1, cy, front.z), Vector3(0.2, h, 4.4), steel)
	Level.box(root, Vector3(front.x - 2.0, front.y + h + 0.1, front.z), Vector3(4.4, 0.2, 4.4), steel)
	# The panel: a glowing strip on the back wall.
	var panel := Vector3(front.x - 3.9, front.y + 1.5, front.z)
	Level.box(root, panel, Vector3(0.08, 0.9, 1.4), Color(0.3, 1.0, 0.5), false, Vector3.ZERO, 2.5)
	Level.label(root, "ELEVATOR\nE to use", panel + Vector3(0.6, 0.9, 0), 40, Color(0.6, 1, 0.7))
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(front.x - 2.0, front.y + h - 0.3, front.z)
	lamp.light_color = Color(1.0, 0.95, 0.8)
	lamp.light_energy = 1.0
	lamp.omni_range = 7
	root.add_child(lamp)
	# The door: solid while closed, gone while open.
	var door := StaticBody3D.new()
	door.name = "Door"
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.3, 2.6, 2.4)
	cs.shape = sh
	door.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.3, 2.6, 2.4)
	bm.material = Level.mat(Color(0.75, 0.6, 0.2), 0.4)
	mi.mesh = bm
	door.add_child(mi)
	door.position = Vector3(front.x, front.y + 1.3, front.z)
	root.add_child(door)
	set_door(door, false)
	return {"door": door, "zone_c": Vector3(front.x - 2.0, front.y + 1.0, front.z),
		"zone_h": Vector3(2.0, 1.6, 2.0), "panel": panel}


static func set_door(door: Node3D, closed: bool) -> void:
	door.visible = closed
	for c in door.get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).set_deferred("disabled", not closed)


static func in_zone(cab: Dictionary, pos: Vector3) -> bool:
	if cab.is_empty():
		return false
	var c: Vector3 = cab.zone_c
	var hz: Vector3 = cab.zone_h
	return absf(pos.x - c.x) <= hz.x and absf(pos.y - c.y) <= hz.y and absf(pos.z - c.z) <= hz.z


## Builds floor `f` from `seed_v`. Returns {root, maze, cab, lights, cells}.
static func build(parent: Node3D, f: int, seed_v: int) -> Dictionary:
	var d: Dictionary = LIST[f]
	var w: int = d.cells.x
	var h: int = d.cells.y
	var maze := generate(seed_v, w, h)
	var root := Node3D.new()
	root.name = "ExpeditionFloor"
	parent.add_child(root)
	var wc := Color(0.5, 0.47, 0.44).darkened(0.06 * f)
	var fc := Color(0.27, 0.27, 0.3)
	var W := w * CELL
	var H := h * CELL
	var wall_cy := EXP_Y + WALL_H / 2
	Level.box(root, Vector3(W / 2 - 2.5, EXP_Y - SLAB / 2, H / 2), Vector3(W + 5.4, SLAB, H + 0.8), fc)
	Level.box(root, Vector3(W / 2 - 2.5, EXP_Y + WALL_H + SLAB / 2, H / 2), Vector3(W + 5.4, SLAB, H + 0.8), fc.darkened(0.2))
	# Outer walls. The west wall's first cell is the elevator's own front wall.
	Level.box(root, Vector3(W / 2, wall_cy, -WALL_T / 2), Vector3(W + WALL_T, WALL_H, WALL_T), wc)
	Level.box(root, Vector3(W / 2, wall_cy, H + WALL_T / 2), Vector3(W + WALL_T, WALL_H, WALL_T), wc)
	Level.box(root, Vector3(W + WALL_T / 2, wall_cy, H / 2), Vector3(WALL_T, WALL_H, H + WALL_T), wc)
	Level.box(root, Vector3(-WALL_T / 2, wall_cy, (H + CELL) / 2), Vector3(WALL_T, WALL_H, H - CELL), wc)
	# Inner walls wherever the maze is closed.
	for y in h:
		for x in w:
			if x < w - 1 and maze.e[y * w + x] == 0:
				Level.box(root, Vector3((x + 1) * CELL, wall_cy, (y + 0.5) * CELL), Vector3(WALL_T, WALL_H, CELL + WALL_T), wc)
			if y < h - 1 and maze.s[y * w + x] == 0:
				Level.box(root, Vector3((x + 0.5) * CELL, wall_cy, (y + 1) * CELL), Vector3(CELL + WALL_T, WALL_H, WALL_T), wc)
	var cab := build_cab(root, CAB_FRONT, wc)
	# Dim, flickery-looking lights get redder the deeper you go.
	var lights: Array[OmniLight3D] = []
	var col := light_color(f, 0.0)
	var cells: Array[Vector3] = []
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if c.distance_to(Vector2(0, 0)) >= 3.0:
				cells.append(cell_center(c, EXP_Y + 1.0))
			Level.label(root, cell_name(c), cell_center(c, EXP_Y + 2.9), 36, Color(0.8, 0.8, 0.85, 0.7))
			if x % 2 == 0 and y % 2 == 0:
				var o := OmniLight3D.new()
				o.position = cell_center(c, EXP_Y + WALL_H - 0.5)
				o.light_color = col
				o.light_energy = light_energy(0.0)
				o.omni_range = 13
				root.add_child(o)
				lights.append(o)
	Level.label(root, "FLOOR %d" % int(d.number), Vector3(CELL * 0.5, EXP_Y + 2.6, 0.3), 72, col)
	return {"root": root, "maze": maze, "cab": cab, "lights": lights, "cells": cells, "floor": f}
