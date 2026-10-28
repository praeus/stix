class_name ScoreDisplay
extends CanvasLayer
## The score, pencilled at the top middle of the screen. Points earned pop
## the number and float a "+N" up beside it.

var score := 0:
	set(value):
		score = value
		if _label:
			_label.text = "score %d" % score

var _label: Label


func _ready() -> void:
	layer = 5
	_label = _make_label("score %d" % score, 26, PencilSketch.INK)
	_label.anchor_left = 0.5
	_label.anchor_right = 0.5
	_label.offset_left = -150.0
	_label.offset_right = 150.0
	_label.offset_top = 18.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.pivot_offset = Vector2(150.0, 18.0)
	add_child(_label)


func add(points: int) -> void:
	score += points
	var pop := create_tween()
	pop.tween_property(_label, ^"scale", Vector2.ONE * 1.25, 0.08)
	pop.tween_property(_label, ^"scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK)

	var plus := _make_label("+%d" % points, 22, HealthBar.RED)
	var width := _label.get_theme_font(&"font").get_string_size(_label.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
	plus.anchor_left = 0.5
	plus.anchor_right = 0.5
	plus.offset_left = width * 0.5 + 10.0
	plus.offset_top = 20.0
	add_child(plus)
	var drift := create_tween().set_parallel(true)
	drift.tween_property(plus, ^"offset_top", -4.0, 1.0).set_ease(Tween.EASE_OUT)
	drift.tween_property(plus, ^"modulate:a", 0.0, 1.0).set_delay(0.4)
	drift.chain().tween_callback(plus.queue_free)


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", size)
	label.add_theme_color_override(&"font_color", color)
	return label
