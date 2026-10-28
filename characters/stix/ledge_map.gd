class_name LedgeMap
extends RefCounted
## The ledges of a page as a graph a computer-controlled figure can plan
## routes over. Each edge is one move: walking off an edge, a walking or
## running jump across a gap, or a jump straight up through a ledge
## overhead. Moves are judged with the figure's JumpArc, with some margin,
## and drops that would hurt cost more or are ruled out.

enum Kind { WALK_OFF, JUMP, JUMP_UP }

## Share of the theoretical jump reach a planned move may need. The AI
## jumps right from the edge and steers exactly, so it can cut it finer
## than a player (ClimbGenerator lays gaps out for 0.75).
const REACH_USE := 0.92
## How far onto a ledge a move aims to land, away from the end.
const LAND_IN := 14.0
## Same, for the far side of a jumped gap, where every px of reach counts.
const JUMP_LAND_IN := 8.0
## Margin kept from a ledge's end when standing on it.
const EDGE_GAP := 6.0
## How far past the end the feet are when a figure walking off starts to fall
## (its body is about this wide).
const WALK_OFF_AT := 6.0

## Each ledge: {x0, x1, y}.
var ledges: Array[Dictionary] = []
## The SketchPlatform for each ledge, by index.
var platforms: Array[Node] = []
## moves[i]: the moves leaving ledge i. Each move: {from, to, kind, dir,
## takeoff_x, land_x, run, fall, cost}. dir is the way to face (0 for
## straight up), takeoff_x where to stand or jump, land_x where to steer to.
var moves: Array = []

var _figure: StixFigure
var _walk_arc: JumpArc
var _run_arc: JumpArc


func _init(nodes: Array[Node], figure: StixFigure) -> void:
	_figure = figure
	_walk_arc = figure.get_jump_arc()
	_run_arc = figure.get_jump_arc(true)
	platforms = nodes.duplicate()
	for p: SketchPlatform in nodes:
		ledges.append({"x0": p.global_position.x, "x1": p.global_position.x + p.width,
				"y": p.global_position.y})
	for i in ledges.size():
		var out: Array[Dictionary] = []
		for j in ledges.size():
			if i != j:
				var move := _move(i, j)
				if not move.is_empty():
					out.append(move)
		moves.append(out)


## The ledge a figure is standing on, from what it touched underfoot this
## frame; falls back to ledge_below when it isn't touching one. (Its body
## is wider than a point, so near an end its position alone can be over
## the ledge below while it still stands on this one.)
func ledge_under(figure: StixFigure) -> int:
	for k in figure.get_slide_collision_count():
		var hit := figure.get_slide_collision(k)
		if hit.get_normal().y < -0.5:
			var index := platforms.find(hit.get_collider())
			if index >= 0:
				return index
	return ledge_below(figure.global_position)


## The ledge whose surface is at or just below pos (what a figure standing
## or falling there is over), or -1.
func ledge_below(pos: Vector2) -> int:
	var best := -1
	for i in ledges.size():
		var l := ledges[i]
		if pos.x >= l.x0 - 2.0 and pos.x <= l.x1 + 2.0 and l.y >= pos.y - 4.0:
			if best == -1 or l.y < ledges[best].y:
				best = i
	return best


## Cheapest list of moves from ledge start to ledge goal, avoiding falls that
## would cost health or more. Empty if already there or there's no way.
## blocked holds "from>to" keys of moves to leave out.
func route(start: int, goal: int, health: float, blocked := {}) -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	if start < 0 or goal < 0 or start == goal:
		return none
	var cost := {start: 0.0}
	var via := {}
	var open := [start]
	var done := {}
	while not open.is_empty():
		var best := 0
		for k in open.size():
			if cost[open[k]] < cost[open[best]]:
				best = k
		var here: int = open[best]
		open.remove_at(best)
		if here == goal:
			break
		done[here] = true
		for move: Dictionary in moves[here]:
			var damage := _figure.fall_damage(move.fall)
			if damage >= health or blocked.has("%d>%d" % [here, move.to]) or done.has(move.to):
				continue
			var c: float = cost[here] + move.cost + damage * 0.2
			if not cost.has(move.to) or c < cost[move.to]:
				cost[move.to] = c
				via[move.to] = move
				if not move.to in open:
					open.append(move.to)
	if not via.has(goal):
		return none
	var path: Array[Dictionary] = []
	var at := goal
	while at != start:
		var move: Dictionary = via[at]
		path.push_front(move)
		at = move.from
	return path


func _move(i: int, j: int) -> Dictionary:
	var a := ledges[i]
	var b := ledges[j]
	var rise: float = a.y - b.y
	var overlap: bool = b.x0 < a.x1 and a.x0 < b.x1
	var height := _walk_arc.height

	if overlap and rise > 0.0:
		# Straight up through the ledge overhead, from under the shared part.
		if rise > _walk_arc.max_rise(height * 0.12):
			return {}
		var x := clampf((maxf(a.x0, b.x0) + minf(a.x1, b.x1)) * 0.5, a.x0 + EDGE_GAP, a.x1 - EDGE_GAP)
		var up_land := clampf(x, b.x0 + LAND_IN, b.x1 - LAND_IN)
		if not _lands_on(j, Vector2(x, a.y), _walk_arc.launch_speed, _walk_arc.run_speed, up_land):
			return {}
		return _make(i, j, Kind.JUMP_UP, 0, x, up_land, false, height - rise, 1.0)

	if overlap:
		# Down onto a lower ledge: walk off whichever end of this one it
		# reaches past, or, if it's tucked right underneath, off the nearer
		# end and steer back in under.
		var drop := -rise
		var dir := 1 if b.x1 > a.x1 else (-1 if b.x0 < a.x0 else 0)
		var land_x: float
		if dir == 0:
			dir = 1 if a.x1 - b.x1 < b.x0 - a.x0 else -1
			land_x = b.x1 - LAND_IN if dir > 0 else b.x0 + LAND_IN
			var back: float = (a.x1 - land_x) if dir > 0 else (land_x - a.x0)
			if drop < _figure.get_height() * 0.6 or back > _walk_arc.run_speed * sqrt(2.0 * drop / _walk_arc.gravity) * 0.6:
				return {}
		else:
			land_x = clampf((a.x1 if dir > 0 else a.x0) + dir * LAND_IN * 1.5, b.x0 + LAND_IN, b.x1 - LAND_IN)
		var edge: float = a.x1 if dir > 0 else a.x0
		if not _lands_on(j, Vector2(edge + dir * WALK_OFF_AT, a.y), 0.0, _walk_arc.run_speed, land_x):
			return {}
		return _make(i, j, Kind.WALK_OFF, dir, edge + dir * 10.0, land_x, false, drop, 1.0)

	# Across a gap, up or down.
	var dir := 1 if b.x0 >= a.x1 else -1
	var edge: float = a.x1 if dir > 0 else a.x0
	var near: float = b.x0 if dir > 0 else b.x1
	var gap := absf(near - edge)
	var land_x := clampf(near + dir * JUMP_LAND_IN, b.x0 + JUMP_LAND_IN * 0.5, b.x1 - JUMP_LAND_IN * 0.5)
	var needed := absf(land_x - edge)
	if rise <= 0.0:
		var fall_time := sqrt(2.0 * -rise / _walk_arc.gravity)
		if needed <= _walk_arc.run_speed * fall_time * 0.6 \
				and _lands_on(j, Vector2(edge + dir * WALK_OFF_AT, a.y), 0.0, _walk_arc.run_speed, land_x):
			return _make(i, j, Kind.WALK_OFF, dir, edge + dir * 10.0, land_x, false, -rise, 1.0 + gap / 400.0)
	if rise > _walk_arc.max_rise(height * 0.12):
		return {}
	var run := needed > _walk_arc.reach(rise) * REACH_USE
	if run and needed > _run_arc.reach(rise) * REACH_USE:
		return {}
	var arc := _run_arc if run else _walk_arc
	if not _lands_on(j, Vector2(edge, a.y), arc.launch_speed, arc.run_speed, land_x):
		return {}
	return _make(i, j, Kind.JUMP, dir, edge, land_x, run, height - rise, 1.2 + gap / 300.0 + (0.4 if run else 0.0))


func _make(i: int, j: int, kind: Kind, dir: int, takeoff_x: float, land_x: float, run: bool,
		fall: float, cost: float) -> Dictionary:
	return {"from": i, "to": j, "kind": kind, "dir": dir, "takeoff_x": takeoff_x,
			"land_x": land_x, "run": run, "fall": maxf(fall, 0.0), "cost": cost}


## Flies the move as the AI will (launch, then steering straight for land_x
## at speed) and checks that the first ledge the feet come down on is
## ledge j, not one in the way.
func _lands_on(j: int, from: Vector2, launch: float, speed: float, land_x: float) -> bool:
	var pos := from
	var vy := -launch
	var dt := 1.0 / 60.0
	for step in 360:
		var dx := land_x - pos.x
		var next := Vector2(pos.x + clampf(dx, -speed * dt, speed * dt), pos.y + vy * dt)
		vy += _walk_arc.gravity * dt
		if next.y > pos.y:
			# One-way ledges catch the feet as they come down through the top.
			for k in ledges.size():
				var l := ledges[k]
				if pos.y <= l.y and next.y > l.y and next.x >= l.x0 and next.x <= l.x1:
					return k == j
		pos = next
	return false
