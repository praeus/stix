@tool
class_name NotebookPage
extends Node2D
## A full sheet of ruled notepad paper, drawn in code so its layout (rule
## spacing, margin, page size) is available to level building. The origin is
## the page's top-left corner. Proportions are US letter (8.5 x 11 in).

@export var size := Vector2(1152, 1488):
	set(value):
		size = value
		queue_redraw()
## Distance between ruled lines. Platforms snap to these.
@export var rule_spacing := 32.0:
	set(value):
		rule_spacing = value
		queue_redraw()
## Blank strip at the top of the page above the first rule.
@export var header_height := 96.0:
	set(value):
		header_height = value
		queue_redraw()
## X of the red margin line. The strip left of it is the margin.
@export var margin_x := 170.0:
	set(value):
		margin_x = value
		queue_redraw()
@export var paper_color := Color("fbfaf4")
@export var rule_color := Color("a9c8e6")
@export var margin_color := Color("e59a9a")

## Set while the sheet is being ripped off the pad: the top edge goes ragged
## and the sheet casts a shadow on the page underneath.
var torn := false:
	set(value):
		torn = value
		queue_redraw()


func rule_y(index: int) -> float:
	return header_height + index * rule_spacing


## Index of the lowest rule that leaves at least bottom_gap px of paper below.
func bottom_rule(bottom_gap := 40.0) -> int:
	return floori((size.y - bottom_gap - header_height) / rule_spacing)


func _draw() -> void:
	if torn:
		draw_rect(Rect2(Vector2(10, 16), size), Color(0, 0, 0, 0.22))
		draw_colored_polygon(_torn_outline(), paper_color)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), paper_color)
	for i in bottom_rule(0.0) + 1:
		var y := rule_y(i)
		# Antialiased so the lines stay whole when the sheet is turned and zoomed out.
		draw_line(Vector2(0, y), Vector2(size.x, y), rule_color, 1.5, true)
	draw_line(Vector2(margin_x, 14.0 if torn else 0.0), Vector2(margin_x, size.y), margin_color, 2.0, true)


## The sheet's outline with a ragged rip along the top, where it tore away
## from the pad's binding.
func _torn_outline() -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var points := PackedVector2Array([Vector2(size.x, size.y), Vector2(0, size.y)])
	var x := 0.0
	while x < size.x:
		points.append(Vector2(x, rng.randf_range(2.0, 14.0)))
		x += rng.randf_range(6.0, 20.0)
	points.append(Vector2(size.x, rng.randf_range(2.0, 14.0)))
	return points
