class_name HealthBar
extends CanvasLayer
## A pencilled box in the top-left corner, hatched in red ink for the health
## left. Health that was just lost shows paler for a moment before it drains
## away, and the bar jolts when hit.

const BAR_SIZE := Vector2(200, 20)
const ORIGIN := Vector2(28, 22)
const RED := Color("b3121b")

var _frame: Frame
var _fill: Control
var _lost: Control
var _ratio := 1.0


func _ready() -> void:
	layer = 5
	var label := Label.new()
	label.text = "health"
	label.position = ORIGIN
	label.add_theme_font_size_override(&"font_size", 18)
	label.add_theme_color_override(&"font_color", Color(PencilSketch.INK, 0.7))
	add_child(label)

	_frame = Frame.new()
	_frame.position = ORIGIN + Vector2(0, 28)
	_frame.size = BAR_SIZE
	add_child(_frame)
	# Pale "just lost" hatching under the real one; each clips its hatch to its width.
	_lost = _hatched(Color(RED, 0.35))
	_fill = _hatched(RED)


func set_health(health: float, max_health: float) -> void:
	var ratio := clampf(health / max_health, 0.0, 1.0)
	var inner := _inner_width()
	if ratio < _ratio:
		var jolt := create_tween()
		for x: float in [6.0, -4.0, 2.0, 0.0]:
			jolt.tween_property(_frame, ^"position:x", ORIGIN.x + x, 0.05)
		var drain := create_tween()
		drain.tween_interval(0.45)
		drain.tween_property(_lost, ^"size:x", inner * ratio, 0.5).set_ease(Tween.EASE_IN)
	else:
		_lost.size.x = inner * ratio
	_fill.size.x = inner * ratio
	_ratio = ratio


func _inner_width() -> float:
	return BAR_SIZE.x - 8.0


func _hatched(color: Color) -> Control:
	var clip := Control.new()
	clip.clip_contents = true
	clip.position = Vector2(4, 4)
	clip.size = Vector2(_inner_width(), BAR_SIZE.y - 8.0)
	var hatch := Hatch.new()
	hatch.color = color
	hatch.size = clip.size
	clip.add_child(hatch)
	_frame.add_child(clip)
	return clip


## The pencil box around the bar.
class Frame extends Control:
	var _strokes: Array[Dictionary] = []

	func _ready() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = 23
		var r := Rect2(Vector2.ZERO, size)
		var corners := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
		for i in 4:
			_strokes.append_array(PencilSketch.sketch_line(rng, corners[i], corners[(i + 1) % 4], 2.2))

	func _draw() -> void:
		PencilSketch.draw_strokes(self, _strokes)


## Quick diagonal ink strokes filling the control, like colouring in.
class Hatch extends Control:
	var color := RED
	var _strokes: Array[Dictionary] = []

	func _ready() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = 41
		var x := -size.y
		while x < size.x + 2.0:
			_strokes.append(PencilSketch.stroke(rng, Vector2(x, size.y + 1.0),
					Vector2(x + size.y * 0.8, -1.0), 2.4, rng.randf_range(0.75, 1.0), 0.5))
			x += rng.randf_range(3.0, 4.5)

	func _draw() -> void:
		PencilSketch.draw_strokes(self, _strokes, color)
