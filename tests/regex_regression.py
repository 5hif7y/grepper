#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""regex's own regression tests for the reverse suffix and reverse inner strategies.

tests/data/regex_reverse_regressions.toml holds the tests of regex 1.13.1's
testdata/regression.toml for those strategies (rust-lang/regex#1354 among them). Each regex
is searched in its haystack with --json, in line mode and with -U; the match spans must be
the test's. ripgrep 14.1.1 is run too, for information only: its reverse strategies predate
the fix, so it fails some of them.

usage: python tests/regex_regression.py [--grepper PATH] [--rg PATH]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def spans(exe, args, path):
    r = subprocess.run([exe, "--json", *args, path], capture_output=True, stdin=subprocess.DEVNULL)
    out = []
    for line in r.stdout.splitlines():
        msg = json.loads(line)
        if msg["type"] != "match":
            continue
        base = msg["data"]["absolute_offset"]
        for sm in msg["data"]["submatches"]:
            out.append([base + sm["start"], base + sm["end"]])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    a = ap.parse_args()
    with open(os.path.join(HERE, "data", "regex_reverse_regressions.toml"), "rb") as f:
        tests = tomllib.load(f)["test"]
    bad, total, rg_bad = 0, 0, 0
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "h.txt")
        for t in tests:
            with open(path, "wb") as f:
                f.write(t["haystack"].encode())
            # a test that lists capture groups gives each match as its groups' spans: the
            # match is group 0
            want = [list(m[0]) if m and isinstance(m[0], list) else list(m) for m in t["matches"]]
            modes = [[], ["-U"]] if "\n" not in t["haystack"] else [["-U"]]
            for mode in modes:
                total += 1
                args = [*mode, "-e", t["regex"]]
                got = spans(a.grepper, args, path)
                if got != want:
                    bad += 1
                    print(f"FAIL {t['name']} {mode}: {t['regex']!r} on {t['haystack']!r}: {got}, want {want}")
                if a.rg and spans(a.rg, args, path) != want:
                    rg_bad += 1
    print(f"{total - bad}/{total} regex regression searches right (rg: {total - rg_bad}/{total})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
