"""Generate sketchy pencil-style SVG body parts for Stix figures.

Each part is drawn as a few overlapping, tapered, slightly wobbly graphite
strokes so it reads like a quick pencil sketch on a notepad. Output is
deterministic per seed, so re-running produces the same art unless --seed
changes.

Every part is written with its joint pivot at a known pixel; the pivot and
the far joint are recorded in stix_parts.json for building the skeleton.

Usage:
    python tools/stix_art/gen_stix_svgs.py [--seed N]
"""

import argparse
import json
import math
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "art" / "stix"

INK = "#2b2b2f"
PAD = 8


def smooth_noise(rng, octaves=((1.0, 1.0), (2.3, 0.5), (5.3, 0.25))):
    """Return a smooth 1D noise function on t in [0, 1], roughly in [-1, 1]."""
    terms = [(f, a, rng.uniform(0, math.tau)) for f, a in octaves]
    total = sum(a for _, a, _ in terms)

    def n(t):
        return sum(a * math.sin(math.tau * f * t + p) for f, a, p in terms) / total

    return n


def taper(t, head, tail, floor=0.3):
    """Pencil pressure: thin at the ends, full in the middle."""
    w = 1.0
    if t < head:
        w = floor + (1 - floor) * math.sin(0.5 * math.pi * t / head)
    elif t > 1 - tail:
        w = floor + (1 - floor) * math.sin(0.5 * math.pi * (1 - t) / tail)
    return w


def ribbon(points, widths, opacity):
    """Turn a centerline with per-point widths into a filled SVG path."""
    left, right = [], []
    n = len(points)
    for i, (x, y) in enumerate(points):
        a = points[max(i - 1, 0)]
        b = points[min(i + 1, n - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        d = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / d, dx / d
        h = widths[i] / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    outline = left + right[::-1]
    d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in outline) + " Z"
    return f'<path d="{d}" fill="{INK}" fill-opacity="{opacity:.2f}"/>'


def grain(rng, points, width, opacity):
    """Broken hairline along the stroke: the paper tooth showing through
    graphite. A random dash pattern keeps it from looking mechanical."""
    dashes = " ".join(f"{rng.uniform(0.6, 3.5):.1f}" for _ in range(12))
    d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in points)
    return (f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="{width:.2f}" '
            f'stroke-opacity="{opacity:.2f}" stroke-linecap="round" stroke-dasharray="{dashes}"/>')


def stroke_line(rng, p0, p1, width, opacity, jitter, overshoot=(0.0, 0.0), bow=0.0):
    """One tapered, wobbly stroke from p0 to p1 (with optional overshoot)."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    length = math.hypot(dx, dy)
    ux, uy = dx / length, dy / length
    nx, ny = -uy, ux
    start = (p0[0] - ux * overshoot[0], p0[1] - uy * overshoot[0])
    total = length + overshoot[0] + overshoot[1]
    wobble = smooth_noise(rng)
    pressure = smooth_noise(rng, ((1.7, 1.0), (4.1, 0.6)))
    head, tail = rng.uniform(0.08, 0.18), rng.uniform(0.12, 0.25)
    steps = max(10, int(total / 1.5))
    pts, ws = [], []
    for i in range(steps + 1):
        t = i / steps
        off = wobble(t) * jitter + bow * math.sin(math.pi * t)
        pts.append((start[0] + ux * total * t + nx * off,
                    start[1] + uy * total * t + ny * off))
        ws.append(width * taper(t, head, tail) * (1 + 0.25 * pressure(t)))
    return pts, ribbon(pts, ws, opacity)


def stroke_ellipse(rng, cx, cy, rx, ry, width, opacity, jitter, sweep, tilt=0.0):
    """A hand-drawn loop: starts at a random angle, drifts in radius so the
    ends don't meet cleanly, and overlaps itself a little."""
    a0 = rng.uniform(0, math.tau)
    drift0, drift1 = rng.uniform(0.92, 0.97), rng.uniform(1.03, 1.08)
    wobble = smooth_noise(rng)
    pressure = smooth_noise(rng, ((1.7, 1.0), (4.1, 0.6)))
    circumference = math.pi * (rx + ry) * sweep / math.tau
    steps = max(24, int(circumference / 1.2))
    ct, st = math.cos(tilt), math.sin(tilt)
    pts, ws = [], []
    for i in range(steps + 1):
        t = i / steps
        a = a0 + sweep * t
        k = drift0 + (drift1 - drift0) * t + wobble(t) * jitter / max(rx, ry)
        ex, ey = math.cos(a) * rx * k, math.sin(a) * ry * k
        pts.append((cx + ex * ct - ey * st, cy + ex * st + ey * ct))
        ws.append(width * taper(t, 0.06, 0.1) * (1 + 0.25 * pressure(t)))
    return pts, ribbon(pts, ws, opacity)


def sketch_line(rng, p0, p1, width):
    """A main stroke, two lighter retrace strokes and a grain hairline."""
    length = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
    pts, main = stroke_line(rng, p0, p1, width, 0.8, jitter=0.7,
                            overshoot=(rng.uniform(0, 1.5), rng.uniform(0.5, 2.5)),
                            bow=rng.uniform(-1, 1) * length * 0.015)
    out = [main]
    # Retraces: offset to one side or the other, rarely covering the full length.
    dx, dy = (p1[0] - p0[0]) / length, (p1[1] - p0[1]) / length
    nx, ny = -dy, dx
    for opacity, wscale in ((0.45, 0.5), (0.3, 0.38)):
        o = rng.choice((-1, 1)) * rng.uniform(0.7, 1.7)
        s = rng.uniform(-0.04, 0.2) * length
        e = rng.uniform(-0.06, 0.18) * length
        q0 = (p0[0] + dx * s + nx * o, p0[1] + dy * s + ny * o)
        q1 = (p1[0] - dx * e + nx * o, p1[1] - dy * e + ny * o)
        out.append(stroke_line(rng, q0, q1, width * wscale, opacity, jitter=1.0,
                               bow=rng.uniform(-1, 1) * length * 0.025)[1])
    out.append(grain(rng, pts, width * 0.3, 0.5))
    return out


def sketch_ellipse(rng, cx, cy, rx, ry, width):
    tilt = rng.uniform(-0.15, 0.15)
    pts, main = stroke_ellipse(rng, cx, cy, rx, ry, width, 0.8, jitter=0.6,
                               sweep=math.tau * rng.uniform(1.08, 1.18), tilt=tilt)
    _, retrace = stroke_ellipse(rng, cx + rng.uniform(-1, 1), cy + rng.uniform(-1, 1),
                                rx, ry, width * 0.5, 0.42, jitter=1.0,
                                sweep=math.tau * rng.uniform(0.45, 0.8), tilt=tilt)
    return [main, retrace, grain(rng, pts, width * 0.3, 0.5)]


def write_svg(path, w, h, elements):
    body = "\n".join(f"  {e}" for e in elements)
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
        f"{body}\n</svg>\n",
        encoding="utf-8",
    )


def limb(rng, name, length, width):
    """Vertical limb hanging down from its pivot at the top."""
    w = int(2 * PAD + 2 * width + 6)
    h = int(2 * PAD + length)
    cx = w / 2
    p0, p1 = (cx, PAD), (cx, PAD + length)
    write_svg(OUT / f"{name}.svg", w, h, sketch_line(rng, p0, p1, width))
    return {"size": [w, h], "pivot": list(p0), "end": list(p1), "length": length}


def torso(rng, length, width):
    """Torso rises from the hip pivot (bottom) to the neck (top)."""
    w = int(2 * PAD + 2 * width + 6)
    h = int(2 * PAD + length)
    cx = w / 2
    hip, neck = (cx, PAD + length), (cx, PAD)
    write_svg(OUT / "torso.svg", w, h, sketch_line(rng, hip, neck, width))
    return {"size": [w, h], "pivot": list(hip), "end": list(neck), "length": length}


def head(rng, radius, width, neck_gap=2):
    """Head loop sitting on a neck pivot at the bottom."""
    size = int(2 * (PAD + radius + width))
    c = size / 2
    write_svg(OUT / "head.svg", size, size, sketch_ellipse(rng, c, c, radius, radius * 1.04, width))
    pivot = (c, c + radius + neck_gap)
    return {"size": [size, size], "pivot": list(pivot), "center": [c, c], "radius": radius}


def hand(rng, rx, ry, width):
    """Oval hand hanging from the wrist pivot at the top."""
    w = int(2 * (PAD + rx + width))
    h = int(2 * (PAD + ry + width))
    c = (w / 2, h / 2)
    write_svg(OUT / "hand.svg", w, h, sketch_ellipse(rng, c[0], c[1], rx, ry, width))
    return {"size": [w, h], "pivot": [c[0], c[1] - ry], "center": list(c)}


def foot(rng, length, width, heel=5):
    """Flat foot line pointing +x, pivot at the ankle a little ahead of the heel."""
    w = int(2 * PAD + length)
    h = int(2 * PAD + 2 * width + 4)
    y = h / 2
    p0, p1 = (PAD, y), (PAD + length, y)
    write_svg(OUT / "foot.svg", w, h, sketch_line(rng, p0, p1, width))
    return {"size": [w, h], "pivot": [PAD + heel, y], "toe": list(p1)}


def katana(rng, handle=34, blade=100, width=3.0):
    """Samurai sword lying along +x: wrapped handle, oval guard, then a blade
    with a gentle upward curve and an angled tip. The pivot is the middle of
    the handle, where the fist goes."""
    sori = 7.0  # how far the blade's curve rises by the tip
    w = int(2 * PAD + handle + 6 + blade + 6)
    h = int(2 * PAD + 2 * sori + 26)
    y = h - PAD - 13  # handle centreline; the blade curves up from here
    x0 = PAD + 2
    guard_x = x0 + handle
    el = []
    # Handle: two sides, the pommel cap, and the criss-cross wrap.
    for side in (-3.5, 3.5):
        el += sketch_line(rng, (x0, y + side), (guard_x, y + side), width * 0.8)[:2]
    el += sketch_line(rng, (x0, y - 4.5), (x0, y + 4.5), width)[:2]
    step = handle / 5
    for i in range(5):
        a = x0 + 1.5 + i * step
        el.append(stroke_line(rng, (a, y - 3.5), (a + step, y + 3.5), width * 0.55, 0.65, 0.3)[1])
        el.append(stroke_line(rng, (a, y + 3.5), (a + step, y - 3.5), width * 0.55, 0.65, 0.3)[1])
    # Guard (tsuba) and the collar in front of it.
    el += sketch_ellipse(rng, guard_x + 1.5, y, 3.0, 9.5, width * 0.85)[:2]
    el += sketch_line(rng, (guard_x + 5, y - 3.5), (guard_x + 5, y + 3.0), width * 0.6)[:1]
    # Blade: the back (top) and the cutting edge (bottom) rise toward the tip,
    # closing in on each other. A positive bow sags the middle, so the back
    # is the inside of the curve and the edge the outside, as on a katana.
    b0 = guard_x + 5
    tip = (b0 + blade, y - sori - 1.0)
    back_end = (b0 + blade - 12, y - sori - 3.5)
    edge_end = (b0 + blade - 4, y - sori + 1.5)
    el.append(stroke_line(rng, (b0, y - 3.0), back_end, width, 0.8, 0.4, bow=sori * 0.4)[1])
    el.append(stroke_line(rng, (b0 + 8, y - 4.0), back_end, width * 0.45, 0.4, 0.8, bow=sori * 0.45)[1])
    el += [stroke_line(rng, (b0, y + 3.0), edge_end, width * 0.9, 0.8, 0.4, bow=sori * 0.4)[1]]
    # Tip (kissaki): the back line kinks down to meet the edge.
    el.append(stroke_line(rng, back_end, tip, width * 0.9, 0.85, 0.2, overshoot=(0.5, 0.5))[1])
    el.append(stroke_line(rng, edge_end, tip, width * 0.8, 0.8, 0.2)[1])
    # Faint wavy temper line (hamon) running along near the edge.
    el.append(stroke_line(rng, (b0 + 6, y + 1.0), (edge_end[0] - 8, edge_end[1] - 2.0),
                          width * 0.35, 0.35, 1.2, bow=sori * 0.45)[1])
    write_svg(OUT / "katana.svg", w, h, el)
    return {"size": [w, h], "pivot": [x0 + handle * 0.5, y], "tip": list(tip),
            "guard": [guard_x, y]}


def paper(w=1152, h=648, rule=32, margin=96):
    """Lined notepad page: off-white, blue rules, red margin."""
    lines = [f'  <rect width="{w}" height="{h}" fill="#fbfaf4"/>']
    for y in range(rule * 3, h, rule):
        lines.append(f'  <line x1="0" y1="{y}" x2="{w}" y2="{y}" stroke="#a9c8e6" stroke-width="1.5"/>')
    lines.append(f'  <line x1="{margin}" y1="0" x2="{margin}" y2="{h}" stroke="#e59a9a" stroke-width="2"/>')
    (OUT / "paper.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
        + "\n".join(lines) + "\n</svg>\n",
        encoding="utf-8",
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    parts = {}
    # A separate RNG per part keeps each one stable when another is tweaked.
    def rng_for(name):
        return random.Random(f"{args.seed}:{name}")

    parts["head"] = head(rng_for("head"), radius=19, width=3.2)
    parts["torso"] = torso(rng_for("torso"), length=74, width=3.6)
    parts["upper_arm"] = limb(rng_for("upper_arm"), "upper_arm", length=38, width=3.0)
    parts["lower_arm"] = limb(rng_for("lower_arm"), "lower_arm", length=36, width=2.8)
    parts["upper_leg"] = limb(rng_for("upper_leg"), "upper_leg", length=46, width=3.4)
    parts["lower_leg"] = limb(rng_for("lower_leg"), "lower_leg", length=46, width=3.2)
    parts["hand"] = hand(rng_for("hand"), rx=5.5, ry=7.5, width=2.4)
    parts["foot"] = foot(rng_for("foot"), length=20, width=3.0)
    parts["katana"] = katana(rng_for("katana"))
    paper()

    (OUT / "stix_parts.json").write_text(json.dumps(parts, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(parts)} parts + paper to {OUT}")


if __name__ == "__main__":
    main()
