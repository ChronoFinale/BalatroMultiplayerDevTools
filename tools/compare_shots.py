#!/usr/bin/env python3
"""Visual regression compare for the DevTools screenshot suite.

Usage:
  python compare_shots.py                 # compare current run against goldens
  python compare_shots.py --accept        # promote current run to goldens
  python compare_shots.py --accept 03-random-armed   # promote one scenario

Reads %APPDATA%/Balatro/shot_suite/ (the suite's output: PNGs + manifest.json)
and compares against the goldens/ directory next to this script. A scenario's
manifest entry may carry a crop region (fractions of the frame) so only the
stable UI area is compared -- the animated background never participates.

Exit code 0 = all match, 1 = differences or missing goldens. Diff images are
written to shot_suite/diff/ with mismatching pixels highlighted.
"""

import argparse
import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageChops

TOLERANCE = 12          # per-channel delta considered "same" (antialias wiggle)
MAX_BAD_FRACTION = 0.002  # fraction of compared pixels allowed over tolerance

SUITE_DIR = Path(os.environ["APPDATA"]) / "Balatro" / "shot_suite"
GOLDEN_DIR = Path(__file__).resolve().parent.parent / "goldens"


def load_manifest():
    p = SUITE_DIR / "manifest.json"
    if not p.exists():
        sys.exit(f"no manifest at {p} - run the suite first (BMP_SHOT_SUITE=1)")
    return json.loads(p.read_text(encoding="utf-8"))


def crop(img, region):
    if not region:
        return img
    w, h = img.size
    x0, y0 = int(region["x"] * w), int(region["y"] * h)
    x1, y1 = x0 + int(region["w"] * w), y0 + int(region["h"] * h)
    return img.crop((x0, y0, x1, y1))


def compare_one(name, region):
    cur_p = SUITE_DIR / f"{name}.png"
    gold_p = GOLDEN_DIR / f"{name}.png"
    if not cur_p.exists():
        return "MISSING-CURRENT"
    if not gold_p.exists():
        return "NO-GOLDEN"
    cur = crop(Image.open(cur_p).convert("RGB"), region)
    gold = crop(Image.open(gold_p).convert("RGB"), region)
    if cur.size != gold.size:
        return "SIZE-MISMATCH"
    diff = ImageChops.difference(cur, gold)
    bad = 0
    px = diff.getdata()
    for r, g, b in px:
        if r > TOLERANCE or g > TOLERANCE or b > TOLERANCE:
            bad += 1
    frac = bad / max(1, len(list(px)))
    if frac <= MAX_BAD_FRACTION:
        return "OK"
    out = SUITE_DIR / "diff"
    out.mkdir(exist_ok=True)
    # Highlight: keep the current image dimmed, paint bad pixels red.
    mask = diff.point(lambda v: 255 if v > TOLERANCE else 0).convert("L")
    marked = Image.blend(cur, Image.new("RGB", cur.size, (40, 40, 40)), 0.55)
    marked.paste(Image.new("RGB", cur.size, (255, 40, 40)), mask=mask)
    marked.save(out / f"{name}.png")
    return f"DIFF {frac * 100:.2f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--accept", nargs="?", const="__all__", default=None)
    args = ap.parse_args()
    manifest = load_manifest()
    scenarios = [(e["name"], e.get("region")) for e in manifest["scenarios"] if e.get("status") == "captured"]
    broken = [(e["name"], e.get("status"), e.get("error", "")) for e in manifest["scenarios"]
              if e.get("status") not in ("captured", "skipped")]
    skipped = [e["name"] for e in manifest["scenarios"] if e.get("status") == "skipped"]

    if args.accept is not None:
        GOLDEN_DIR.mkdir(exist_ok=True)
        for name, _ in scenarios:
            if args.accept not in ("__all__", name):
                continue
            src = SUITE_DIR / f"{name}.png"
            if src.exists():
                (GOLDEN_DIR / f"{name}.png").write_bytes(src.read_bytes())
                print(f"accepted {name}")
        return

    failed = False
    # A scenario that ERRORED is a failing run -- silence here would report
    # green on a broken suite.
    for name, status, err in broken:
        print(f"{name:40s} {status.upper()}: {err}")
        failed = True
    for name in skipped:
        print(f"{name:40s} SKIPPED")
    for name, region in scenarios:
        verdict = compare_one(name, region)
        print(f"{name:40s} {verdict}")
        if verdict != "OK":
            failed = True
    if failed:
        print(f"\ndiff images (if any): {SUITE_DIR / 'diff'}")
        sys.exit(1)
    print("\nall scenarios match goldens")


if __name__ == "__main__":
    main()
