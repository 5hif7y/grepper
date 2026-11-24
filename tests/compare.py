"""grepper against ripgrep: each case runs both on the same arguments, piped (not a terminal),
and compares stdout and the exit code byte for byte.

    python tests/compare.py [--grepper PATH] [--rg PATH] [-k SUBSTRING]

The fixtures live in tests/fixtures (written by this script); the source tree itself is a
second corpus. ripgrep runs with -j1 so that its output order is deterministic."""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")

FILES = {
    "plain.txt": b"alpha beta\ngamma delta\nalpha again\n\nlast line alpha",
    "crlf.txt": b"one alpha\r\ntwo\r\nthree alpha\r\n",
    "empty.txt": b"",
    "only_newlines.txt": b"\n\n\n",
    "long.txt": b"".join(b"line %d %s\n" % (i, b"needle" if i % 97 == 0 else b"hay") for i in range(5000)),
    "utf8.txt": "café ü naïve\nnothing\nCAFÉ\n".encode(),
    "binary.bin": b"text with alpha\x00\x01\x02 more alpha\n",
}

# a tree for the recursive cases: a git repository with nested ignore files, hidden entries and
# a binary file (written under tests/fixtures/tree)
TREE = {
    ".git/config": b"[core] alpha = 1\n",
    ".git/HEAD": b"ref: refs/heads/main\n",
    ".gitignore": b"*.log\nbuild/\n/rootonly.txt\n!keep.log\ndocs/**/draft*\n",
    ".ignore": b"secret.txt\n",
    "a.txt": b"alpha in a\n",
    "keep.log": b"alpha kept\n",
    "drop.log": b"alpha dropped\n",
    "rootonly.txt": b"alpha root only\n",
    "secret.txt": b"alpha secret\n",
    ".hidden.txt": b"alpha hidden\n",
    ".hiddendir/x.txt": b"alpha in hidden dir\n",
    "build/out.txt": b"alpha built\n",
    "src/rootonly.txt": b"alpha not root\n",
    "src/main.c": b"int alpha;\nint beta;\n",
    "src/.gitignore": b"*.tmp\n",
    "src/x.tmp": b"alpha tmp\n",
    "src/deep/er/file.txt": b"alpha deep\n",
    "docs/a/b/draft1.md": b"alpha draft\n",
    "docs/a/final.md": b"alpha final\n",
    "bin.dat": b"alpha\x00binary\n",
    # a NUL past ripgrep's first 64 KiB fill: the lines before it are printed, then a warning
    "late_nul.txt": b"alpha line\n" * 7000 + b"\x00alpha after\n",
}

CASES = [
    # (name, args); paths are relative to tests/fixtures
    ("literal", ["-F", "alpha", "plain.txt"]),
    ("literal -n", ["-F", "-n", "alpha", "plain.txt"]),
    ("literal last line no newline", ["-F", "-n", "last", "plain.txt"]),
    ("count", ["-F", "-c", "alpha", "plain.txt"]),
    ("count several files", ["-F", "-c", "alpha", "plain.txt", "crlf.txt", "empty.txt"]),
    ("files with matches", ["-F", "-l", "alpha", "plain.txt", "crlf.txt", "empty.txt"]),
    ("with filename", ["-F", "-H", "-n", "alpha", "plain.txt"]),
    ("no filename", ["-F", "-I", "alpha", "plain.txt", "crlf.txt"]),
    ("several files", ["-F", "-n", "alpha", "plain.txt", "crlf.txt"]),
    ("crlf", ["-F", "-n", "alpha", "crlf.txt"]),
    ("no match", ["-F", "zzz", "plain.txt"]),
    ("empty file", ["-F", "alpha", "empty.txt"]),
    ("many lines", ["-F", "-n", "needle", "long.txt"]),
    ("many lines count", ["-F", "-c", "needle", "long.txt"]),
    ("two patterns", ["-F", "-n", "-e", "gamma", "-e", "again", "plain.txt"]),
    ("eight patterns", ["-F", "-n"] + sum([["-e", w] for w in ("alpha", "beta", "gamma", "delta", "again", "last", "line", "zzz")], []) + ["plain.txt"]),
    ("utf8 literal", ["-F", "-n", "café", "utf8.txt"]),
    ("missing file", ["-F", "alpha", "plain.txt", "does_not_exist.txt"]),
    ("binary explicit", ["-F", "-n", "alpha", "binary.bin"]),
    ("binary explicit -c", ["-F", "-c", "alpha", "binary.bin"]),
    ("binary explicit -l", ["-F", "-l", "alpha", "binary.bin"]),
    ("binary explicit no match", ["-F", "zzz", "binary.bin"]),
    ("binary explicit with others", ["-F", "alpha", "binary.bin", "plain.txt"]),
    ("binary explicit heading", ["-F", "--heading", "alpha", "binary.bin", "plain.txt"]),
    # the regex engine (interim: Odin's core:text/regex); -i is ASCII-only for now, so the
    # cases keep to ASCII letters
    ("regex dot", ["-n", "alp.a", "plain.txt"]),
    ("regex anchors start", ["-n", "^alpha", "plain.txt"]),
    ("regex anchors end", ["-n", "alpha$", "plain.txt"]),
    ("regex anchors end crlf", ["-n", "alpha$", "crlf.txt"]),
    ("regex whole line", ["-n", "^$", "plain.txt"]),
    ("regex class", ["-n", "[gl]a", "plain.txt"]),
    ("regex negated class", ["-c", "line [0-9]+ [^h]", "long.txt"]),
    ("regex alternation", ["-n", "gamma|again", "plain.txt"]),
    ("regex group", ["-n", "(al|ga)(pha|mma)", "plain.txt"]),
    ("regex quantifiers", ["-c", "line 1[0-9]{2} ", "long.txt"]),
    ("regex optional", ["-n", "alphas?", "plain.txt"]),
    ("regex word boundary", ["-n", "\\bline\\b", "plain.txt"]),
    ("regex digits", ["-c", "\\d\\d\\d9 ", "long.txt"]),
    ("regex no literal", ["-n", "[a-c]+[ ]+[a-d]", "plain.txt"]),
    ("regex ignore case", ["-n", "-i", "ALPHA", "plain.txt"]),
    ("fixed ignore case", ["-n", "-i", "-F", "AlPhA", "plain.txt"]),
    ("regex several -e", ["-n", "-e", "gam+a", "-e", "^last"]  + ["plain.txt"]),
    ("regex count", ["-c", "needle$", "long.txt"]),
    ("regex files", ["-l", "a.p", "plain.txt", "crlf.txt", "empty.txt"]),
    ("regex no match", ["zz+q", "plain.txt"]),
    ("regex utf8", ["-n", "caf.", "utf8.txt"]),
    # the printer with colours and headings, byte for byte (the path colour is per platform)
    ("color lines", ["--color", "always", "-n", "alpha", "plain.txt"]),
    ("color heading", ["--color", "always", "--heading", "-n", "alpha", "plain.txt", "crlf.txt"]),
    ("color count", ["--color", "always", "-c", "alpha", "plain.txt", "crlf.txt"]),
    ("color files", ["--color", "always", "-l", "alpha", "plain.txt", "crlf.txt"]),
    ("color with filename", ["--color", "always", "-n", "-H", "al.ha", "plain.txt"]),
    ("color several matches", ["--color", "always", "-e", "alpha", "-e", "beta", "plain.txt"]),
    ("color binary", ["--color", "always", "alpha", "binary.bin", "plain.txt"]),
    ("heading no color", ["--heading", "-n", "alpha", "plain.txt", "crlf.txt"]),
]

# recursive cases, run in tests/fixtures/tree; their lines are compared sorted (the walk order
# is not part of ripgrep's contract)
TREE_CASES = [
    ("walk default", ["-F", "alpha"]),
    ("walk dot", ["-F", "alpha", "."]),
    ("walk -n", ["-F", "-n", "alpha"]),
    ("walk -l", ["-F", "-l", "alpha"]),
    ("walk -c", ["-F", "-c", "alpha"]),
    ("walk --hidden", ["-F", "-l", "--hidden", "alpha"]),
    ("walk --no-ignore", ["-F", "-l", "--no-ignore", "alpha"]),
    ("walk --hidden --no-ignore", ["-F", "-l", "--hidden", "--no-ignore", "alpha"]),
    ("walk subdir", ["-F", "-l", "alpha", "src"]),
    ("walk explicit ignored file", ["-F", "alpha", "drop.log"]),
    ("walk two roots", ["-F", "-l", "alpha", "src", "docs"]),
    ("walk regex", ["-n", "^int [a-z]+;$"]),
    ("walk regex -l", ["-l", "al.ha (in|kept)"]),
]


def write_fixtures():
    os.makedirs(FIX, exist_ok=True)
    for name, data in FILES.items():
        with open(os.path.join(FIX, name), "wb") as f:
            f.write(data)
    tree = os.path.join(FIX, "tree")
    shutil.rmtree(tree, ignore_errors=True)
    for name, data in TREE.items():
        path = os.path.join(tree, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)


def run(exe, args, extra=(), cwd=FIX):
    # stdin closed: with no path and a readable stdin, rg would search stdin instead
    r = subprocess.run([exe, *extra, *args], cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg", default=shutil.which("rg"))
    ap.add_argument("-k", default="")
    a = ap.parse_args()
    if not a.rg:
        print("no rg found", file=sys.stderr)
        return 2
    write_fixtures()
    bad = 0
    tree = os.path.join(FIX, "tree")
    cases = [(n, c, FIX, False) for n, c in CASES] + [(n, c, tree, True) for n, c in TREE_CASES]
    for name, args, cwd, sort in cases:
        if a.k not in name:
            continue
        g = run(a.grepper, args, ["-j1"], cwd)
        r = run(a.rg, args, ["-j1"], cwd)
        if sort:
            g = g[0], b"".join(sorted(g[1].splitlines(True)))
            r = r[0], b"".join(sorted(r[1].splitlines(True)))
        if g != r:
            bad += 1
            print(f"DIFF {name}: {args}")
            print(f"  grepper rc={g[0]} {g[1][:400]!r}")
            print(f"  rg      rc={r[0]} {r[1][:400]!r}")
    total = sum(1 for n, *_ in cases if a.k in n)
    print(f"{total - bad}/{total} cases match rg")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
