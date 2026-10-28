class_name PageLevel
extends Node2D
## A notepad-page level: the Stix figure starts bottom-left in the margin and
## climbs ledges to the top of the page. Ledges sit on the page's ruled lines
## and are laid out by ClimbGenerator from the figure's jump arc, so every
## page can be climbed. Jumping off the top of the page wins: the figure rips
## the sheet off the pad, and the next page is pencilled in underneath.
## Escape pauses and shows the whole page beside a menu.

## Share of the jump height kept spare above a ledge the figure must land on.
const JUMP_CLEARANCE := 0.13
## Share of the jump a player can be relied on to use when jumping off the
## top of the page, which decides how high the path has to climb.
const WIN_JUMP_USE := 0.75
## Share of the screen width the page takes up when zoomed out to see all of
## it, and where its centre sits (the pause view leaves the right for the menu).
const MAP_WIDTH := 0.55
const PAUSE_CENTER_X := 0.33

## Seed the next page should reuse ("Retry this page"). Survives the scene
## reload because it lives on the script.
static var _retry_seed := 0
## Set by winning, so the reloaded scene pencils its page in.
static var _draw_in_next := false
## The score when the current page began. Winning carries the score on to
## the next page; dying or retrying goes back to this.
static var _page_start_score := 0

const STIX_SCENE := preload("res://characters/stix/stix_figure.tscn")
const KILL_POINTS := 10
const PAGE_POINTS := 100
## One sword each: whoever reaches one first takes it.
const SWORD_COUNT := 2
## Seconds after a rival dies before the next one is pencilled in.
const RESPAWN_DELAY := 2.0
## A new rival appears at least this far from the player, where the page allows.
const RESPAWN_DISTANCE := 450.0

## Fixed seed for repeating a page while testing; 0 picks a new page every run.
@export var level_seed := 0
@export var side_ledges := 8

var page_seed := 0

var _pause_menu: PauseMenu
var _health_bar: HealthBar
var _score: ScoreDisplay
var _blood: BloodSpray
var _swords: Array[SwordPickup] = []
## The computer-controlled figure that hunts the player.
var _rival: StixFigure
var _rival_brain: StixBrain

@onready var _page: NotebookPage = $Page
@onready var _platforms: Node2D = $Platforms
@onready var _figure: StixFigure = $StixFigure
@onready var _camera: Camera2D = $StixFigure/Camera2D


func _ready() -> void:
	var floor_rule := _page.bottom_rule()
	var floor_y := _page.rule_y(floor_rule)
	add_platform(0.0, floor_y, _page.size.x, false)
	_figure.position = Vector2(_page.margin_x * 0.5, floor_y)

	if level_seed != 0:
		page_seed = level_seed
	elif _retry_seed != 0:
		page_seed = _retry_seed
		_retry_seed = 0
	else:
		page_seed = randi()
	var climb := ClimbGenerator.new(_page, _figure.get_jump_arc(), _figure.get_jump_arc(true),
			max_rules_up())
	climb.generate(page_seed, floor_rule, goal_rule(), side_ledges)
	for ledge in climb.ledges:
		add_platform(ledge.x, _page.rule_y(ledge.rule), ledge.width)
	print("Page seed %d: %d ledges" % [page_seed, climb.ledges.size()])
	_add_swords(climb.ledges)

	_add_page_edges()

	_camera.position = _camera_offset()
	_camera.limit_left = 0
	_camera.limit_top = 0
	_camera.limit_right = int(_page.size.x)
	_camera.limit_bottom = int(_page.size.y)
	_camera.reset_smoothing()
	# Keep easing the camera to the page view while the game is paused.
	_camera.process_mode = Node.PROCESS_MODE_ALWAYS

	# Stains are drawn on the paper so they stay with it when it's torn off.
	var stains := Node2D.new()
	stains.name = "BloodStains"
	_page.add_child(stains)
	_blood = BloodSpray.new()
	_blood.name = "Blood"
	add_child(_blood)
	_blood.stain_layer = stains
	_figure.blood = _blood
	_figure.died.connect(_on_figure_died)
	# Blue to the rival's red.
	var band := Headband.new()
	band.color = Color("1f4fa8")
	_figure.get_node("Skeleton2D").find_child("Head").add_child(band)
	# Seeded by the page, so a retry starts the rival in the same place.
	var rival_rng := RandomNumberGenerator.new()
	rival_rng.seed = hash([page_seed, "rival"])
	_add_rival(_spot_away_from_player(rival_rng, 60.0))

	_score = ScoreDisplay.new()
	_score.score = _page_start_score
	add_child(_score)

	_health_bar = HealthBar.new()
	add_child(_health_bar)
	_figure.health_changed.connect(_health_bar.set_health)

	_pause_menu = PauseMenu.new()
	_pause_menu.page_title = "page %d" % page_seed
	_pause_menu.paused_changed.connect(_set_pause_view)
	_pause_menu.retry_requested.connect(_load_page.bind(true))
	_pause_menu.new_page_requested.connect(_load_page.bind(false))
	add_child(_pause_menu)

	if _draw_in_next:
		_draw_in_next = false
		_draw_page_in()


## How many ruled lines up the figure can jump from one ledge to the next.
func max_rules_up() -> int:
	var arc := _figure.get_jump_arc()
	return maxi(1, floori(arc.max_rise(arc.height * JUMP_CLEARANCE) / _page.rule_spacing))


## Highest rule the path climbs to: close enough to the top of the paper that
## a jump from it carries the figure's head clear of the top edge.
func goal_rule() -> int:
	var reach := _figure.get_height() + _figure.get_jump_arc().height * WIN_JUMP_USE
	return clampi(floori((reach - _page.header_height) / _page.rule_spacing), 0, _page.bottom_rule())


## The following camera looks a little above the figure's feet.
func _camera_offset() -> Vector2:
	return Vector2(0, -_figure.get_height() * 0.5)


func add_platform(x: float, y: float, width: float, one_way := true) -> SketchPlatform:
	var platform := SketchPlatform.new()
	platform.position = Vector2(x, y)
	platform.width = width
	platform.one_way = one_way
	platform.sketch_seed = _platforms.get_child_count()
	_platforms.add_child(platform)
	return platform


## Sticks swords into ledges picked by the page seed, so retrying a page
## puts them back in the same places. They go on different ledges, well
## apart where the page allows.
func _add_swords(ledges: Array[ClimbGenerator.Ledge]) -> void:
	var wide := ledges.filter(func(l: ClimbGenerator.Ledge) -> bool: return l.width >= 70.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([page_seed, "sword"])
	for n in SWORD_COUNT:
		if wide.is_empty():
			return
		var ledge: ClimbGenerator.Ledge = wide[rng.randi_range(0, wide.size() - 1)]
		var spot := Vector2(rng.randf_range(ledge.x + 25.0, ledge.end - 25.0), _page.rule_y(ledge.rule))
		for tries in 20:
			if _swords.all(func(s: SwordPickup) -> bool: return s.position.distance_to(spot) > 300.0):
				break
			ledge = wide[rng.randi_range(0, wide.size() - 1)]
			spot = Vector2(rng.randf_range(ledge.x + 25.0, ledge.end - 25.0), _page.rule_y(ledge.rule))
		wide.erase(ledge)
		_add_sword(spot)


func _add_sword(spot: Vector2) -> SwordPickup:
	var sword := SwordPickup.new()
	sword.name = "Sword"
	sword.position = spot
	add_child(sword)
	# Under the ledges, so the line is drawn over where the blade goes in.
	move_child(sword, _platforms.get_index())
	_swords.append(sword)
	return sword


## Swords still stuck in the page, waiting to be picked up.
func lying_swords() -> Array[SwordPickup]:
	# Picked-up swords are freed after fading, so drop those before looking.
	_swords = _swords.filter(func(s) -> bool: return is_instance_valid(s))
	return _swords.filter(func(s: SwordPickup) -> bool: return not s.taken)


## A second figure in a red headband, standing at spot. It goes for a
## sword, then for the player, and when it dies another takes its place.
func _add_rival(spot: Vector2) -> void:
	_rival = STIX_SCENE.instantiate()
	_rival.name = "Rival"
	_rival.position = spot
	add_child(_rival)
	move_child(_rival, _figure.get_index())
	_rival.facing = 1 if _figure.position.x > spot.x else -1
	_rival.died.connect(_on_rival_died)
	_rival.blood = _blood
	_rival.get_node("Skeleton2D").find_child("Head").add_child(Headband.new())
	_rival.add_child(OverheadHealthBar.new())
	_rival_brain = StixBrain.new()
	_rival_brain.name = "Brain"
	_rival.add_child(_rival_brain)
	_rival_brain.setup(_rival, _figure, LedgeMap.new(_platforms.get_children(), _rival), lying_swords)
	_rival_brain.active = true


func _on_rival_died() -> void:
	_score.add(KILL_POINTS)
	# Not process-always, so the wait holds while the game is paused.
	get_tree().create_timer(RESPAWN_DELAY, false).timeout.connect(_respawn_rival)


## Pencils a new rival in on a ledge away from the player, plus a sword for
## it if none are left lying about (a dead rival's sword flies off broken).
func _respawn_rival() -> void:
	# Not if the player died meanwhile, or the page is being torn off.
	if _figure.is_dead() or not is_processing():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var appearing: Array[Node2D] = []
	if lying_swords().is_empty():
		appearing.append(_add_sword(_spot_away_from_player(rng, 70.0)))
	var old := _rival
	_add_rival(_spot_away_from_player(rng, 60.0))
	old.queue_free()
	appearing.append(_rival)
	_rival_brain.active = false
	var tween := create_tween().set_parallel(true)
	for node in appearing:
		node.modulate.a = 0.0
		tween.tween_property(node, ^"modulate:a", 1.0, 0.5)
	tween.chain().tween_callback(func() -> void: _rival_brain.active = is_processing())


## A random spot on a ledge at least min_width wide, as far from the player
## as RESPAWN_DISTANCE if any is, otherwise the farthest one tried.
func _spot_away_from_player(rng: RandomNumberGenerator, min_width: float) -> Vector2:
	var ledges := _platforms.get_children().filter(
			func(p: SketchPlatform) -> bool: return p.width >= min_width)
	var best := Vector2.ZERO
	for tries in 30:
		var ledge: SketchPlatform = ledges[rng.randi_range(0, ledges.size() - 1)]
		var spot := ledge.position + Vector2(rng.randf_range(25.0, ledge.width - 25.0), 0.0)
		if spot.distance_to(_figure.position) > best.distance_to(_figure.position) or tries == 0:
			best = spot
		if best.distance_to(_figure.position) >= RESPAWN_DISTANCE:
			break
	return best


## Invisible walls down both sides of the paper so the figure can't run off it.
func _add_page_edges() -> void:
	var edges := StaticBody2D.new()
	edges.name = "PageEdges"
	for side in [[Vector2.RIGHT, 0.0], [Vector2.LEFT, _page.size.x]]:
		var wall := WorldBoundaryShape2D.new()
		wall.normal = side[0]
		var shape := CollisionShape2D.new()
		shape.shape = wall
		shape.position.x = side[1]
		edges.add_child(shape)
	add_child(edges)


## Camera zoom and centre that fit the whole page on screen, with the page's
## centre at center_x across the screen.
func _page_view(center_x: float) -> Dictionary:
	var view := get_viewport_rect().size
	var zoom := minf(view.x * MAP_WIDTH / _page.size.x, view.y * 0.94 / _page.size.y)
	return {
		"zoom": Vector2.ONE * zoom,
		"center": _page.size * 0.5 + Vector2((0.5 - center_x) * view.x / zoom, 0.0),
	}


## Where the following camera ends up for the figure's current spot, once
## the page limits clamp it.
func _follow_center() -> Vector2:
	var half := get_viewport_rect().size * 0.5
	var target := _figure.global_position + _camera_offset()
	return target.clamp(half, _page.size - half)


## Zooms out to show the whole page beside the pause menu, or back to
## following the figure.
func _set_pause_view(on: bool) -> void:
	_camera.limit_enabled = not on
	if not on:
		_camera.zoom = Vector2.ONE
		_camera.position = _camera_offset()
		return
	var view := _page_view(PAUSE_CENTER_X)
	_camera.zoom = view.zoom
	# The figure is frozen while paused, so placing the camera once is enough.
	_camera.global_position = view.center


func _load_page(same_page: bool) -> void:
	_retry_seed = page_seed if same_page else 0
	# A won page keeps its points; skipping to a new page from the menu
	# starts the score over.
	if _draw_in_next:
		_page_start_score = _score.score
	elif not same_page:
		_page_start_score = 0
	get_tree().paused = false
	get_tree().reload_current_scene()


## Holds the player's controls and the pause menu during a cutscene.
func _set_playing(on: bool) -> void:
	set_process(on)
	_pause_menu.enabled = on
	_health_bar.visible = on
	_rival_brain.active = on
	_camera.position_smoothing_enabled = on
	_camera.limit_enabled = on


## The figure has jumped its head clear of the top edge: it grabs the paper
## and rips the whole sheet off the pad, revealing a blank page underneath.
func _tear_off_page() -> void:
	_set_playing(false)
	_score.add(PAGE_POINTS)
	_figure.hang()
	_rival.set_physics_process(false)
	# Loose body parts are moved by physics, not their parent; pin them to
	# the sheet so they go with it.
	get_tree().call_group(&"body_parts", &"set", &"freeze", true)
	var grip := Vector2(_figure.global_position.x, 0.0)

	# The camera stays behind with the pad while the sheet flies off.
	_camera.reparent(self)
	var next_page := NotebookPage.new()
	add_child(next_page)
	move_child(next_page, 0)

	# Everything on the old sheet goes with it, swinging about the grip point.
	var sheet := Node2D.new()
	sheet.name = "TornSheet"
	sheet.position = grip
	add_child(sheet)
	# Everything drawn on or over the page: swords, both figures, remains, blood.
	for node in get_children():
		if node is Node2D and node != sheet and node != next_page and node != _camera:
			node.reparent(sheet)

	var view := _page_view(0.5)
	var tilt := 0.14 * signf(grip.x - _page.size.x * 0.5)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_camera, ^"zoom", view.zoom, 0.7)
	tween.parallel().tween_property(_camera, ^"global_position", view.center, 0.7)
	tween.tween_callback(func() -> void: _page.torn = true)
	# A tug down as the perforations give, then the sheet rips free and is
	# carried up off the top of the screen.
	tween.tween_property(sheet, ^"position:y", 18.0, 0.14).set_ease(Tween.EASE_OUT)
	tween.tween_property(sheet, ^"position:y", -_page.size.y * 1.7, 1.0) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(sheet, ^"rotation", tilt, 1.0)
	tween.tween_interval(0.3)
	tween.tween_callback(func() -> void:
		_draw_in_next = true
		_load_page(false))


## Starts on a blank page seen whole, pencils the ledges in from the bottom
## up, draws the figure in at the start, then zooms back in to play.
func _draw_page_in() -> void:
	_set_playing(false)
	_figure.set_physics_process(false)
	var drawn_last: Array[Node2D] = [_figure, _rival]
	drawn_last.append_array(_swords)
	for node in drawn_last:
		node.modulate.a = 0.0
	var view := _page_view(0.5)
	_camera.zoom = view.zoom
	_camera.global_position = view.center

	var ledges := _platforms.get_children()
	# Bottom first, which also puts the floor first.
	ledges.sort_custom(func(a: Node2D, b: Node2D) -> bool: return a.position.y > b.position.y)
	var tween := create_tween().set_parallel(true)
	var start := 0.35
	for ledge: SketchPlatform in ledges:
		ledge.reveal = 0.0
		var duration := clampf(ledge.width / 500.0, 0.18, 0.7)
		tween.tween_property(ledge, ^"reveal", 1.0, duration).set_delay(start)
		start += duration * 0.9 if ledge == ledges[0] else 0.09
	for node in drawn_last:
		tween.tween_property(node, ^"modulate:a", 1.0, 0.4).set_delay(start + 0.3)
	start += 0.9
	tween.tween_property(_camera, ^"zoom", Vector2.ONE, 0.9).set_delay(start) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_camera, ^"global_position", _follow_center(), 0.9).set_delay(start) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.chain().tween_callback(func() -> void:
		_camera.position = _camera_offset()
		_figure.set_physics_process(true)
		_set_playing(true)
		_camera.reset_smoothing())


## The figure has broken apart. Let the pieces land and the blood settle,
## then start the same page over.
func _on_figure_died() -> void:
	set_process(false)
	_rival_brain.active = false
	_pause_menu.enabled = false
	get_tree().create_timer(2.6).timeout.connect(_load_page.bind(true))


func _process(_delta: float) -> void:
	_figure.move_direction = Input.get_axis(&"move_left", &"move_right")
	_figure.running = Input.is_action_pressed(&"run")
	if Input.is_action_just_pressed(&"jump"):
		_figure.jump()
	if Input.is_action_just_pressed(&"attack"):
		_figure.swing()
	if _figure.global_position.y - _figure.get_height() < 0.0:
		_tear_off_page()
