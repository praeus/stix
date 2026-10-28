class_name PencilSketch
extends RefCounted
## Runtime version of the stroke drawing in tools/stix_art/gen_stix_svgs.py,
## for things whose size is only known in game (platforms), so they match the
## pre-made SVG body parts. A stroke is a closed outline polygon plus an alpha.

const INK := Color("2b2b2f")


## Main stroke plus two lighter, offset retraces, like the body-part art.
static func sketch_line(rng: RandomNumberGenerator, p0: Vector2, p1: Vector2,
		width: float) -> Array[Dictionary]:
	var length := p0.distance_to(p1)
	var dir := (p1 - p0) / length
	var normal := Vector2(-dir.y, dir.x)
	# Long lines get a gentler bow so they don't sag like a hammock.
	var bow_scale := minf(length * 0.015, 2.5)
	var strokes: Array[Dictionary] = [stroke(rng, p0, p1, width, 0.8, 0.7,
			Vector2(rng.randf_range(0, 1.5), rng.randf_range(0.5, 2.5)),
			rng.randf_range(-1, 1) * bow_scale)]
	for pass_style: Vector2 in [Vector2(0.45, 0.5), Vector2(0.3, 0.38)]:
		var offset := normal * (1.0 if rng.randf() < 0.5 else -1.0) * rng.randf_range(0.7, 1.7)
		var start := dir * rng.randf_range(-0.04, 0.2) * minf(length, 80.0)
		var end := dir * rng.randf_range(-0.06, 0.18) * minf(length, 80.0)
		strokes.append(stroke(rng, p0 + start + offset, p1 - end + offset,
				width * pass_style.y, pass_style.x, 1.0, Vector2.ZERO,
				rng.randf_range(-1, 1) * bow_scale * 1.3))
	return strokes


## One tapered, wobbly stroke from p0 to p1, extended by overshoot (start, end).
static func stroke(rng: RandomNumberGenerator, p0: Vector2, p1: Vector2, width: float,
		alpha: float, jitter: float, overshoot := Vector2.ZERO, bow := 0.0) -> Dictionary:
	var dir := (p1 - p0).normalized()
	var normal := Vector2(-dir.y, dir.x)
	var start := p0 - dir * overshoot.x
	var total := p0.distance_to(p1) + overshoot.x + overshoot.y
	# Keep the wobble's wavelength roughly constant however long the line is.
	var freq_scale := maxf(1.0, total / 80.0)
	var wobble := _noise_terms(rng, [Vector2(1.0, 1.0), Vector2(2.3, 0.5), Vector2(5.3, 0.25)], freq_scale)
	var pressure := _noise_terms(rng, [Vector2(1.7, 1.0), Vector2(4.1, 0.6)], freq_scale)
	var head := rng.randf_range(0.08, 0.18) / freq_scale
	var tail := rng.randf_range(0.12, 0.25) / freq_scale
	var steps := maxi(10, int(total / 1.5))
	var points := PackedVector2Array()
	var widths := PackedFloat32Array()
	for i in steps + 1:
		var t := float(i) / steps
		var off := _noise(wobble, t) * jitter + bow * sin(PI * t)
		points.append(start + dir * total * t + normal * off)
		widths.append(width * _taper(t, head, tail) * (1.0 + 0.25 * _noise(pressure, t)))
	return {"outline": _ribbon(points, widths), "alpha": alpha}


static func draw_strokes(canvas: CanvasItem, strokes: Array[Dictionary], color := INK) -> void:
	for s in strokes:
		canvas.draw_colored_polygon(s.outline, Color(color, s.alpha))


## Each octave is Vector2(frequency, amplitude); returns [freq, amp, phase] terms.
static func _noise_terms(rng: RandomNumberGenerator, octaves: Array, freq_scale: float) -> Array:
	var terms := []
	for o: Vector2 in octaves:
		terms.append([o.x * freq_scale, o.y, rng.randf_range(0.0, TAU)])
	return terms


static func _noise(terms: Array, t: float) -> float:
	var total := 0.0
	var amp_sum := 0.0
	for term in terms:
		total += term[1] * sin(TAU * term[0] * t + term[2])
		amp_sum += term[1]
	return total / amp_sum


## Pencil pressure: thin at the ends, full in the middle.
static func _taper(t: float, head: float, tail: float, floor_width := 0.3) -> float:
	if t < head:
		return floor_width + (1.0 - floor_width) * sin(0.5 * PI * t / head)
	if t > 1.0 - tail:
		return floor_width + (1.0 - floor_width) * sin(0.5 * PI * (1.0 - t) / tail)
	return 1.0


static func _ribbon(points: PackedVector2Array, widths: PackedFloat32Array) -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var n := points.size()
	for i in n:
		var a := points[maxi(i - 1, 0)]
		var b := points[mini(i + 1, n - 1)]
		var d := (b - a).normalized()
		var nrm := Vector2(-d.y, d.x) * widths[i] * 0.5
		left.append(points[i] + nrm)
		right.append(points[i] - nrm)
	right.reverse()
	return left + right
