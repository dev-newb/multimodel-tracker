#!/usr/bin/env python3
"""Check synchronous native window events from manually exercised roll-ups."""
import argparse
import json

parser = argparse.ArgumentParser()
parser.add_argument("trace")
parser.add_argument("--kind", choices=["popover", "panel"], default="popover")
parser.add_argument("--min-transitions", type=int, default=2)
args = parser.parse_args()
with open(args.trace) as stream:
    rows = [json.loads(line) for line in stream if line.strip()]

before = "before resize" if args.kind == "popover" else "before panel resize"
after = "after resize" if args.kind == "popover" else "after panel resize"
groups = []
current = []
for row in rows:
    if current and (row["time"] - current[-1]["time"] > 0.3 or row["pid"] != current[0]["pid"]):
        groups.append(current)
        current = []
    if row["event"] == before or current:
        # A hidden popover may also receive layout while the panel is open.
        if ("hostingFrame" in row) == (args.kind == "popover"):
            current.append(row)
if current:
    groups.append(current)

checked = 0
for group in groups:
    # Exclude initial layout/reopening; a roll-up has intermediate size steps.
    if sum(row["event"] == after for row in group) < 3:
        continue
    frames = [row["window"] for row in group if row.get("window")]
    if abs(frames[-1][2] - frames[0][2]) > 1:
        continue  # Switching grid layout is intentionally a width change.
    xs = [f[0] for f in frames]
    tops = [f[1] + f[3] for f in frames]
    heights = [f[3] for f in frames]
    direction = 1 if heights[-1] > heights[0] else -1
    assert max(f[2] for f in frames) - min(f[2] for f in frames) <= 1, "Width jitter"
    assert max(xs) - min(xs) <= 1, f"Horizontal excursion: {max(xs) - min(xs):.1f} pt"
    assert max(tops) - min(tops) <= 1, f"Top-edge excursion: {max(tops) - min(tops):.1f} pt"
    assert all(direction * (b - a) >= -1 for a, b in zip(heights, heights[1:])), "Height reversed during transition"
    checked += 1
assert checked >= args.min_transitions, f"Only {checked} transitions; need {args.min_transitions}"
print(f"PASS: {checked} {args.kind} transitions; all synchronous frame events kept x/top fixed")
