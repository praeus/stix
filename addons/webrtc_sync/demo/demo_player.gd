extends Node2D
## A square that the owning peer moves with the arrow keys. Position is
## replicated by the RtcSync child; color comes from a shared variable.

const SPEED := 300.0

var peer_id := 0
var color := Color.WHITE:
	set(value):
		color = value
		queue_redraw()

var _sync: RtcSync


func setup(id: int) -> void:
	peer_id = id
	name = "Player%d" % id
	_sync = RtcSync.new()
	_sync.net_id = "player_%d" % id
	_sync.owner_peer = id
	_sync.properties = PackedStringArray(["position", "rotation"])
	add_child(_sync)


func _process(delta: float) -> void:
	if not _sync.is_authority():
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	position += dir * SPEED * delta
	if dir != Vector2.ZERO:
		rotation = lerp_angle(rotation, dir.angle(), 10.0 * delta)


func _draw() -> void:
	draw_rect(Rect2(-20, -20, 40, 40), color)
	draw_line(Vector2.ZERO, Vector2(24, 0), Color.BLACK, 3.0)
	draw_string(ThemeDB.fallback_font, Vector2(-20, -28), str(peer_id))
