#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""The parallel walk under stress: many runs at several thread counts over one tree.

Each run must finish within the timeout and print what -j1 prints (lines compared sorted:
the parallel order is not fixed). A run past the timeout is a hang: on Linux, when gdb is
installed, every thread's stack is dumped before the process is killed, so the hang leaves
evidence (PARITY P9: one Windows run in 30 passed a 30 s timeout once, and never again in 660).

usage: python tests/stress_walk.py ROOT [-n RUNS] [-j 2,4,8] [--timeout S] [--grepper PATH]
           [-- ARGS...]      (the search; default: -c -F return)
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def run(exe, args, cwd, timeout):
    p = subprocess.Popen([exe, *args], cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err, None
    except subprocess.TimeoutExpired:
        dump = None
        if sys.platform.startswith("linux") and shutil.which("gdb"):
            g = subprocess.run(["gdb", "-batch", "-p", str(p.pid), "-ex", "thread apply all bt"],
                               capture_output=True, text=True)
            dump = g.stdout + g.stderr
        p.kill()
        p.communicate()
        return None, b"", b"", dump or "(no thread dump: gdb is Linux only, or not installed)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("-n", type=int, default=100, help="runs per thread count")
    ap.add_argument("-j", default="2,4,8", help="thread counts, comma separated")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    search = a.args or ["-c", "-F", "return"]
    rc, ref, _, hang = run(a.grepper, ["-j1", *search], a.root, a.timeout * 4)
    if hang:
        print(f"-j1 reference hung: {hang}")
        return 1
    ref = sorted(ref.splitlines())
    bad = 0
    for j in [int(x) for x in a.j.split(",")]:
        hangs = diffs = 0
        worst = 0.0
        for k in range(a.n):
            t = time.perf_counter()
            code, out, err, dump = run(a.grepper, [f"-j{j}", *search], a.root, a.timeout)
            worst = max(worst, time.perf_counter() - t)
            if dump is not None:
                hangs += 1
                print(f"HANG -j{j} run {k + 1}: past {a.timeout:.0f} s\n{dump}")
            elif code != rc or sorted(out.splitlines()) != ref:
                diffs += 1
                print(f"DIFF -j{j} run {k + 1}: rc {code}/{rc}, {len(out.splitlines())}/{len(ref)} lines")
        bad += hangs + diffs
        print(f"-j{j}: {a.n} runs, {hangs} hangs, {diffs} differences, slowest {worst:.2f} s")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
