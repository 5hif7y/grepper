#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""--max-columns-preview against ripgrep: grapheme clusters at the cut of a long line.

rg cuts a long line after its first N extended grapheme clusters (bstr's UAX #29
segmentation). Lines here are built from the code points each rule of UAX #29 is about:
Hangul jamo and syllables (L, V, T, LV, LVT), regional indicators, emoji with ZWJ sequences
and modifiers, Extend, SpacingMark, Prepend, controls, CR and LF, plus ASCII (bstr's fast
path, and its whitespace exception) and invalid UTF-8 (U+FFFD for the maximal invalid
prefix). Each file is searched with -M N --max-columns-preview for several N, with and
without -o, colour, context and -U; stdout and exit code must equal rg 14.1.1's.

With -r the reference is rg 16.0.0 (--rg16, or RG16), and without it those runs are
skipped: 14.1.1 drops a replaced line's terminator and puts 
 back under --crlf (U3100 in
docs/PARITY.md, fixed in grepper as upstream fixed it), so it measures a replaced line one or
two bytes short against -M.

usage: python tests/grapheme_fuzz.py [--seed N] [-n N] [--grepper PATH] [--rg PATH] [--rg16 PATH]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

POOL = {
    "ascii": ["a", "b", "x", "needle", " ", "\t", "0", "-", "\x0b", "\x0c"],
    "crlf": ["\r", "\r\n"],
    "control": ["\x01", "\x7f", "​", " ", "­"],
    "hangul_L": ["ᄀ", "ᄒ", "ꥠ"],
    "hangul_V": ["ᅡ", "ᅵ", "ힰ"],
    "hangul_T": ["ᆨ", "ᇂ", "ퟋ"],
    "hangul_LV": ["가", "개"],
    "hangul_LVT": ["각", "힣"],
    "ri": ["\U0001f1fa", "\U0001f1f8", "\U0001f1e6"],
    "emoji": ["\U0001f469", "\U0001f4bb", "❤", "\U0001f3fd", "️", "\U0001f9d1"],
    "zwj": ["‍"],
    "extend": ["́", "̈", "⃣", "\U000e0020"],
    "spacing": ["ः", "ा", "ำ"],
    "prepend": ["؀", "؅", "ᄋd"],
    "other": ["é", "中", "क", "्", "\U00010348"],
    # whole sequences, which single code points drawn at random seldom make
    "sequences": [
        "\U0001f469‍\U0001f4bb", "❤️‍\U0001f525", "\U0001f9d1\U0001f3fd‍\U0001f4bb",
        "\U0001f468‍\U0001f469‍\U0001f467", "\U0001f1fa\U0001f1f8", "\U0001f1fa\U0001f1f8\U0001f1e6",
        "각", "ᄀᄀ각", "؀कः", "é̈",
    ],
}
INVALID = [b"\xff", b"\xc3", b"\xe2\x82", b"\xf0\x9f\x91", b"\xed\xa0\x80", b"\xc0\xaf", b"\xf4\x90\x80\x80"]


def gen_line(rnd):
    out = bytearray()
    for _ in range(rnd.randint(1, 40)):
        if rnd.random() < 0.08:
            out += rnd.choice(INVALID)
        else:
            kind = rnd.choice(list(POOL))
            out += rnd.choice(POOL[kind]).encode("utf-8")
    if rnd.random() < 0.7:
        cut = rnd.randint(0, len(out))
        out[cut:cut] = b"needle"
    return bytes(out).replace(b"\n", b"")


def run(exe, args):
    r = subprocess.run([exe, *args], capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
    return r.returncode, r.stdout


def main():
    sys.stdout.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--rg16", default=os.environ.get("RG16"))
    ap.add_argument("-n", type=int, default=150)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    bad = 0
    total = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "g.txt")
        for k in range(a.n):
            lines = [gen_line(rnd) for _ in range(rnd.randint(1, 6))]
            with open(path, "wb") as f:
                f.write(b"\n".join(lines) + b"\n")
            for _ in range(4):
                n = rnd.choice([1, 2, 3, 4, 5, 7, 10, 16, 30])
                extra = rnd.choice([[], ["-o"], ["--color=always"], ["-C1"], ["-n", "-b"], ["-U"], ["-r", "R"], ["-v"]])
                pat = rnd.choice(["needle", "e", ".", "\\p{L}", "x|é"])
                args = ["-M", str(n), "--max-columns-preview", *extra, "-e", pat, path]
                ref = a.rg
                if "-r" in extra:
                    if not a.rg16:
                        continue
                    ref = a.rg16
                total += 1
                g, r = run(a.grepper, args), run(ref, args)
                if g != r:
                    bad += 1
                    print(f"DIFF run {k}: {args[:-1]!r}")
                    with open(path, "rb") as f:
                        print(f"  file {f.read()[:200]!r}")
                    gl, rl = g[1].splitlines(), r[1].splitlines()
                    for i, (x, y) in enumerate(zip(rl, gl)):
                        if x != y:
                            print(f"  line {i}: rg {x!r}\n          grepper {y!r}")
                            break
                    else:
                        print(f"  rg {len(rl)} lines rc {r[0]}, grepper {len(gl)} lines rc {g[0]}")
    print(f"{total - bad}/{total} previews match rg (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
