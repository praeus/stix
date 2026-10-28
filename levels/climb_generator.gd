class_name ClimbGenerator
extends RefCounted
## Lays out a climb of ledges from the bottom of a NotebookPage to the top.
## Every ledge on the main path is one jump from the ledge before it, judged
## with the figure's JumpArc, so the page can always be finished. Side ledges
## branch off ledges that already exist, the same way, so they are reachable
## too. The layout is pure data (rule index + x span), and the same seed
## always gives the same page.

## How much of the theoretical jump reach a gap may use, leaving room for
## imperfect timing.
const REACH_USE := 0.75
const MIN_WIDTH := 60.0
const MAX_WIDTH := 200.0
## Smallest gap between the end of one ledge and the start of the next.
const MIN_GAP := 10.0
## A gap that needs a running jump only goes after a ledge at least this wide,
## so there is room for a run-up.
const RUN_UP := 100.0
## Ledges on the same or neighbouring rules keep at least this much air between them.
const SPACING := 40.0
const ATTEMPTS := 24
## Chance per step that the path doubles back the other way.
const TURN_CHANCE := 0.2


class Ledge:
	var rule: int
	var x: float
	var width: float
	var on_path: bool
	## The gap leading to this ledge is too wide for a walking jump.
	var needs_run := false

	var end: float:
		get:
			return x + width

	func _init(p_rule: int, p_x: float, p_width: float, p_on_path: bool) -> void:
		rule = p_rule
		x = p_x
		width = p_width
		on_path = p_on_path


var ledges: Array[Ledge] = []

var _page: NotebookPage
var _walk_arc: JumpArc
var _run_arc: JumpArc
var _max_rules_up: int
var _rng := RandomNumberGenerator.new()


func _init(page: NotebookPage, walk_arc: JumpArc, run_arc: JumpArc, max_rules_up: int) -> void:
	_page = page
	_walk_arc = walk_arc
	_run_arc = run_arc
	_max_rules_up = max_rules_up


## Builds the climb from the floor at floor_rule up to goal_rule. The last
## ledge in the returned list's path is the goal.
func generate(page_seed: int, floor_rule: int, goal_rule: int, side_ledges := 8) -> Array[Ledge]:
	_rng.seed = page_seed
	ledges.clear()

	# The floor runs the full width, but the figure starts in the margin, so
	# measure the first jump from the margin's edge.
	var prev := Ledge.new(floor_rule, 0.0, _page.margin_x, true)
	var dir := 1
	while prev.rule > goal_rule:
		if _rng.randf() < TURN_CHANCE:
			dir = -dir
		var next := _step_from(prev, dir, goal_rule, floor_rule, true)
		if next == null:
			push_warning("ClimbGenerator: path stuck at rule %d (seed %d)" % [prev.rule, page_seed])
			break
		dir = 1 if next.x + next.width * 0.5 >= prev.x + prev.width * 0.5 else -1
		ledges.append(next)
		prev = next

	for i in side_ledges if not ledges.is_empty() else 0:
		var from := ledges[_rng.randi_range(0, ledges.size() - 1)]
		var side := _step_from(from, -1 if _rng.randf() < 0.5 else 1, 0, floor_rule, false)
		if side != null:
			ledges.append(side)
	return ledges


## The final ledge of the main path.
func goal() -> Ledge:
	for i in range(ledges.size() - 1, -1, -1):
		if ledges[i].on_path:
			return ledges[i]
	return null


## A new ledge one jump away from prev, or null if nothing fits.
func _step_from(prev: Ledge, dir: int, top_rule: int, floor_rule: int, on_path: bool) -> Ledge:
	var lo := _page.margin_x
	var hi := _page.size.x - 12.0
	for attempt in ATTEMPTS:
		# Try the preferred direction first, then the other way.
		var d := dir if attempt * 2 < ATTEMPTS else -dir
		var rise := _pick_rise(on_path)
		var rule := maxi(prev.rule - rise, top_rule)
		rise = prev.rule - rule
		if rise == 0 or rule >= floor_rule:
			continue
		var width := _rng.randf_range(MIN_WIDTH, MAX_WIDTH)
		var gap := _pick_gap(prev, rise * _page.rule_spacing, width)
		var x: float = prev.end + gap.x if d > 0 else prev.x - gap.x - width
		if x < lo or x + width > hi:
			continue
		var ledge := Ledge.new(rule, x, width, on_path)
		ledge.needs_run = gap.y > 0.0
		if _fits(ledge, prev):
			return ledge
	return null


## Rules to climb in one jump. Side ledges can also step down.
func _pick_rise(on_path: bool) -> int:
	if not on_path and _rng.randf() < 0.35:
		return -_rng.randi_range(1, 2)
	var roll := _rng.randf()
	if roll < 0.15:
		return 1
	if roll < 0.5:
		return mini(2, _max_rules_up)
	return _max_rules_up


## Edge-to-edge gap (x) to the next ledge, and whether it needs a run (y > 0).
## A negative gap tucks the next ledge over the end of this one, so the
## figure jumps straight up through it.
func _pick_gap(prev: Ledge, rise: float, width: float) -> Vector2:
	var walk_max := _walk_arc.reach(rise) * REACH_USE
	var roll := _rng.randf()
	if roll < 0.2:
		return Vector2(-_rng.randf_range(12.0, minf(prev.width, width) * 0.6), 0.0)
	if roll < 0.4 and prev.width >= RUN_UP:
		var run_max := _run_arc.reach(rise) * REACH_USE
		return Vector2(_rng.randf_range(walk_max, run_max), 1.0)
	return Vector2(_rng.randf_range(MIN_GAP, maxf(walk_max, MIN_GAP)), 0.0)


## The ledge being jumped from is exempt: one-rule steps sit right next to it.
func _fits(ledge: Ledge, from: Ledge) -> bool:
	for other in ledges:
		if other != from and absi(other.rule - ledge.rule) <= 1 \
				and ledge.x < other.end + SPACING and other.x < ledge.end + SPACING:
			return false
	return true
