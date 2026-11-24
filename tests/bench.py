"""Wall time of grepper against ripgrep on the same searches over a directory tree: the best of
R runs each, both with their default thread count, after checking that their sorted outputs are
identical (a search that differs is reported and not timed).

    python tests/bench.py CORPUS [--grepper PATH] [--rg PATH] [-r RUNS]

Run it on an idle machine: other load changes wall time more than these differences."""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SEARCHES = [
    ("literal, common", ["-F", "return"]),
    ("literal, rare", ["-F", "zq_never_here_7"]),
    ("literal, -c", ["-F", "-c", "include"]),
    ("literal, -l", ["-F", "-l", "memchr"]),
    ("8 literals (Teddy)", ["-F", "-e", "alpha", "-e", "omega", "-e", "Sherlock", "-e", "Teddy", "-e", "needle", "-e", "simdjson", "-e", "PCLMUL", "-e", "zebra"]),
    ("regex with a literal", ["fn [a-z_]+\\("]),
    ("regex, no literal", ["[A-Z][a-z]+Error"]),
    ("regex, anchored", ["^#include"]),
    ("-i literal (regex path)", ["-i", "sherlock"]),
]


def run(exe, args, cwd):
    t = time.perf_counter()
    r = subprocess.run([exe, *args], cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL)
    return time.perf_counter() - t, r.returncode, r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("-r", type=int, default=7)
    a = ap.parse_args()
    print(f"{'search':26s} {'lines':>8s} {'grepper ms':>11s} {'rg ms':>8s} {'ratio':>6s}")
    for name, args in SEARCHES:
        _, gc, go = run(a.grepper, args, a.corpus)
        _, rc, ro = run(a.rg, args, a.corpus)
        if gc != rc or sorted(go.splitlines()) != sorted(ro.splitlines()):
            print(f"{name:26s} DIFFERENT output (rc {gc}/{rc}, lines {len(go.splitlines())}/{len(ro.splitlines())})")
            continue
        g = min(run(a.grepper, args, a.corpus)[0] for _ in range(a.r))
        r = min(run(a.rg, args, a.corpus)[0] for _ in range(a.r))
        print(f"{name:26s} {len(ro.splitlines()):8d} {g * 1000:11.0f} {r * 1000:8.0f} {g / r:6.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
