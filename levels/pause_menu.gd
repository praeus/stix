class_name PauseMenu
extends CanvasLayer
## Escape pauses the game and opens a pencil-drawn card of options on the
## right of the screen. The level shows the whole page beside it.

signal paused_changed(is_paused: bool)
signal retry_requested
signal new_page_requested

const INK := PencilSketch.INK
const CARD_SIZE := Vector2(300, 380)

var page_title := "":
	set(value):
		page_title = value
		if _subtitle:
			_subtitle.text = value

## Off while the level plays a cutscene, so Escape can't interrupt it.
var enabled := true

var _card: SketchCard
var _subtitle: Label
var _first_button: Button


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false


func is_open() -> bool:
	return visible


func open() -> void:
	visible = true
	get_tree().paused = true
	_first_button.grab_focus()
	paused_changed.emit(true)


func close() -> void:
	visible = false
	get_tree().paused = false
	paused_changed.emit(false)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(&"pause") and enabled:
		if is_open():
			close()
		else:
			open()


func _build() -> void:
	_card = SketchCard.new()
	_card.anchor_left = 0.62
	_card.anchor_right = 0.62
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_top = -CARD_SIZE.y * 0.5
	_card.offset_bottom = CARD_SIZE.y * 0.5
	_card.offset_right = CARD_SIZE.x
	add_child(_card)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 36
	box.offset_top = 28
	box.offset_right = -24
	box.offset_bottom = -24
	box.add_theme_constant_override(&"separation", 6)
	_card.add_child(box)

	var title := _label("Paused", 40, 1.0)
	box.add_child(title)
	_subtitle = _label(page_title, 18, 0.6)
	box.add_child(_subtitle)
	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	box.add_child(gap)

	_first_button = _option(box, "Resume", close)
	_option(box, "Retry this page", func() -> void: retry_requested.emit())
	_option(box, "New page", func() -> void: new_page_requested.emit())
	_option(box, "Quit", func() -> void: get_tree().quit())


func _label(text: String, font_size: int, alpha: float) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", Color(INK, alpha))
	return label


func _option(parent: Control, text: String, action: Callable) -> Button:
	var button := SketchButton.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## A sheet of paper with a pencilled border and a shadow.
class SketchCard extends Control:
	var _strokes: Array[Dictionary] = []

	func _ready() -> void:
		resized.connect(_sketch)
		_sketch()

	func _sketch() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		var r := Rect2(Vector2.ZERO, size).grow(-4)
		var corners := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
		_strokes.clear()
		for i in 4:
			_strokes.append_array(PencilSketch.sketch_line(rng, corners[i], corners[(i + 1) % 4], 2.6))
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2(8, 10), size), Color(0, 0, 0, 0.25))
		draw_rect(Rect2(Vector2.ZERO, size), Color("fbfaf4"))
		PencilSketch.draw_strokes(self, _strokes)


## A plain text option that gets a pencil underline while focused. Hovering
## focuses it, so mouse and keyboard share one highlight.
class SketchButton extends Button:
	var _underline: Array[Dictionary] = []

	func _ready() -> void:
		flat = true
		alignment = HORIZONTAL_ALIGNMENT_LEFT
		focus_mode = Control.FOCUS_ALL
		add_theme_font_size_override(&"font_size", 26)
		for state in [&"font_color", &"font_hover_color", &"font_focus_color",
				&"font_pressed_color", &"font_hover_pressed_color"]:
			add_theme_color_override(state, PencilSketch.INK)
		add_theme_stylebox_override(&"focus", StyleBoxEmpty.new())
		mouse_entered.connect(grab_focus)
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _draw() -> void:
		if not has_focus():
			return
		if _underline.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(text)
			var font := get_theme_font(&"font")
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
					get_theme_font_size(&"font_size")).x
			var y := size.y - 6.0
			_underline = PencilSketch.sketch_line(rng, Vector2(2, y), Vector2(w + 10, y + 1.5), 2.4)
		PencilSketch.draw_strokes(self, _underline)
