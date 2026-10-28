class_name Headband
extends Node2D
## A red cloth band round the head with two tails flapping out behind, drawn
## in ink. Goes on a StixFigure's Head bone, in its art space: the head circle
## is centred HEAD_CENTER from the bone and the art faces +x, so the knot
## and tails are on the -x side and turn with the head.

const HEAD_CENTER := Vector2(0, -21)
const HEAD_RADIUS := 19.0

var color := Color("b3121b")

var _time := randf() * 10.0


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _draw() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var y := HEAD_CENTER.y - 7.0
	var half := sqrt(HEAD_RADIUS * HEAD_RADIUS - 7.0 * 7.0) + 1.0
	var knot := Vector2(-half + 1.0, y + 1.0)
	var strokes: Array[Dictionary] = [
		PencilSketch.stroke(rng, Vector2(half, y - 1.5), knot, 5.5, 0.95, 0.4),
		PencilSketch.stroke(rng, Vector2(half - 2.0, y + 1.5), knot + Vector2(0, 2), 3.0, 0.6, 0.6),
	]
	# Tails ripple as if in the wind of moving.
	for tail: Vector2 in [Vector2(-22, 3.0), Vector2(-17, 10.0)]:
		var wave := sin(_time * 9.0 + tail.y) * 3.0
		var mid := knot + Vector2(tail.x * 0.5, tail.y * 0.4 + wave)
		var end := knot + Vector2(tail.x, tail.y + wave * 1.6)
		strokes.append(PencilSketch.stroke(rng, knot, mid, 4.5, 0.9, 0.3))
		strokes.append(PencilSketch.stroke(rng, mid, end, 3.5, 0.85, 0.3))
	PencilSketch.draw_strokes(self, strokes, color)
