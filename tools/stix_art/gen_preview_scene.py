"""Write res://scenes/preview/stix_parts_preview.tscn: every part laid out on
the notepad page plus one assembled figure, for eyeballing the art.

Reads art/stix/stix_parts.json, so run gen_stix_svgs.py first.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARTS = json.loads((ROOT / "art" / "stix" / "stix_parts.json").read_text())
OUT = ROOT / "scenes" / "preview" / "stix_parts_preview.tscn"

TEXTURES = ["paper", "head", "torso", "upper_arm", "lower_arm",
            "upper_leg", "lower_leg", "hand", "foot"]
tex_id = {name: i + 1 for i, name in enumerate(TEXTURES)}

lines = [f"[gd_scene load_steps={len(TEXTURES) + 1} format=3]", ""]
for name in TEXTURES:
    lines.append(f'[ext_resource type="Texture2D" path="res://art/stix/{name}.svg" id="{tex_id[name]}"]')
lines.append("")
lines.append('[node name="StixPartsPreview" type="Node2D"]')
lines.append("")
lines += ['[node name="Paper" type="Sprite2D" parent="."]',
          f'texture = ExtResource("{tex_id["paper"]}")', "centered = false", ""]


def vec(x, y):
    return f"Vector2({x:g}, {y:g})"


def sprite(name, parent, part, pos=(0, 0)):
    px, py = PARTS[part]["pivot"]
    return [f'[node name="{name}" type="Sprite2D" parent="{parent}"]',
            f"position = {vec(*pos)}",
            f'texture = ExtResource("{tex_id[part]}")',
            "centered = false",
            f"offset = {vec(-px, -py)}", ""]


def joint(name, parent, pos, rot=0.0):
    out = [f'[node name="{name}" type="Node2D" parent="{parent}"]', f"position = {vec(*pos)}"]
    if rot:
        out.append(f"rotation = {rot:g}")
    return out + [""]


# Row of loose parts, each placed at its pivot so the pivots line up on a rule.
lines += joint("Parts", ".", (0, 0))
x = 150
for part in TEXTURES[1:]:
    w, _ = PARTS[part]["size"]
    px, _ = PARTS[part]["pivot"]
    y = 288 if part not in ("torso", "head") else 352
    lines += sprite(part.title().replace("_", ""), "Parts", part, (x + px, y))
    x += w + 28


def length(part):
    p, e = PARTS[part]["pivot"], PARTS[part]["end"]
    return ((e[0] - p[0]) ** 2 + (e[1] - p[1]) ** 2) ** 0.5


# Assembled figure in a relaxed stance.
torso = length("torso")
lines += joint("Figure", ".", (820, 432))
lines += sprite("Torso", "Figure", "torso")
lines += joint("Neck", "Figure", (0, -torso))
lines += sprite("Head", "Figure/Neck", "head")
for side, sign in (("L", 1), ("R", -1)):
    shoulder = f"Figure/Shoulder{side}"
    lines += joint(f"Shoulder{side}", "Figure", (0, -torso + 3), 0.35 * sign)
    lines += sprite("UpperArm", shoulder, "upper_arm")
    lines += joint("Elbow", shoulder, (0, length("upper_arm")), -0.2 * sign)
    lines += sprite("LowerArm", f"{shoulder}/Elbow", "lower_arm")
    lines += joint("Wrist", f"{shoulder}/Elbow", (0, length("lower_arm")))
    lines += sprite("Hand", f"{shoulder}/Elbow/Wrist", "hand")

    hip = f"Figure/Hip{side}"
    lines += joint(f"Hip{side}", "Figure", (0, 0), 0.18 * sign)
    lines += sprite("UpperLeg", hip, "upper_leg")
    lines += joint("Knee", hip, (0, length("upper_leg")), -0.05 * sign)
    lines += sprite("LowerLeg", f"{hip}/Knee", "lower_leg")
    lines += joint("Ankle", f"{hip}/Knee", (0, length("lower_leg")), -0.13 * sign)
    # Both feet point the way the figure faces (+x).
    lines += sprite("Foot", f"{hip}/Knee/Ankle", "foot")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines), encoding="utf-8")
print(f"Wrote {OUT}")
