class_name BloodSpray
extends Node2D
## Drops of red ink thrown about by injuries. Each drop flies under gravity
## and, where it lands on a ledge, leaves a stain drawn onto stain_layer
## (a node on the page, so stains stay put and go with the paper).

const COLOR := Color("a3141c")
const GRAVITY := 1300.0
const MAX_DROPS := 400
const MAX_STAINS := 600
## Drops that hit nothing (off the sides or under a ledge) dry up after this long.
const LIFETIME := 3.0
## Stains are drawn in batches of this many, each its own node, so a new one
## only redraws its batch rather than every stain on the page.
const STAINS_PER_BATCH := 32

## Holds the stains. Defaults to this node.
var stain_layer: Node2D

var _drops: Array[Dictionary] = []
## Batches of stains, oldest first; the last one is being filled.
var _batches: Array[StainBatch] = []
var _stain_count := 0


func _ready() -> void:
	if stain_layer == null:
		stain_layer = self


## Throws count drops from origin, at velocity plus a random spread of up to
## spread px/s in any direction.
func spray(origin: Vector2, velocity: Vector2, count: int, spread: float) -> void:
	for i in count:
		if _drops.size() >= MAX_DROPS:
			_drops.pop_front()
		var kick := Vector2.from_angle(randf() * TAU) * spread * sqrt(randf())
		_drops.append({
			"pos": origin, "vel": velocity + kick, "life": LIFETIME,
			"size": randf_range(1.6, 4.2),
		})


func _physics_process(delta: float) -> void:
	if _drops.is_empty():
		return
	var space := get_world_2d().direct_space_state
	for i in range(_drops.size() - 1, -1, -1):
		var drop := _drops[i]
		drop.vel.y += GRAVITY * delta
		var from: Vector2 = drop.pos
		var to: Vector2 = from + drop.vel * delta
		drop.life -= delta
		var query := PhysicsRayQueryParameters2D.create(from, to, 1)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			drop.pos = to
			if drop.life <= 0.0:
				_drops.remove_at(i)
			continue
		# Only the tops of ledges catch blood; drops hitting a wall or the
		# underside of a ledge just vanish.
		if hit.normal.y < -0.5:
			_add_stain(hit.position, drop)
		_drops.remove_at(i)
	queue_redraw()


func _add_stain(pos: Vector2, drop: Dictionary) -> void:
	if _stain_count >= MAX_STAINS:
		_stain_count -= _batches[0].colors.size()
		_batches.pop_front().queue_free()
	if _batches.is_empty() or _batches[-1].colors.size() >= STAINS_PER_BATCH:
		var batch := StainBatch.new()
		stain_layer.add_child(batch)
		_batches.append(batch)
	var speed: float = drop.vel.length()
	# Faster drops land as wider, flatter splats, smeared the way they flew.
	var rx: float = drop.size * (1.0 + minf(speed / 500.0, 1.5))
	var ry: float = drop.size * 0.55
	var skew := clampf(drop.vel.x / 600.0, -1.0, 1.0)
	var center := stain_layer.to_local(pos)
	var points := PackedVector2Array()
	for k in 12:
		var a := TAU * k / 12.0
		var p := Vector2(cos(a) * rx, sin(a) * ry)
		# Lean the splat toward the side the drop was travelling.
		p.x += skew * rx * 0.5 * (1.0 + cos(a))
		points.append(center + p)
	_batches[-1].add(points, Color(COLOR, randf_range(0.7, 0.95)))
	_stain_count += 1


func _draw() -> void:
	for drop in _drops:
		var tail: Vector2 = drop.vel * 0.012
		draw_line(drop.pos - tail, drop.pos, COLOR, drop.size, true)
		draw_circle(drop.pos, drop.size * 0.5, COLOR, true, -1.0, true)


class StainBatch extends Node2D:
	var outlines: Array[PackedVector2Array] = []
	var colors: PackedColorArray = []

	func add(outline: PackedVector2Array, color: Color) -> void:
		outlines.append(outline)
		colors.append(color)
		queue_redraw()

	func _draw() -> void:
		for i in outlines.size():
			draw_colored_polygon(outlines[i], colors[i])
