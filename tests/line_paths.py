#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""The searcher's two line paths must agree.

A regex with a haystack anchor (\\A, \\z) is searched line by line (the slow path); the same
question asked with line anchors (^, $) runs over many lines at once (the fast path). In line
mode both mean the same, so grepper must print the same bytes and exit with the same code for
both, whatever the context, -m and -v flags. ripgrep 14.1.1 holds this too; 16.0.0 does not
(docs/PARITY.md section 6, R16-1 and R16-2).

usage: python tests/line_paths.py [--seed N] [--count N] [--grepper PATH]
"""
import argparse
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PAIRS = [("\\Afoo", "^foo"), ("foo\\z", "foo$"), ("\\Afoo\\z", "^foo$"), ("\\A(?:foo|b)", "^(?:foo|b)")]
WORDS = ["a", "b", "foo", "c", "foox", "xfoo", ""]


def main():
    # a report holds patterns and bytes the Windows console's code page cannot encode
    sys.stdout.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=300)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "h.txt")
        for _ in range(a.count):
            lines = [rnd.choice(WORDS) for _ in range(rnd.randint(1, 14))]
            eol = rnd.choice(["\n", "\n", "\r\n"])
            data = (eol.join(lines) + (eol if rnd.random() < 0.8 else "")).encode()
            with open(path, "wb") as f:
                f.write(data)
            slow, fast = rnd.choice(PAIRS)
            args = ["-n"]
            if rnd.random() < 0.7:
                args.append("-v")
            if rnd.random() < 0.8:
                args += ["-m", str(rnd.randint(1, 3))]
            args += ["-A", str(rnd.randint(0, 3))]
            if rnd.random() < 0.4:
                args += ["-B", str(rnd.randint(1, 2))]
            if rnd.random() < 0.2:
                args.append("-c")
            if rnd.random() < 0.3:
                args.append("--no-mmap")
            if eol == "\r\n" and rnd.random() < 0.5:
                args.append("--crlf")
            outs = []
            for pat in (slow, fast):
                r = subprocess.run([a.grepper, *args, pat, path], capture_output=True, stdin=subprocess.DEVNULL)
                outs.append((r.returncode, r.stdout, r.stderr))
            if outs[0][:2] != outs[1][:2] or outs[0][0] > 1:
                bad += 1
                print(f"DIFF {args} {slow!r} vs {fast!r} on {data!r}")
                print(f"  slow rc={outs[0][0]} {outs[0][1]!r} {outs[0][2][:200]!r}")
                print(f"  fast rc={outs[1][0]} {outs[1][1]!r}")
    print(f"{a.count - bad}/{a.count} pairs agree (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
