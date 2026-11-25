#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""Literal sets past Teddy against ripgrep: Aho-Corasick's leftmost-first semantics.

Random sets of literals over a small alphabet (so patterns are often prefixes of each other
and overlap), searched with -F -o -b (every match and its offset) in random haystacks over
the same alphabet. The sizes reach the two places regex-automata uses Aho-Corasick: as the
prefilter when Teddy refuses a set (more than 64 literals, within the literal extraction's
limit) and as the whole search from 3000 literals (Pre::from_alternation_literals). Some
sets are given as one regex alternation of escaped literals instead of -F, which takes the
regex path to the same strategies. stdout and exit code must equal rg 14.1.1's.

usage: python tests/aho_fuzz.py [--seed N] [-n N] [--grepper PATH] [--rg PATH]
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    sys.stdout.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-n", type=int, default=60)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        pats_path = os.path.join(tmp, "pats.txt")
        hay_path = os.path.join(tmp, "hay.txt")
        for k in range(a.n):
            alphabet = rnd.choice(["ab", "abc", "abcd", "abcdefgh"])
            size = rnd.choice([70, 100, 250, 400, 3000, 3500])
            pats = []
            for _ in range(size):
                pats.append("".join(rnd.choice(alphabet) for _ in range(rnd.randint(1, 9))))
            if rnd.random() < 0.3:
                rnd.shuffle(pats)
            lines = ["".join(rnd.choice(alphabet + " ") for _ in range(rnd.randint(0, 60))) for _ in range(rnd.randint(1, 40))]
            with open(hay_path, "w", newline="\n") as f:
                f.write("\n".join(lines) + "\n")
            if rnd.random() < 0.7:
                with open(pats_path, "w", newline="\n") as f:
                    f.write("\n".join(pats) + "\n")
                args = ["-F", "-o", "-b", "-f", pats_path, hay_path]
            else:
                args = ["-o", "-b", "-e", "|".join(re.escape(p) for p in pats), hay_path]
            outs = []
            for exe in (a.rg, a.grepper):
                r = subprocess.run([exe, *args], capture_output=True, stdin=subprocess.DEVNULL)
                outs.append((r.returncode, r.stdout))
            if outs[0] != outs[1]:
                bad += 1
                print(f"DIFF run {k}: {size} literals over {alphabet!r}, {'-F' if '-F' in args else 'regex'}")
                g, r_ = outs[1][1].splitlines(), outs[0][1].splitlines()
                for i, (x, y) in enumerate(zip(r_, g)):
                    if x != y:
                        print(f"  line {i}: rg {x!r} grepper {y!r}")
                        break
                else:
                    print(f"  rg {len(r_)} lines, grepper {len(g)}")
    print(f"{a.n - bad}/{a.n} literal sets match rg (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
