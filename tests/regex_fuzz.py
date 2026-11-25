"""Regex semantics, grepper against ripgrep: random patterns from a small grammar searched in a
text of ASCII, Unicode (case folding traps included), CRLF lines and invalid UTF-8, comparing
`-o -n --column` (every match's position and text) and the exit code byte for byte.

    python tests/regex_fuzz.py [-n COUNT] [--seed SEED] [--grepper PATH] [--rg PATH]

A pattern ripgrep rejects is compared on stderr instead (program name aside)."""
import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

TEXT = (
    "alpha beta gamma\n"
    "Alpha BETA Gamma 42\n"
    "foo_bar baz-qux 3.14 x=y\n"
    "  leading spaces\ttab\n"
    "\n"
    "café naïve résumé Ærøskøbing\n"
    "STRASSE straße Σίσυφος σοφός ΣΟΦΌΣ\n"
    "Kelvin \u212a k K ſ s S\n"
    "日本語 テキスト 中文\n"
    "emoji 😀 x😀y\n"
    "crlf line\r\n"
    "mixed123abc456\n"
    "a\u0301 combining\n"
).encode() + b"bad \xff\xfe utf8 \xc3( here\n" + b"end"

ATOMS = list("abcxyzABCXYZ0123 _-.") + ["é", "ß", "σ", "Σ", "K", "ſ", "日"]
CLASSES = ["[a-c]", "[^a ]", "[A-Z]", "[0-9]", "[[:alpha:]]", "[\\w-]", "[é-ü]", "[^\\s]",
           "[a-z&&[^aeiou]]", "\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\pL", "\\p{Greek}",
           "\\p{Lu}", "\\PL", ".", "(?-u:\\w)", "(?-u:.)"]
LOOKS = ["^", "$", "\\b", "\\B", "\\b{start}", "\\b{end}", "\\<", "\\>",
         "\\b{start-half}", "\\b{end-half}", "\\A", "\\z",
         # the ASCII forms: Unicode is on by default, so they need (?-u) to appear
         "(?-u:\\b)", "(?-u:\\B)", "(?-u:\\b{start})", "(?-u:\\b{end})", "(?-u:\\b{start-half})",
         "(?-u:\\b{end-half})"]
QUANTS = ["*", "+", "?", "{2}", "{1,3}", "{2,}", "*?", "+?", "??", "{1,2}?"]
FLAGS = ["(?i)", "(?-i)", "(?u)", "(?-u)", "(?s)", "(?U)", "(?x)"]


def gen(r, depth=0):
    parts = []
    for _ in range(r.randint(1, 4)):
        k = r.random()
        if k < 0.40:
            a = r.choice(ATOMS)
            if a in ".-":
                a = "\\" + a
        elif k < 0.65:
            a = r.choice(CLASSES)
        elif k < 0.75:
            a = r.choice(LOOKS)
        elif k < 0.80:
            a = r.choice(FLAGS)
        elif depth < 2:
            inner = gen(r, depth + 1)
            if r.random() < 0.5:
                inner += "|" + gen(r, depth + 1)
            a = r.choice(["(", "(?:", "(?i:", "(?<n>"]) + inner + ")"
        else:
            a = r.choice(ATOMS)
        if r.random() < 0.3 and a not in LOOKS and not a.startswith("(?") or (a.startswith("(") and r.random() < 0.3):
            a += r.choice(QUANTS)
        parts.append(a)
    return "".join(parts)


OPTS = [[], ["-i"], ["-w"], ["-x"], ["-S"], ["--no-unicode"], ["-v", "-c"], ["-c"], ["--crlf"]]


def run(exe, args, path):
    try:
        r = subprocess.run([exe, "-j1", *args, path], capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
    except subprocess.TimeoutExpired:
        return None, b"TIMEOUT", b""
    return r.returncode, r.stdout, r.stderr


def main():
    # a report holds patterns and bytes the Windows console's code page cannot encode
    sys.stdout.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--grepper", default=os.path.join(here, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("-n", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    r = random.Random(a.seed)
    fd, path = tempfile.mkstemp(suffix=".txt")
    os.write(fd, TEXT)
    os.close(fd)
    bad = 0
    try:
        for i in range(a.n):
            pat = gen(r)
            opts = r.choice(OPTS)
            args = opts + ([] if "-c" in opts else ["-o", "-n", "--column"]) + ["-e", pat]
            if "-c" not in opts and r.random() < 0.3 and "--crlf" not in opts:
                # the capture groups, through -r: each group's text as the regex crate has it
                # (not with --crlf, where rg 14.1.1 turns a bare \n into \r\n: RG_BUGS U3100)
                args = opts + ["-n", "-r", "<$0|$1|$2|$3>", "-e", pat]
            g = run(a.grepper, args, path)
            rg = run(a.rg, args, path)
            if rg[0] == 2:
                same = g[0] == 2 and g[2].replace(b"grepper: ", b"rg: ") == rg[2]
            else:
                same = g[:2] == rg[:2]
            if not same:
                bad += 1
                print(f"DIFF {args!r}")
                print(f"  grepper rc={g[0]} {g[1][:300]!r} {g[2][:200]!r}")
                print(f"  rg      rc={rg[0]} {rg[1][:300]!r} {rg[2][:200]!r}")
    finally:
        os.remove(path)
    print(f"{a.n - bad}/{a.n} patterns match rg (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
