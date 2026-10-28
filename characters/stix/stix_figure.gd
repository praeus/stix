class_name StixFigure
extends CharacterBody2D
## A sketched stick figure on a Skeleton2D rig. The origin sits on the
## ground between the feet; the art faces +x.
## Long falls hurt, measured from the top of the fall in body heights, and a
## fall that empties the health bar breaks the figure apart.

signal health_changed(health: float, max_health: float)
signal died
## A sword swing connected with something that can take damage.
signal sword_hit(body: Node2D)

enum State { GROUNDED, TAKEOFF, AIRBORNE, LANDING, DEAD }

## Landing blocks walking for this long so the crouch reads before the
## figure moves off.
const LAND_LOCK_TIME := 0.12
## Extra crouch time after a fall that took the whole health bar's worth.
const HURT_LOCK_TIME := 0.5
## The part of sword_swing where the blade is coming down and can cut.
const SWING_CUT_START := 0.12
const SWING_CUT_END := 0.29
## The katana's tip relative to its grip, in art px (stix_parts.json: tip - pivot).
const SWORD_TIP := Vector2(122, -8)
const SWORD_DAMAGE := 40.0
## How hard a cut shoves the one it hits, in px/s; it wears off quickly.
const KNOCKBACK := 260.0
const KNOCKBACK_DRAG := 1400.0
## Figures sit on their own physics layer: they stand on the world (layer 1)
## but pass through each other, and swords and pickups look for this layer.
const BODY_LAYER := 2

## Ground speed in px/s that matches the walk cycle's stride, so the planted
## foot doesn't slide. Written by tools/stix_art/gen_stix_rig.py.
@export var walk_speed := 160.0
## Same as walk_speed, for the run cycle.
@export var run_speed := 326.0
## Peak height of a jump in px, measured at the feet.
@export var jump_height := 120.0
## Seconds from leaving the ground to the top of the jump.
@export var jump_time_to_apex := 0.4
@export var max_health := 100.0
## Falls up to this many body heights don't hurt.
@export var safe_fall_heights := 3.0
## Falls this many body heights or more are fatal; damage ramps up in between.
@export var lethal_fall_heights := 8.0

## Where blood goes when the figure is hurt. Optional.
var blood: BloodSpray

## -1 walks left, 1 walks right, 0 stands idle.
var move_direction := 0.0:
	set(value):
		move_direction = clampf(value, -1.0, 1.0)

## Run instead of walk while moving on the ground. Jumping while running
## leaps, and the leap keeps running speed through the air.
var running := false

var facing := 1:
	set(value):
		facing = 1 if value >= 0 else -1
		# Keep the rig's size; only flip which way it faces.
		_skeleton.scale.x = facing * absf(_skeleton.scale.y)
		_reach.position.x = facing * absf(_reach.position.x)

var state := State.GROUNDED
var health := 0.0
var has_sword := false

var _state_time := 0.0
## Horizontal speed carried through the current jump or fall.
var _air_speed := 0.0
var _leaping := false
## Highest point (smallest y) reached since leaving the ground.
var _fall_top := 0.0
var _land_lock := LAND_LOCK_TIME
var _knockback := 0.0
## Everything the current swing has already cut, so each is hit once.
var _cut: Array[Node2D] = []
var _cut_area: Area2D
var _reach: CollisionShape2D
var _trail: SwordTrail

@onready var _skeleton: Skeleton2D = $Skeleton2D
@onready var _anim: AnimationPlayer = $AnimationPlayer
@onready var _sword_anim: AnimationPlayer = $SwordPlayer
@onready var _sword: Sprite2D = _skeleton.find_child("Sword")
@onready var _arc := get_jump_arc()


func _ready() -> void:
	health = max_health
	collision_layer = BODY_LAYER
	collision_mask = 1
	# Where the blade sweeps in front of the body. Mirrored with facing.
	_cut_area = Area2D.new()
	_cut_area.name = "SwordReach"
	_cut_area.collision_layer = 0
	_cut_area.collision_mask = BODY_LAYER
	_cut_area.monitorable = false
	_reach = CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(get_height() * 0.75, get_height() * 0.9)
	_reach.shape = rect
	_reach.position = Vector2(rect.size.x * 0.5 + 4.0, -get_height() * 0.6)
	_cut_area.add_child(_reach)
	add_child(_cut_area)
	_trail = SwordTrail.new()
	add_child(_trail)


## Pass running = true for the arc of a running jump, which covers the same
## height but more ground.
func get_jump_arc(is_running := false) -> JumpArc:
	return JumpArc.new(jump_height, jump_time_to_apex, run_speed if is_running else walk_speed)


func is_dead() -> bool:
	return state == State.DEAD


func is_on_ground() -> bool:
	return state == State.GROUNDED or state == State.LANDING


## Crouch and spring up, or leap straight out of a run. Ignored unless on
## the ground.
func jump() -> void:
	if not is_on_ground():
		return
	_leaping = _is_running()
	_set_state(State.TAKEOFF)
	_anim.speed_scale = 1.0
	_anim.play(&"run_jump_start" if _leaping else &"jump_start", 0.08)


## Height of the body from the feet to the top of the head.
func get_height() -> float:
	return ($Collision.shape as RectangleShape2D).size.y


## Stops moving and holds the arms-up pose from the start of a jump, for
## hanging on to something (like a page being torn off).
func hang() -> void:
	set_physics_process(false)
	velocity = Vector2.ZERO
	_anim.speed_scale = 1.0
	_anim.play(&"jump_air")
	_anim.seek(0.1, true)
	_anim.pause()


## Takes the sword in the right hand and holds it up, ready.
func equip_sword() -> void:
	has_sword = true
	_sword.visible = true
	_sword_anim.play(&"sword_hold")


func is_swinging() -> bool:
	return _sword_anim.current_animation == &"sword_swing"


## An overhead cut in front. Works on the ground or in the air; the legs keep
## doing whatever they were doing.
func swing() -> void:
	if not has_sword or is_dead() or is_swinging():
		return
	_cut.clear()
	_sword_anim.play(&"sword_swing")
	_sword_anim.queue(&"sword_hold")


## Damage from a fall of the given height in px: nothing up to the safe
## height, the whole bar at the lethal height.
func fall_damage(fall: float) -> float:
	var t := inverse_lerp(safe_fall_heights, lethal_fall_heights, fall / get_height())
	return 0.0 if t <= 0.0 else max_health * minf(t, 1.0)


func take_damage(amount: float, impact := Vector2.ZERO) -> void:
	if is_dead() or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		die(impact)
		return
	if blood:
		blood.spray(global_position + Vector2(0, -get_height() * 0.3), Vector2(0, -160),
				int(4 + amount * 0.3), 140.0)
	_skeleton.modulate = Color(1.0, 0.35, 0.35)
	create_tween().tween_property(_skeleton, ^"modulate", Color.WHITE, 0.5)


## A shove sideways (px/s) on top of the figure's own movement.
func knock_back(speed: float) -> void:
	if not is_dead():
		_knockback = speed


## Breaks the figure into its body parts, which fly apart, bleeding.
func die(impact := Vector2.ZERO) -> void:
	if is_dead():
		return
	_set_state(State.DEAD)
	set_physics_process(false)
	velocity = Vector2.ZERO
	_anim.pause()
	_sword_anim.pause()
	$Collision.set_deferred(&"disabled", true)
	var center := global_position + Vector2(0, -get_height() * 0.45)
	var remains := Node2D.new()
	remains.name = "Remains"
	add_sibling(remains)
	# The sword, if held, goes flying with the rest.
	for sprite: Sprite2D in _skeleton.find_children("*", "Sprite2D"):
		if not sprite.visible:
			continue
		var part := BodyPart.from_sprite(sprite, blood)
		remains.add_child(part)
		var away := (part.global_position - center).normalized()
		part.linear_velocity = impact * 0.35 + away * randf_range(160.0, 380.0) \
				+ Vector2(randf_range(-60.0, 60.0), -randf_range(220.0, 420.0))
		part.angular_velocity = randf_range(-14.0, 14.0)
	_skeleton.visible = false
	if blood:
		blood.spray(center, Vector2(impact.x * 0.3, -260.0), 90, 380.0)
	died.emit()


func _physics_process(delta: float) -> void:
	_state_time += delta
	var can_move := state != State.LANDING or _leaping or _state_time >= _land_lock
	if state == State.AIRBORNE:
		velocity.x = move_direction * _air_speed
	else:
		velocity.x = move_direction * _ground_speed() if can_move else 0.0
	if can_move and not is_zero_approx(move_direction):
		facing = signi(int(signf(move_direction)))

	if state == State.TAKEOFF and _state_time >= _anim.current_animation_length:
		velocity.y = -_arc.launch_speed
		_enter_air()
	velocity.x += _knockback
	_knockback = move_toward(_knockback, 0.0, KNOCKBACK_DRAG * delta)
	velocity.y += _arc.gravity * delta
	# Landing zeroes the velocity, so keep what it hit the ground with.
	var impact := velocity
	move_and_slide()
	if is_swinging():
		_update_swing()

	match state:
		State.GROUNDED:
			if not is_on_floor():
				_leaping = false
				_enter_air()
			else:
				_update_ground_animation()
		State.AIRBORNE:
			if is_on_floor() and velocity.y >= 0.0:
				_land(impact)
			else:
				_fall_top = minf(_fall_top, global_position.y)
				_scrub_air_pose()
		State.LANDING:
			if not is_on_floor():
				_enter_air()
			elif _leaping and (_is_running() or not _anim.is_playing()):
				# Land in stride: no lock, straight back into the run.
				_leaping = false
				_set_state(State.GROUNDED)
				_update_ground_animation()
			elif not _leaping and _state_time >= _land_lock \
					and (not is_zero_approx(move_direction) or not _anim.is_playing()):
				_set_state(State.GROUNDED)
				_update_ground_animation()


func _update_swing() -> void:
	var t := _sword_anim.current_animation_position
	var cutting := t >= SWING_CUT_START and t <= SWING_CUT_END
	var grip := _sword.global_transform
	_trail.add_point(grip * SWORD_TIP, grip * (SWORD_TIP * 0.55), cutting)
	if not cutting:
		return
	for body in _cut_area.get_overlapping_bodies():
		if body == self or body in _cut or not body.has_method(&"take_damage"):
			continue
		_cut.append(body)
		body.take_damage(SWORD_DAMAGE, Vector2(facing * 300.0, -150.0))
		if body is StixFigure:
			body.knock_back(facing * KNOCKBACK)
		sword_hit.emit(body)


func _land(impact: Vector2) -> void:
	var damage := fall_damage(global_position.y - _fall_top)
	_land_lock = LAND_LOCK_TIME + HURT_LOCK_TIME * damage / max_health
	take_damage(damage, impact)
	if is_dead():
		return
	if damage > 0.0:
		# A hard landing knocks the stride out: crouch instead of running on.
		_leaping = false
	_set_state(State.LANDING)
	_anim.play(&"run_jump_land" if _leaping else &"jump_land")


func _is_running() -> bool:
	return running and not is_zero_approx(move_direction)


func _ground_speed() -> float:
	return run_speed if running else walk_speed


func _update_ground_animation() -> void:
	if is_zero_approx(move_direction):
		_play(&"idle")
		return
	_play(&"run" if running else &"walk")
	# Scale playback with input strength so partial input still keeps feet planted.
	_anim.speed_scale = absf(move_direction)


## Also used when walking off a ledge, so falling reuses the jump poses.
func _enter_air() -> void:
	_set_state(State.AIRBORNE)
	_fall_top = global_position.y
	_air_speed = run_speed if _leaping or running else walk_speed
	# The air animations are scrubbed by vertical velocity rather than played in time.
	_anim.speed_scale = 1.0
	_anim.play(&"run_jump_air" if _leaping else &"jump_air")
	_anim.pause()
	_scrub_air_pose()


func _scrub_air_pose() -> void:
	var t := inverse_lerp(-_arc.launch_speed, _arc.launch_speed, velocity.y)
	_anim.seek(clampf(t, 0.0, 1.0), true)


func _set_state(new_state: State) -> void:
	state = new_state
	_state_time = 0.0


func _play(anim_name: StringName) -> void:
	if _anim.current_animation != anim_name:
		_anim.play(anim_name, 0.15)
		if anim_name != &"walk" and anim_name != &"run":
			_anim.speed_scale = 1.0
