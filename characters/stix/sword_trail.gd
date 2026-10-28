class_name SwordTrail
extends Node2D
## Pencil speed lines following the sword tip through a swing, with a faint
## smudge over the area the blade swept. Drawn in world space so the lines
## stay where the blade passed while the figure moves on.

const FADE_TIME := 0.16

## Each point: {tip, mid, age, cut}. cut marks the part of the swing that hits.
var _points: Array[Dictionary] = []


func _ready() -> void:
	top_level = true
	global_transform = Transform2D.IDENTITY


func add_point(tip: Vector2, mid: Vector2, cut: bool) -> void:
	_points.append({"tip": tip, "mid": mid, "age": 0.0, "cut": cut})


func _process(delta: float) -> void:
	if _points.is_empty():
		return
	for p in _points:
		p.age += delta
	while not _points.is_empty() and _points[0].age > FADE_TIME:
		_points.pop_front()
	queue_redraw()


func _draw() -> void:
	for i in range(1, _points.size()):
		var a := _points[i - 1]
		var b := _points[i]
		if not (a.cut and b.cut):
			continue
		var fade: float = 1.0 - b.age / FADE_TIME
		# draw_primitive, not draw_colored_polygon: the quad can fold over
		# itself, which polygon triangulation rejects.
		var smudge := Color(PencilSketch.INK, 0.08 * fade)
		draw_primitive(PackedVector2Array([a.tip, b.tip, b.mid, a.mid]),
				PackedColorArray([smudge, smudge, smudge, smudge]), PackedVector2Array())
		draw_line(a.tip, b.tip, Color(PencilSketch.INK, 0.75 * fade), 2.4, true)
		draw_line(a.tip.lerp(a.mid, 0.3), b.tip.lerp(b.mid, 0.3), Color(PencilSketch.INK, 0.35 * fade), 1.4, true)
		draw_line(a.tip.lerp(a.mid, 0.6), b.tip.lerp(b.mid, 0.6), Color(PencilSketch.INK, 0.2 * fade), 1.0, true)
