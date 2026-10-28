@tool
class_name SketchPlatform
extends StaticBody2D
## A pencil-drawn ledge: a sketchy line with light hatching underneath. The
## origin is the left end of the walking surface; the surface runs along +x.

## Collision depth below the surface line.
const THICKNESS := 12.0
const LINE_WIDTH := 3.6
const HATCH_SPACING := 14.0

@export var width := 200.0:
	set(value):
		width = maxf(value, 8.0)
		_rebuild()
## One-way ledges can be jumped up through from below and only hold you from above.
@export var one_way := true:
	set(value):
		one_way = value
		_rebuild()
## Changes the hand-drawn wobble without changing the shape.
@export var sketch_seed := 0:
	set(value):
		sketch_seed = value
		_rebuild()

## How much of the ledge has been pencilled in, left to right, for drawing a
## new page in. Anything below 1 masks off the rest of the line.
var reveal := 1.0:
	set(value):
		reveal = clampf(value, 0.0, 1.0)
		# This node draws only the mask; the strokes live on the Ink child.
		clip_children = CLIP_CHILDREN_ONLY if reveal < 1.0 else CLIP_CHILDREN_DISABLED
		queue_redraw()

var _strokes: Array[Dictionary] = []
var _ink: Node2D


func _ready() -> void:
	_ink = Node2D.new()
	_ink.name = "Ink"
	_ink.draw.connect(func() -> void: PencilSketch.draw_strokes(_ink, _strokes))
	add_child(_ink)
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var shape_node := get_node_or_null(^"Collision") as CollisionShape2D
	if shape_node == null:
		# Built in code rather than saved, so it always matches width.
		shape_node = CollisionShape2D.new()
		shape_node.name = "Collision"
		add_child(shape_node)
	var rect := RectangleShape2D.new()
	rect.size = Vector2(width, THICKNESS)
	shape_node.shape = rect
	shape_node.position = Vector2(width * 0.5, THICKNESS * 0.5)
	shape_node.one_way_collision = one_way

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([sketch_seed, width])
	_strokes = PencilSketch.sketch_line(rng, Vector2.ZERO, Vector2(width, 0), LINE_WIDTH)
	var x := rng.randf_range(4.0, HATCH_SPACING)
	while x < width - 2.0:
		var drop := rng.randf_range(8.0, 12.0)
		_strokes.append(PencilSketch.stroke(rng, Vector2(x, 3.0), Vector2(x - drop * 0.7, 3.0 + drop),
				1.3, 0.35, 0.4))
		x += HATCH_SPACING + rng.randf_range(-3.0, 3.0)
	if _ink:
		_ink.queue_redraw()


func _draw() -> void:
	if reveal < 1.0:
		# Wide enough to cover the stroke overshoot, wobble and hatching.
		draw_rect(Rect2(-12.0, -16.0, (width + 24.0) * reveal, 40.0), Color.WHITE)
