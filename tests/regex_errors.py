"""Regex parse errors: grepper's message against ripgrep's, byte for byte (program name aside).

    python tests/regex_errors.py [--grepper PATH] [--rg PATH]

Each pattern is searched for in an empty file, with a timeout, so that a pattern the interim
engine mishandles cannot hang the run."""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

PATTERNS = [
    "(?:a", "a{2,1}", "(?ii)x", "\\p{", "[a", "a)", "(?<n>a)(?<n>b)", "*a", "a{", "\\xZZ",
    "\\8", "a\nb(", "(?=x)", "\\b{foo}", "x{99999999999}", "[z-a]", "(?-)", "\\u{110000}",
    "(?P<1a>x)", "(?<>x)", "(?<n", "(?--i)", "(?i-)", "(?z)", "(?", "a{1", "a{1,", "a{,5}",
    "\\", "\\q", "\\x{}", "\\x{zz}", "[\\d-z]", "[a-\\w]", "\\b{start", "[[:alpha:]",
    "(", ")", "a||b(", "\\pN", "\\P{", "\\p\\", "[]", "[^]", "\\u{D800}", "\\x{ 41 }",
    "a\n\nb)\nc", "(?x)a #b\n(", "\\cA", "\\K", "(?<=a)b", "(?!a)", "(?i)(?i)",
]


def run(exe, pattern, path):
    try:
        r = subprocess.run([exe, "-e", pattern, path], capture_output=True, stdin=subprocess.DEVNULL, timeout=20)
    except subprocess.TimeoutExpired:
        return None, b"TIMEOUT"
    return r.returncode, r.stderr


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--grepper", default=os.path.join(here, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    a = ap.parse_args()
    fd, path = tempfile.mkstemp()
    os.close(fd)
    bad = 0
    try:
        for p in PATTERNS:
            g = run(a.grepper, p, path)
            r = run(a.rg, p, path)
            g = (g[0], g[1].replace(b"grepper: ", b"rg: "))
            if g != r:
                bad += 1
                print(f"DIFF {p!r}")
                print(f"  grepper rc={g[0]} {g[1]!r}")
                print(f"  rg      rc={r[0]} {r[1]!r}")
    finally:
        os.remove(path)
    print(f"{len(PATTERNS) - bad}/{len(PATTERNS)} patterns match rg")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
