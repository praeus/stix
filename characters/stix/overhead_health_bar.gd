class_name OverheadHealthBar
extends Node2D
## A small pencilled health bar floating over a figure's head, filled with
## red ink scribble. Add it as a child of the figure; it follows the
## figure's health_changed signal and hides once the figure dies.

const SIZE := Vector2(40, 6)
const GAP := 12.0

var _ratio := 1.0
var _frame: Array[Dictionary] = []
var _hatch: Array[Dictionary] = []


func _ready() -> void:
	var figure := get_parent() as StixFigure
	position = Vector2(-SIZE.x * 0.5, -figure.get_height() - GAP - SIZE.y)
	figure.health_changed.connect(func(health: float, max_health: float) -> void:
		_ratio = clampf(health / max_health, 0.0, 1.0)
		queue_redraw())
	figure.died.connect(hide)

	var rng := RandomNumberGenerator.new()
	rng.seed = 29
	var r := Rect2(Vector2.ZERO, SIZE)
	var corners := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for i in 4:
		_frame.append(PencilSketch.stroke(rng, corners[i], corners[(i + 1) % 4], 1.4, 0.8, 0.3))
	var x := 1.0
	while x < SIZE.x - 1.0:
		_hatch.append(PencilSketch.stroke(rng, Vector2(x, SIZE.y - 1.0), Vector2(x + 2.5, 1.0),
				1.4, rng.randf_range(0.75, 1.0), 0.2))
		x += 2.2


func _draw() -> void:
	var fill := (SIZE.x - 2.0) * _ratio
	for s in _hatch:
		# Only the strokes inside the filled part.
		if s.outline[0].x <= fill:
			draw_colored_polygon(s.outline, Color(HealthBar.RED, s.alpha))
	PencilSketch.draw_strokes(self, _frame)
