#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""-U against ripgrep on random files.

Random small files (LF and CRLF lines) searched with -U, a pattern from a list of multi line
and single line regexes, and one set of flags; stdout, exit code and stderr must equal rg
14.1.1's. Two flags are left out, where grepper takes ripgrep's later fixes (RG_BUGS in
compare.py): --json, which rg 14.1.1 writes as one message per multi line block (U1983) and
whose summary leaves out searches without a match (U3178); and -m, which grepper counts in
matches, as rg 16.0.0 does, and rg 14.1.1 in blocks of touching matches (U3076).

usage: python tests/multiline_fuzz.py [--seed N] [-n N] [--grepper PATH] [--rg PATH]
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

PATS = ["foo\\nbar", "a\\n", "\\nb", "(?s)a.*?c", "a[^x]*b", "^b", "c$", "(?m)^a$", "foo", "x*", "\\n\\n",
        "o\\s+b", "[ab]\\n[bc]", "bar\\n?", "(?s).{3}", "\\w+\\n\\w+", "a|\\nc", "$", "^"]
OPTS = [[], ["-n"], ["-c"], ["--count-matches"], ["-o"], ["-o", "-n", "--column"], ["-v"], ["-n", "-A1"],
        ["-n", "-B1"], ["-C1", "-n"], ["-l"], ["-b", "-n"], ["--vimgrep"], ["-m1"], ["-m2", "-n"],
        ["--passthru"], ["--json"], ["-r", "<$0>"], ["--color", "always"], ["--multiline-dotall"],
        ["--stats"], ["-v", "-n", "-C1"], ["--no-mmap", "-n"], ["--crlf"], ["-w"], ["-x"], ["-M", "5"]]
WORDS = ["a", "b", "c", "foo", "bar", "foo bar", "xa", "", "a b c"]


def norm(out):
    out = re.sub(rb'"secs":\d+', b"", out)
    out = re.sub(rb'"nanos":\d+', b"", out)
    out = re.sub(rb'"human":"[0-9.]+s"', b"", out)
    return re.sub(rb"\d+\.\d{6} seconds", b"", out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-n", type=int, default=400)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "m.txt")
        for _ in range(a.n):
            lines = [rnd.choice(WORDS) for _ in range(rnd.randint(1, 10))]
            eol = rnd.choice(["\n", "\n", "\r\n"])
            data = (eol.join(lines) + (eol if rnd.random() < 0.8 else "")).encode()
            with open(path, "wb") as f:
                f.write(data)
            pat = rnd.choice(PATS)
            opts = rnd.choice(OPTS)
            args = ["-U", *opts, "-e", pat, path]
            outs = []
            for exe in (a.rg, a.grepper):
                r = subprocess.run([exe, *args], capture_output=True, stdin=subprocess.DEVNULL)
                outs.append((r.returncode, norm(r.stdout), r.stderr.replace(b"grepper:", b"rg:")))
            if "--json" in opts:
                # grepper splits a multi line block into one message per run of lines (rg
                # 16.0.0's fix, RG_BUGS U1983) and counts searches without a match (U3178)
                continue
            if any(o.startswith("-m") for o in opts):
                # -U -m counts matches in grepper, blocks in rg 14.1.1 (RG_BUGS U3076)
                continue
            if outs[0] != outs[1]:
                bad += 1
                print(f"DIFF {opts} {pat!r} on {data!r}")
                print(f"  rg      {outs[0]!r:.400}")
                print(f"  grepper {outs[1]!r:.400}")
    print(f"{a.n - bad}/{a.n} searches match rg (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
