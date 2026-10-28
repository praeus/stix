class_name StixBrain
extends Node
## Drives a StixFigure in place of a player: it climbs the page to the
## nearest sword lying about, then hunts down its opponent and cuts at them.
## Routes come from a LedgeMap and are replanned whenever the figure lands
## somewhere new; between landings it sets the same controls the player's
## keys do (move_direction, running, jump, swing).

## Close enough to cut: horizontal and vertical distance to the opponent's feet.
const STRIKE_X := 46.0
const STRIKE_Y := 40.0
## How near it closes in before stopping, so it doesn't walk into them.
const KEEP_X := 30.0
## Seconds between swings, randomised in this range so it isn't metronomic.
const SWING_GAP := Vector2(0.55, 1.05)
## A move that hasn't worked this long after the walk to its takeoff should
## have taken is left out of routes for a while.
const STUCK_TIME := 3.0
const BLOCK_TIME := 6.0
const REPLAN_TIME := 0.4
## Runs to a takeoff point further away than this.
const RUN_TO := 150.0

## Off during cutscenes, and once either fighter is dead.
var active := false

var _figure: StixFigure
var _opponent: StixFigure
var _map: LedgeMap
## Callable returning the SwordPickups still lying on the page.
var _swords: Callable

var _move: Dictionary = {}
var _move_time := 0.0
var _move_allowed := 0.0
var _replan := 0.0
var _swing_wait := 0.0
## Where to steer while in the air; NAN when there's no plan for this fall.
var _air_x := NAN
## The move being flown (jumped or walked off), until the figure lands.
var _flying: Dictionary = {}
var _airborne := false
## "from>to" move keys left out of routes, with seconds until they're allowed again.
var _blocked := {}


func setup(figure: StixFigure, opponent: StixFigure, map: LedgeMap, swords: Callable) -> void:
	_figure = figure
	_opponent = opponent
	_map = map
	_swords = swords


func _physics_process(delta: float) -> void:
	if not active or _figure.is_dead():
		_stop()
		return
	for key in _blocked.keys():
		_blocked[key] -= delta
		if _blocked[key] <= 0.0:
			_blocked.erase(key)
	_swing_wait -= delta
	_replan -= delta
	_move_time += delta

	if _figure.state == StixFigure.State.TAKEOFF:
		return
	if not _figure.is_on_ground():
		_airborne = true
		_steer_in_air()
		return
	_air_x = NAN

	var target := _target()
	var here := _map.ledge_under(_figure)
	if _airborne:
		_airborne = false
		# A move that came down somewhere else is left out for a while, so a
		# wrong landing can't send it round in a loop.
		if not _flying.is_empty() and here != _flying.to:
			_blocked["%d>%d" % [_flying.from, _flying.to]] = BLOCK_TIME
			_move = {}
		_flying = {}
	var goal := _map.ledge_under(_opponent) if target == _opponent.global_position \
			else _map.ledge_below(target)
	if _move.is_empty() or _move.from != here or _replan <= 0.0:
		_plan(here, goal)
	if _move_time > _move_allowed and not _move.is_empty():
		_blocked["%d>%d" % [_move.from, _move.to]] = BLOCK_TIME
		_plan(here, goal)

	if _move.is_empty():
		_close_in(target, here)
	else:
		_follow_move()
	_try_strike()


## The nearest sword until it has one, then the opponent's feet.
func _target() -> Vector2:
	if not _figure.has_sword:
		var best := Vector2.INF
		for sword: Node2D in _swords.call():
			if _figure.global_position.distance_squared_to(sword.global_position) \
					< _figure.global_position.distance_squared_to(best):
				best = sword.global_position
		if best != Vector2.INF:
			return best
	return _opponent.global_position


func _plan(here: int, goal: int) -> void:
	_replan = REPLAN_TIME
	var route := _map.route(here, goal, _figure.health, _blocked)
	var next: Dictionary = route[0] if not route.is_empty() else {}
	if next.is_empty() or _move.is_empty() or next.from != _move.from or next.to != _move.to:
		_move_time = 0.0
		if not next.is_empty():
			_move_allowed = STUCK_TIME + absf(next.takeoff_x - _figure.global_position.x) / _figure.walk_speed
	_move = next


## On the target's ledge: walk up to it, and cut if it's the opponent.
func _close_in(target: Vector2, here: int) -> void:
	var dx := target.x - _figure.global_position.x
	var fighting := _figure.has_sword and not _opponent.is_dead()
	var stop := KEEP_X if fighting and target == _opponent.global_position else 3.0
	_figure.running = absf(dx) > 220.0
	if absf(dx) > stop:
		var to := target.x
		if here >= 0:
			var l := _map.ledges[here]
			to = clampf(to, l.x0 + LedgeMap.EDGE_GAP, l.x1 - LedgeMap.EDGE_GAP)
		_walk_to(to, 3.0)
	else:
		_figure.move_direction = 0.0


## Cuts at the opponent whenever they're in reach, whatever the plan is.
func _try_strike() -> void:
	if not _figure.has_sword or _opponent.is_dead():
		return
	var gap := _opponent.global_position - _figure.global_position
	if absf(gap.x) > STRIKE_X or absf(gap.y) > STRIKE_Y:
		return
	_figure.facing = 1 if gap.x >= 0.0 else -1
	if _swing_wait <= 0.0 and not _figure.is_swinging():
		_figure.swing()
		_swing_wait = randf_range(SWING_GAP.x, SWING_GAP.y)


func _follow_move() -> void:
	var x := _figure.global_position.x
	var move := _move
	_figure.running = move.run or absf(move.takeoff_x - x) > RUN_TO
	match move.kind:
		LedgeMap.Kind.WALK_OFF:
			# Keep walking until the floor runs out.
			_figure.move_direction = move.dir
			_air_x = move.land_x
			_flying = move
		LedgeMap.Kind.JUMP_UP:
			if _walk_to(move.takeoff_x, 4.0):
				_launch(move)
		LedgeMap.Kind.JUMP:
			# Jump so the takeoff crouch finishes right at the edge.
			var speed := _figure.run_speed if move.run else _figure.walk_speed
			var lead := speed * (0.09 if move.run else 0.22) + 2.0
			var to_edge: float = (move.takeoff_x - x) * move.dir
			if to_edge > lead:
				_figure.move_direction = move.dir
			elif to_edge >= -lead:
				_figure.move_direction = move.dir
				_launch(move)
			else:
				# Overshot back past it somehow: walk back first.
				_walk_to(move.takeoff_x - move.dir * lead * 2.0, 3.0)


func _launch(move: Dictionary) -> void:
	_air_x = move.land_x
	_flying = move
	_figure.jump()


func _steer_in_air() -> void:
	var to := _air_x if not is_nan(_air_x) else _target().x
	var dx := to - _figure.global_position.x
	_figure.move_direction = 0.0 if absf(dx) < 4.0 else signf(dx)


## Walks toward x; true once within reach of it (and stopped).
func _walk_to(x: float, within: float) -> bool:
	var dx := x - _figure.global_position.x
	if absf(dx) <= within:
		_figure.move_direction = 0.0
		return true
	_figure.move_direction = signf(dx)
	return false


func _stop() -> void:
	if _figure and not _figure.is_dead():
		_figure.move_direction = 0.0
		_figure.running = false
