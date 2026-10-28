class_name SwordPickup
extends Area2D
## A katana stuck point-first into a ledge, with a pencil glint to catch the
## eye. The origin sits on the ledge's surface. Touching it takes the sword.

const TEXTURE := preload("res://art/stix/katana.svg")
## Matches the figure's rig scale, so it's the same size in the hand.
const ART_SCALE := 0.5
## The katana's grip in the texture (stix_parts.json pivot), and grip-to-tip.
const GRIP := Vector2(27, 35)
const TIP := StixFigure.SWORD_TIP
## How far the tip is sunk into the ledge, and the lean off vertical.
const SINK := 6.0
const LEAN := 0.22
## How far above the ledge a figure's feet can be and still grab it, so one
## jumping past can snatch it. Feet below the ledge never can.
const FEET_ABOVE := 40.0

## Picked up (it fades out for a moment before it's freed).
var taken := false

var _time := 0.0
var _hilt := Vector2.ZERO


func _ready() -> void:
	collision_layer = 0
	collision_mask = StixFigure.BODY_LAYER
	monitorable = false
	var sprite := Sprite2D.new()
	sprite.texture = TEXTURE
	sprite.centered = false
	# Grip at the sprite's origin, like in the hand.
	sprite.offset = -GRIP
	sprite.scale = Vector2.ONE * ART_SCALE
	sprite.rotation = PI * 0.5 + LEAN
	# Place the grip so the tip ends up just under the surface.
	sprite.position = Vector2(0, SINK) - (TIP * ART_SCALE).rotated(sprite.rotation)
	add_child(sprite)
	_hilt = sprite.position

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 70)
	shape.shape = rect
	shape.position = Vector2(_hilt.x * 0.5, -35)
	add_child(shape)


## Checked every frame rather than on entering, since a figure can be in the
## area from the ledge below (reaching up through it) before it climbs on.
func _physics_process(_delta: float) -> void:
	if taken:
		return
	for body in get_overlapping_bodies():
		var figure := body as StixFigure
		# Feet on this ledge, not reaching up through it from underneath.
		if figure == null or figure.is_dead() or figure.has_sword:
			continue
		var feet := figure.global_position.y - global_position.y
		if feet > 2.0 or feet < -FEET_ABOVE:
			continue
		figure.equip_sword()
		taken = true
		set_deferred(&"monitoring", false)
		var tween := create_tween()
		tween.tween_property(self, ^"modulate:a", 0.0, 0.12)
		tween.tween_callback(queue_free)
		return


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


## A four-point pencil sparkle that twinkles by the guard every so often.
func _draw() -> void:
	var t := fmod(_time, 2.2)
	if t > 0.5:
		return
	var s := sin(PI * t / 0.5)
	var center := _hilt + Vector2(10, 4)
	var ink := Color(PencilSketch.INK, 0.8 * s)
	for a: float in [0.0, PI * 0.5]:
		var d := Vector2.from_angle(a + 0.3) * 7.0 * s
		draw_line(center - d, center + d, ink, 1.6, true)
	for a: float in [PI * 0.25, PI * 0.75]:
		var d := Vector2.from_angle(a + 0.3) * 3.5 * s
		draw_line(center - d, center + d, ink, 1.0, true)
