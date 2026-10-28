class_name BodyPart
extends RigidBody2D
## One limb, the head or the torso of a StixFigure that has broken apart. It
## tumbles onto the ledges and bleeds for a moment as it goes.

## Transparent padding around the strokes in the body-part SVGs, trimmed off
## the collider so parts rest on their lines rather than their margins.
const ART_PAD := 8.0
const BLEED_TIME := 1.6

var _blood: BloodSpray
var _bleed_left := BLEED_TIME
var _drip := 0.0


## A part with the same look and place as one of the rig's sprites. The rig is
## scaled and flipped, which a physics body can't be, so that goes on the
## part's own sprite instead.
static func from_sprite(rig_sprite: Sprite2D, blood: BloodSpray) -> BodyPart:
	var part := BodyPart.new()
	part.add_to_group(&"body_parts")
	part._blood = blood
	var xform := rig_sprite.global_transform
	var tex_size := rig_sprite.texture.get_size()
	var center := xform * (rig_sprite.offset + tex_size * 0.5)
	part.position = center

	var sprite := Sprite2D.new()
	sprite.texture = rig_sprite.texture
	sprite.centered = false
	sprite.offset = rig_sprite.offset
	sprite.transform = Transform2D(xform.x, xform.y, xform.origin - center)
	part.add_child(sprite)

	var rect := RectangleShape2D.new()
	var axis_scale := Vector2(xform.x.length(), xform.y.length())
	rect.size = ((tex_size - Vector2.ONE * ART_PAD * 2.0) * axis_scale).max(Vector2(3, 3))
	var shape := CollisionShape2D.new()
	shape.shape = rect
	shape.rotation = xform.y.angle() - PI * 0.5
	part.add_child(shape)

	# Nothing collides with the parts, and they don't collide with each other.
	part.collision_layer = 0
	part.collision_mask = 1
	part.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	var bounce := PhysicsMaterial.new()
	bounce.bounce = 0.25
	bounce.friction = 0.9
	part.physics_material_override = bounce
	return part


func _physics_process(delta: float) -> void:
	if _blood == null or _bleed_left <= 0.0:
		return
	_bleed_left -= delta
	# Drips come thick at first and slow as the part runs dry.
	_drip += delta * 24.0 * _bleed_left / BLEED_TIME
	while _drip >= 1.0:
		_drip -= 1.0
		_blood.spray(global_position, linear_velocity * 0.3 + Vector2(0, -30), 1, 70.0)
