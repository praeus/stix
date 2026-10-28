"""Write res://characters/stix/stix_figure.tscn: the Stix Skeleton2D rig with
its sprites, plus RESET / idle / walk animations.

Bone layout comes from art/stix/stix_parts.json, so rerun this after
gen_stix_svgs.py changes part sizes. The walk is keyed as joint-angle tables;
hip height is solved per frame so the lowest foot always touches the ground,
and the matching ground speed is written into the scene's walk_speed.

Angles follow Godot's 2D convention (y down, positive = clockwise). The
figure faces +x, so a positive rotation swings a downward limb backwards and
leans the upward-pointing spine forwards.
"""

import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARTS = json.loads((ROOT / "art" / "stix" / "stix_parts.json").read_text())
OUT = ROOT / "characters" / "stix" / "stix_figure.tscn"

CYCLE = 1.0  # seconds per full walk cycle (two steps)
SAMPLES = 16  # keys per cycle


def seg_len(part):
    p, e = PARTS[part]["pivot"], PARTS[part]["end"]
    return math.dist(p, e)


TORSO = seg_len("torso")
UPPER_ARM = seg_len("upper_arm")
LOWER_ARM = seg_len("lower_arm")
UPPER_LEG = seg_len("upper_leg")
LOWER_LEG = seg_len("lower_leg")
SHOULDER_DROP = 3.0  # how far below the neck the arms attach
BODY_WIDTH = 22.0  # collision box width
FOOT_HEEL = PARTS["foot"]["pivot"][0] - 8  # heel is the stroke start (PAD = 8)
FOOT_TOE = PARTS["foot"]["toe"][0] - PARTS["foot"]["pivot"][0]
STAND_HEIGHT = UPPER_LEG + LOWER_LEG
# On-screen size of the figure relative to the art. The whole skeleton is
# scaled, so poses stay in art pixels; speeds, collider and jump scale with it.
FIGURE_SCALE = 0.5
JUMP_HEIGHT = 120.0  # full-size jump; ~58% of the body height
JUMP_TIME_TO_APEX = 0.4

# --- Walk key poses -------------------------------------------------------
# Eight hand-tuned keys per cycle for one leg, starting at heel strike.
# The other leg runs half a cycle behind. Values are radians.
THIGH = [-0.45, -0.30, -0.05, 0.20, 0.40, 0.15, -0.25, -0.50]
KNEE = [0.05, 0.25, 0.10, 0.05, 0.15, 0.75, 1.10, 0.45]
# Foot angle in world space: toe up at heel strike, flat in stance,
# heel up at push-off, toe trailing in swing.
FOOT_WORLD = [-0.30, 0.00, 0.00, 0.05, 0.45, 0.60, 0.20, -0.15]


# --- Run key poses --------------------------------------------------------
# Same layout as the walk tables: bigger thigh swing, the swing knee folds
# right up under the body, and the foot lands nearer the toes.
RUN_CYCLE = 0.74
THIGH_RUN = [-0.60, -0.25, 0.15, 0.55, 0.80, 0.35, -0.40, -0.85]
KNEE_RUN = [0.25, 0.45, 0.30, 0.20, 0.85, 1.75, 1.95, 0.95]
FOOT_RUN = [-0.10, 0.00, 0.05, 0.40, 0.85, 0.95, 0.35, -0.05]


def periodic(table, p):
    """Catmull-Rom through a looping key table at phase p in [0, 1)."""
    n = len(table)
    x = (p % 1.0) * n
    i = int(x)
    t = x - i
    p0, p1, p2, p3 = (table[(i + k) % n] for k in (-1, 0, 1, 2))
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                  + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3)


def rot(v, a):
    c, s = math.cos(a), math.sin(a)
    return (v[0] * c - v[1] * s, v[0] * s + v[1] * c)


def add(a, b):
    return (a[0] + b[0], a[1] + b[1])


WALK_GAIT = (THIGH, KNEE, FOOT_WORLD)
RUN_GAIT = (THIGH_RUN, KNEE_RUN, FOOT_RUN)


def leg_pose(p, gait=WALK_GAIT):
    thighs, knees, feet = gait
    thigh, knee = periodic(thighs, p), periodic(knees, p)
    foot = periodic(feet, p) - thigh - knee
    return thigh, knee, foot


def leg_points(pose):
    """Ankle, heel and toe relative to the hip joint."""
    thigh, knee, foot = pose
    k = rot((0, UPPER_LEG), thigh)
    ankle = add(k, rot((0, LOWER_LEG), thigh + knee))
    fw = thigh + knee + foot
    return ankle, add(ankle, rot((-FOOT_HEEL, 0), fw)), add(ankle, rot((FOOT_TOE, 0), fw))


def arm_pose(p):
    """Arms swing opposite their own-side leg; elbows bend more going forward."""
    swing = math.cos(math.tau * p)
    upper = 0.34 * swing
    lower = -0.12 - 0.22 * (1 - swing) / 2
    hand = 0.12 * math.sin(math.tau * p)
    return upper, lower, hand


def walk_frames():
    frames = []
    for i in range(SAMPLES):
        p = i / SAMPLES
        right, left = leg_pose(p), leg_pose(p + 0.5)
        lowest = max(pt[1] for pose in (right, left) for pt in leg_points(pose))
        frames.append({
            "hip_y": -lowest,
            "spine": 0.09 + 0.025 * math.cos(2 * math.tau * p),
            "head": -0.06 - 0.02 * math.cos(2 * math.tau * p),
            "leg_r": right, "leg_l": left,
            # Right arm swings with the left leg, and vice versa.
            "arm_r": arm_pose(p + 0.5), "arm_l": arm_pose(p),
        })
    return frames


def run_arm_pose(p):
    """Elbows held at about a right angle, pumping hard front to back."""
    swing = math.cos(math.tau * p)
    upper = 0.8 * swing
    lower = -1.25 - 0.3 * (1 - swing) / 2
    hand = 0.15 * math.sin(math.tau * p)
    return upper, lower, hand


def run_frames():
    frames = []
    for i in range(SAMPLES):
        p = i / SAMPLES
        right, left = leg_pose(p, RUN_GAIT), leg_pose(p + 0.5, RUN_GAIT)
        lowest = max(pt[1] for pose in (right, left) for pt in leg_points(pose))
        bob = math.cos(2 * math.tau * p)
        frames.append({
            "hip_y": -lowest,
            # Lean into the run; the head tips back up to keep looking ahead.
            "spine": 0.30 + 0.04 * bob,
            "head": -0.22 - 0.03 * bob,
            "leg_r": right, "leg_l": left,
            "arm_r": run_arm_pose(p + 0.5), "arm_l": run_arm_pose(p),
        })
    return frames


def stance_speed(gait=WALK_GAIT, cycle=CYCLE):
    """Ground speed that keeps the planted foot still: how fast the right
    ankle moves backwards relative to the hip while it is flat on the floor."""
    a = leg_points(leg_pose(0.0, gait))[0][0]
    b = leg_points(leg_pose(0.5, gait))[0][0]
    return (a - b) / (0.5 * cycle)


def idle_frames():
    """Slow breathing: the chest rises a touch and the arms drift."""
    frames = []
    for i in range(8):
        p = i / 8
        b = math.sin(math.tau * p)
        frames.append({
            "hip_y": -STAND_HEIGHT + 0.6 * (1 - math.cos(math.tau * p)) / 2,
            "spine": 0.015 * b,
            "head": -0.02 * b,
            "leg_r": (-0.08, 0.04, 0.04), "leg_l": (0.10, 0.02, -0.12),
            "arm_r": (-0.10 - 0.03 * b, -0.15, 0.0), "arm_l": (0.12 + 0.03 * b, -0.20, 0.0),
        })
    # The legs are spread, so the hip has to sit a touch lower to reach the floor.
    lowest = max(pt[1] for pose in (frames[0]["leg_r"], frames[0]["leg_l"])
                 for pt in leg_points(pose))
    for f in frames:
        f["hip_y"] += STAND_HEIGHT - lowest
    return frames


# --- Jump -----------------------------------------------------------------
# The jump is driven by code: jump_start (crouch + push off) plays on the
# ground, jump_air is scrubbed by vertical velocity (0 = launch, 1 = falling
# fast), and jump_land absorbs the impact. The figure's origin stays at the
# feet, so the hip is solved so the lowest foot point sits at y = 0 whenever
# the feet are meant to touch the ground.

def leg(thigh, knee, foot_world):
    return thigh, knee, foot_world - thigh - knee


def ground_hip(leg_r, leg_l):
    return -max(pt[1] for pose in (leg_r, leg_l) for pt in leg_points(pose))


def pose(spine, head, leg_r, leg_l, arm_r, arm_l, hip_y=None):
    return {"hip_y": ground_hip(leg_r, leg_l) if hip_y is None else hip_y,
            "spine": spine, "head": head, "leg_r": leg_r, "leg_l": leg_l,
            "arm_r": arm_r, "arm_l": arm_l}


def jump_poses():
    stand = idle_frames()[0]
    # Deep crouch: knees forward, body folded, arms swung back to load up.
    crouch = pose(0.38, -0.25, leg(-1.0, 1.65, 0.0), leg(-0.85, 1.5, 0.0),
                  (0.85, -0.25, 0.1), (0.7, -0.2, 0.1))
    # Push-off: legs straight, toes pointing down, arms thrown up and forward.
    takeoff = pose(0.06, -0.05, leg(0.12, 0.05, 0.95), leg(0.2, 0.08, 1.0),
                   (-2.5, -0.25, -0.1), (-2.3, -0.3, -0.1))
    # Falling: legs reaching down for the ground, arms out for balance.
    fall_r, fall_l = leg(-0.35, 0.4, 0.15), leg(-0.15, 0.5, 0.25)
    air_hip = ground_hip(fall_r, fall_l)
    # Rising: knees tucked, arms still high.
    rise = pose(0.12, -0.1, leg(-0.95, 1.45, 0.35), leg(-0.75, 1.55, 0.45),
                (-2.3, -0.4, 0.0), (-2.1, -0.45, 0.0), hip_y=air_hip)
    apex = pose(0.08, -0.05, leg(-0.7, 1.0, 0.25), leg(-0.5, 1.1, 0.35),
                (-1.7, -0.35, 0.0), (-1.4, -0.4, 0.0), hip_y=air_hip)
    fall = pose(0.04, 0.0, fall_r, fall_l, (-1.35, -0.25, 0.1), (-0.95, -0.3, 0.1),
                hip_y=air_hip)
    # Landing: knees soak up the impact, arms come down in front.
    land = pose(0.3, -0.2, leg(-0.8, 1.3, 0.0), leg(-0.65, 1.2, 0.0),
                (-0.55, -0.3, 0.0), (-0.35, -0.3, 0.0))
    # Running jump: no crouch, the figure springs straight out of its stride
    # into a long leap with the legs split front and back.
    stride = run_frames()[SAMPLES // 4]
    leap_hip = air_hip
    # Right leg trails behind, left leg drives forward; the arms oppose them.
    push = pose(0.32, -0.22, leg(0.55, 0.25, 0.9), leg(-0.9, 1.4, 0.2),
                (-0.9, -1.1, 0.0), (0.7, -1.2, 0.0))
    leap_rise = pose(0.26, -0.2, leg(0.75, 0.5, 1.0), leg(-1.2, 1.1, 0.2),
                     (-1.4, -0.7, 0.0), (0.9, -0.9, 0.0), hip_y=leap_hip)
    leap_apex = pose(0.2, -0.16, leg(0.85, 0.7, 1.0), leg(-1.35, 0.7, 0.1),
                     (-1.6, -0.5, 0.0), (0.6, -0.6, 0.0), hip_y=leap_hip)
    # Coming down: the front leg reaches for the ground, the back leg follows through.
    leap_fall = pose(0.16, -0.1, leg(0.2, 1.1, 0.6), leg(-0.9, 0.5, 0.05),
                     (-1.2, -0.5, 0.1), (-0.2, -0.6, 0.1), hip_y=leap_hip)
    run_land = pose(0.34, -0.24, leg(0.3, 0.8, 0.3), leg(-0.7, 1.15, 0.0),
                    (-0.7, -1.2, 0.0), (0.5, -1.2, 0.0))
    return {
        "jump_start": ([0.0, 0.13, 0.22], [stand, crouch, takeoff]),
        "jump_air": ([0.0, 0.2, 0.5, 0.85, 1.0], [takeoff, rise, apex, fall, fall]),
        "jump_land": ([0.0, 0.1, 0.32], [fall, land, stand]),
        "run_jump_start": ([0.0, 0.09], [stride, push]),
        "run_jump_air": ([0.0, 0.2, 0.5, 0.85, 1.0],
                         [push, leap_rise, leap_apex, leap_fall, leap_fall]),
        "run_jump_land": ([0.0, 0.12], [leap_fall, run_land]),
    }


# --- Sword ----------------------------------------------------------------
# The sword sits in the right hand along the hand bone's +x, so with the arm
# hanging it points straight ahead. Its world angle is the sum of the arm
# angles (upper + lower + hand). Sword animations play on a second
# AnimationPlayer that only keys the arms (and the spine for the swing),
# layered over whatever the legs are doing. Poses are set for the right arm;
# the left arm is solved to grip the handle just behind the right fist.

# Where the fist closes, in the hand bone's space: the middle of the hand oval.
GRIP = (0.0, PARTS["hand"]["center"][1] - PARTS["hand"]["pivot"][1])
# Upright in front of the chest, leaning a little forward.
SWORD_HOLD = (-0.45, -1.2, 0.25)
# Gap along the handle from the right fist back to the left one, toward the pommel.
HANDS_APART = 15.0
# The swing is keyed this often, so the solved left hand stays on the handle
# between the hand-set poses instead of drifting off it.
SWORD_KEY_RATE = 60


def angle_of(v):
    """Bone rotation that points a hanging (+y) bone along v."""
    return math.atan2(-v[0], v[1])


def right_grip(arm):
    """Where the right fist holds the sword, from the shoulder, and the
    sword's world angle."""
    u, lo, h = arm
    wrist = add(rot((0, UPPER_ARM), u), rot((0, LOWER_ARM), u + lo))
    return add(wrist, rot(GRIP, u + lo + h)), u + lo + h


def left_arm_to(target):
    """Two-bone IK from the shoulder: left arm angles that put the left fist
    on target. The hand stays in line with the forearm, and the elbow bends
    the natural way (behind), which is the negative-lower solution."""
    a, b = UPPER_ARM, LOWER_ARM + GRIP[1]
    d = min(max(math.hypot(*target), abs(a - b) + 0.01), a + b - 0.01)
    alpha = math.acos((a * a + d * d - b * b) / (2 * a * d))
    gamma = math.acos((a * a + b * b - d * d) / (2 * a * b))
    return angle_of(target) + alpha, -(math.pi - gamma), 0.0


def two_handed(frame):
    grip, angle = right_grip(frame["arm_r"])
    back = rot((HANDS_APART, 0.0), angle)
    return {**frame, "arm_l": left_arm_to((grip[0] - back[0], grip[1] - back[1]))}


def hermite(times, values, t):
    """Smooth curve through keyed values (Catmull-Rom tangents, flat ends)."""
    n = len(times)
    i = max(k for k in range(n - 1) if times[k] <= t) if t < times[-1] else n - 2
    t0, t1 = times[i], times[i + 1]

    def tangent(k):
        if k == 0 or k == n - 1:
            return 0.0
        return (values[k + 1] - values[k - 1]) / (times[k + 1] - times[k - 1])

    s = (t - t0) / (t1 - t0)
    h00, h10 = 2 * s ** 3 - 3 * s ** 2 + 1, s ** 3 - 2 * s ** 2 + s
    h01, h11 = -2 * s ** 3 + 3 * s ** 2, s ** 3 - s ** 2
    dt = t1 - t0
    return (h00 * values[i] + h10 * dt * tangent(i) + h01 * values[i + 1]
            + h11 * dt * tangent(i + 1))


def densify(times, frames):
    """Resample hand-set sword poses at SWORD_KEY_RATE."""
    count = round(times[-1] * SWORD_KEY_RATE)
    out_times = [times[-1] * i / count for i in range(count + 1)]
    out = []
    for t in out_times:
        spine = hermite(times, [f["spine"] for f in frames], t)
        head = hermite(times, [f["head"] for f in frames], t)
        arm = tuple(hermite(times, [f["arm_r"][j] for f in frames], t) for j in range(3))
        out.append(sword_frames(spine, head, arm))
    return out_times, out


def sword_frames(spine, head, arm_r):
    return {"spine": spine, "head": head, "arm_r": arm_r}


def sword_poses():
    """{name: (key times, frames, loop)}. A frame with spine None leaves the
    spine and head to the main animation."""
    hold = sword_frames(None, None, SWORD_HOLD)
    # Overhead, blade hanging back behind the head; leaning back to load up.
    windup = sword_frames(-0.08, 0.02, (-2.8, -0.85, 0.15))
    # Arm whips forward and the blade comes down level, body leaning in.
    strike = sword_frames(0.32, -0.18, (-1.45, -0.35, 1.9))
    # Follow-through: blade carries on down and forward.
    follow = sword_frames(0.36, -0.2, (-0.7, -0.35, 1.75))
    settle = sword_frames(0.09, -0.06, SWORD_HOLD)
    swing_times, swing = densify([0.0, 0.11, 0.19, 0.27, 0.42],
                                 [sword_frames(0.09, -0.06, SWORD_HOLD), windup, strike, follow, settle])
    return {
        "sword_hold": ([0.0], [two_handed(hold)], True),
        "sword_swing": (swing_times, [two_handed(f) for f in swing], False),
    }


def sword_tracks(frames):
    paths = bone_paths()
    tracks = {}

    def put(bone_name, prop, value):
        tracks.setdefault(f"{paths[bone_name]}:{prop}", []).append(value)

    for f in frames:
        spine = f["spine"]
        if spine is not None:
            put("Spine", "rotation", spine)
            put("Head", "rotation", f["head"])
        for side, key in (("R", "arm_r"), ("L", "arm_l")):
            u, lo, h = f[key]
            put(f"UpperArm{side}", "rotation", u - (spine or 0.0))
            put(f"LowerArm{side}", "rotation", lo)
            put(f"Hand{side}", "rotation", h)
    return tracks


# --- Scene writing --------------------------------------------------------

def vec(x, y):
    return f"Vector2({x:.6g}, {y:.6g})"


BONES = []  # (name, parent path, position, bone_angle, length, sprite part)


def bone(name, parent, pos, angle, length, part=None):
    BONES.append((name, parent, pos, angle, length, part))
    return f"{parent}/{name}"


def build_bones():
    hip = bone("Hip", "Skeleton2D", (0, -STAND_HEIGHT), -90, 1)
    spine = bone("Spine", hip, (0, 0), -90, TORSO, "torso")
    neck = bone("Neck", spine, (0, -TORSO), -90, SHOULDER_DROP)
    bone("Head", neck, (0, 0), -90, 2 * PARTS["head"]["radius"], "head")
    # Far side (L) first so the near side (R) draws on top.
    for side in ("L", "R"):
        ua = bone(f"UpperArm{side}", neck, (0, SHOULDER_DROP), 90, UPPER_ARM, "upper_arm")
        la = bone(f"LowerArm{side}", ua, (0, UPPER_ARM), 90, LOWER_ARM, "lower_arm")
        bone(f"Hand{side}", la, (0, LOWER_ARM), 90, 2 * 7.5, "hand")
    for side in ("L", "R"):
        ul = bone(f"UpperLeg{side}", hip, (0, 0), 90, UPPER_LEG, "upper_leg")
        ll = bone(f"LowerLeg{side}", ul, (0, UPPER_LEG), 90, LOWER_LEG, "lower_leg")
        bone(f"Foot{side}", ll, (0, LOWER_LEG), 0, FOOT_TOE, "foot")


def bone_paths():
    return {name: f"{parent}/{name}" for name, parent, *_ in BONES}


def pose_tracks(frames):
    """Map frame dicts to {track path: [values]}."""
    paths = bone_paths()
    tracks = {}

    def put(bone_name, prop, value):
        tracks.setdefault(f"{paths[bone_name]}:{prop}", []).append(value)

    for f in frames:
        put("Hip", "position", ("vec", 0.0, f["hip_y"]))
        put("Spine", "rotation", f["spine"])
        put("Head", "rotation", f["head"])
        for side, key in (("R", "r"), ("L", "l")):
            t, k, ft = f[f"leg_{key}"]
            put(f"UpperLeg{side}", "rotation", t)
            put(f"LowerLeg{side}", "rotation", k)
            put(f"Foot{side}", "rotation", ft)
            u, lo, h = f[f"arm_{key}"]
            # Arms hang from the neck, so cancel the spine lean to keep the
            # swing measured from vertical.
            put(f"UpperArm{side}", "rotation", u - f["spine"])
            put(f"LowerArm{side}", "rotation", lo)
            put(f"Hand{side}", "rotation", h)
    return tracks


def fmt_value(v):
    if isinstance(v, tuple) and v[0] == "vec":
        return vec(v[1], v[2])
    # Always write a decimal point: a bare "0" makes Godot type the whole
    # track as int and round every rotation to zero.
    s = f"{v:.5g}"
    return s if any(c in s for c in ".e") else s + ".0"


def animation(res_id, name, length, tracks, loop=True, key_times=None):
    """Evenly spaced keys by default; pass key_times for hand-timed poses."""
    n = len(next(iter(tracks.values())))
    if key_times is None:
        key_times = [length * i / n for i in range(n)]
    times = ", ".join(f"{t:.6g}" for t in key_times)
    ones = ", ".join("1" for _ in range(n))
    out = [f'[sub_resource type="Animation" id="{res_id}"]',
           f'resource_name = "{name}"',
           f"length = {length:g}"]
    if loop:
        out.append("loop_mode = 1")
    out.append(f"step = {length / n if loop else 0.01:.6g}")
    for i, (path, values) in enumerate(tracks.items()):
        out += [f'tracks/{i}/type = "value"',
                f"tracks/{i}/imported = false",
                f"tracks/{i}/enabled = true",
                f'tracks/{i}/path = NodePath("{path}")',
                f"tracks/{i}/interp = 2",
                f"tracks/{i}/loop_wrap = true",
                f"tracks/{i}/keys = {{",
                f'"times": PackedFloat32Array({times}),',
                f'"transitions": PackedFloat32Array({ones}),',
                '"update": 0,',
                f'"values": [{", ".join(fmt_value(v) for v in values)}]',
                "}"]
    return out + [""]


def reset_tracks():
    """Rest pose for every animated property (what the editor shows)."""
    tracks = {}
    for path in pose_tracks(walk_frames()):
        bone_path, prop = path.rsplit(":", 1)
        if prop == "position":
            tracks[path] = [("vec", 0.0, -STAND_HEIGHT)]
        else:
            tracks[path] = [0.0]
    return tracks


def main():
    build_bones()
    textures = sorted({b[5] for b in BONES if b[5]} | {"katana"})
    tex_id = {name: f"tex_{name}" for name in textures}

    jumps = jump_poses()
    swords = sword_poses()
    lines = [f"[gd_scene load_steps={len(textures) + 9 + len(jumps) + len(swords)} format=3]", "",
             '[ext_resource type="Script" path="res://characters/stix/stix_figure.gd" id="script"]']
    for name in textures:
        lines.append(f'[ext_resource type="Texture2D" path="res://art/stix/{name}.svg" id="{tex_id[name]}"]')
    lines.append("")

    lines += animation("Animation_reset", "RESET", 0.001, reset_tracks(), loop=False)
    lines += animation("Animation_idle", "idle", 3.0, pose_tracks(idle_frames()))
    lines += animation("Animation_walk", "walk", CYCLE, pose_tracks(walk_frames()))
    lines += animation("Animation_run", "run", RUN_CYCLE, pose_tracks(run_frames()))
    for name, (times, frames) in jumps.items():
        lines += animation(f"Animation_{name}", name, times[-1], pose_tracks(frames),
                           loop=False, key_times=times)
    names = ["RESET", "idle", "walk", "run", *jumps]
    lines += ['[sub_resource type="AnimationLibrary" id="AnimationLibrary_stix"]',
              "_data = {",
              ",\n".join(f'&"{n}": SubResource("Animation_{n.lower() if n == "RESET" else n}")'
                         for n in names),
              "}", ""]
    for name, (times, frames, loop) in swords.items():
        lines += animation(f"Animation_{name}", name, max(times[-1], 0.1), sword_tracks(frames),
                           loop=loop, key_times=times)
    lines += ['[sub_resource type="AnimationLibrary" id="AnimationLibrary_sword"]',
              "_data = {",
              ",\n".join(f'&"{n}": SubResource("Animation_{n}")' for n in swords),
              "}", ""]

    # Body collider: feet at the origin up to the top of the head.
    body_h = (STAND_HEIGHT + TORSO + 2 + 2 * PARTS["head"]["radius"]) * FIGURE_SCALE
    lines += ['[sub_resource type="RectangleShape2D" id="RectangleShape2D_body"]',
              f"size = {vec(BODY_WIDTH * FIGURE_SCALE, body_h)}", ""]

    speed = stance_speed() * FIGURE_SCALE
    run_speed = stance_speed(RUN_GAIT, RUN_CYCLE) * FIGURE_SCALE
    # A smaller body jumps proportionally lower, and quicker: fall time goes
    # with the square root of the height, so gravity stays the same.
    jump_height = JUMP_HEIGHT * FIGURE_SCALE
    jump_time = JUMP_TIME_TO_APEX * math.sqrt(FIGURE_SCALE)
    lines += ['[node name="StixFigure" type="CharacterBody2D"]',
              'script = ExtResource("script")',
              f"walk_speed = {speed:.4g}",
              f"run_speed = {run_speed:.4g}",
              f"jump_height = {jump_height:.4g}",
              f"jump_time_to_apex = {jump_time:.4g}", "",
              '[node name="Collision" type="CollisionShape2D" parent="."]',
              f"position = {vec(0, -body_h / 2)}",
              'shape = SubResource("RectangleShape2D_body")', "",
              '[node name="Skeleton2D" type="Skeleton2D" parent="."]',
              f"scale = {vec(FIGURE_SCALE, FIGURE_SCALE)}", ""]

    for name, parent, pos, angle, length, part in BONES:
        lines += [f'[node name="{name}" type="Bone2D" parent="{parent}"]',
                  f"position = {vec(*pos)}",
                  f"rest = Transform2D(1, 0, 0, 1, {pos[0]:g}, {pos[1]:.6g})",
                  "auto_calculate_length_and_angle = false",
                  f"length = {length:.6g}",
                  f"bone_angle = {angle:g}", ""]
        if part:
            px, py = PARTS[part]["pivot"]
            lines += [f'[node name="Sprite" type="Sprite2D" parent="{parent}/{name}"]',
                      f'texture = ExtResource("{tex_id[part]}")',
                      "centered = false",
                      f"offset = {vec(-px, -py)}", ""]
        if name == "HandR":
            # Hidden until a sword is picked up; drawn over the fist.
            sx, sy = PARTS["katana"]["pivot"]
            lines += [f'[node name="Sword" type="Sprite2D" parent="{parent}/{name}"]',
                      "visible = false",
                      f"position = {vec(*GRIP)}",
                      f'texture = ExtResource("{tex_id["katana"]}")',
                      "centered = false",
                      f"offset = {vec(-sx, -sy)}", ""]

    lines += ['[node name="AnimationPlayer" type="AnimationPlayer" parent="."]',
              'libraries = {',
              '&"": SubResource("AnimationLibrary_stix")',
              "}",
              'autoplay = &"idle"', "",
              # After the main player in the tree, so it applies last and its
              # arm keys win over the walk/run/jump arms.
              '[node name="SwordPlayer" type="AnimationPlayer" parent="."]',
              'libraries = {',
              '&"": SubResource("AnimationLibrary_sword")',
              "}", ""]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT} (walk_speed = {speed:.1f} px/s, run_speed = {run_speed:.1f} px/s)")
    for i, f in enumerate(walk_frames()):
        print(f"  walk {i:2d}: hip_y={f['hip_y']:7.2f}  "
              f"R ankle x={leg_points(f['leg_r'])[0][0]:6.1f}  L ankle x={leg_points(f['leg_l'])[0][0]:6.1f}")


if __name__ == "__main__":
    main()
