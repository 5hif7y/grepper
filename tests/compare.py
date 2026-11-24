"""grepper against ripgrep: each case runs both on the same arguments, piped (not a terminal),
and compares stdout and the exit code byte for byte.

    python tests/compare.py [--grepper PATH] [--rg PATH] [-k SUBSTRING]

The fixtures live in tests/fixtures (written by this script); the source tree itself is a
second corpus. ripgrep runs with -j1 so that its output order is deterministic."""
import argparse
import os
import re
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
    "hash.txt": b"#include <a.h>\nx #include y\n  #inc\nno hash\n",
    # context: matches at lines 3, 5, 12 and 20 of 24
    "ctx.txt": b"".join(b"%s %d\n" % (b"hit" if i in (3, 5, 12, 20) else b"line", i) for i in range(1, 25)),
    "ws.txt": b"  \t lead alpha\n\tx alpha y alpha\nalpha\n",
    "pats.txt": b"gamma\r\nlast\n\nzzz",
    "esc.txt": b"tab\there\nquote\"d\nctl\x01x\x7f\n",
    # a NUL past the first 64 KiB of a file given on the command line: read through the line
    # buffer (more than 10 paths) the lines before it print, then "binary file matches"
    "late_nul_explicit.txt": b"alpha line\n" * 7000 + b"\x00alpha after\n",
}

# a tree for the recursive cases: a git repository with nested ignore files, hidden entries and
# a binary file (written under tests/fixtures/tree)
TREE = {
    ".git/config": b"[core] alpha = 1\n",
    ".git/HEAD": b"ref: refs/heads/main\n",
    ".gitignore": b"*.log\nbuild/\n/rootonly.txt\n!keep.log\ndocs/**/draft*\n",
    ".ignore": b"secret.txt\n!/.visible/\n",
    ".visible/y.txt": b"alpha in a whitelisted hidden dir\n",
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
    ("regex hash", ["-n", "^#inc", "hash.txt"]),
    ("regex hash in class", ["-n", "[#]inc", "hash.txt"]),
    ("regex hash escaped", ["-n", "\\#inc", "hash.txt"]),
    # the printer with colours and headings, byte for byte (the path colour is per platform)
    ("color lines", ["--color", "always", "-n", "alpha", "plain.txt"]),
    ("color heading", ["--color", "always", "--heading", "-n", "alpha", "plain.txt", "crlf.txt"]),
    ("color count", ["--color", "always", "-c", "alpha", "plain.txt", "crlf.txt"]),
    ("color files", ["--color", "always", "-l", "alpha", "plain.txt", "crlf.txt"]),
    ("color with filename", ["--color", "always", "-n", "-H", "al.ha", "plain.txt"]),
    ("color several matches", ["--color", "always", "-e", "alpha", "-e", "beta", "plain.txt"]),
    ("color binary", ["--color", "always", "alpha", "binary.bin", "plain.txt"]),
    ("heading no color", ["--heading", "-n", "alpha", "plain.txt", "crlf.txt"]),
    # context lines and their separators
    ("after context", ["-n", "-A", "1", "hit", "ctx.txt"]),
    ("before context", ["-n", "-B", "2", "hit", "ctx.txt"]),
    ("context both", ["-n", "-C", "1", "hit", "ctx.txt"]),
    ("context overlap", ["-n", "-C", "3", "hit", "ctx.txt"]),
    ("context A beats C", ["-n", "-C", "3", "-A", "0", "hit", "ctx.txt"]),
    ("context several files", ["-n", "-C", "1", "hit", "ctx.txt", "plain.txt", "ctx.txt"]),
    ("context heading", ["--heading", "-n", "-C", "1", "-e", "hit", "-e", "alpha", "ctx.txt", "plain.txt"]),
    ("context separator", ["-n", "-C", "1", "--context-separator", "~~\\t", "hit", "ctx.txt"]),
    ("no context separator", ["-n", "-C", "1", "--no-context-separator", "hit", "ctx.txt"]),
    ("field separators", ["-n", "-H", "-C", "1", "--field-match-separator", "=>", "--field-context-separator", "..", "hit", "ctx.txt"]),
    ("context color", ["--color", "always", "-n", "-C", "1", "hit", "ctx.txt", "plain.txt"]),
    # invert, max count, passthru
    ("invert", ["-n", "-v", "hit", "ctx.txt"]),
    ("invert count", ["-c", "-v", "alpha", "plain.txt"]),
    ("invert context", ["-n", "-v", "-C", "1", "line", "ctx.txt"]),
    ("invert color", ["--color", "always", "-v", "beta", "plain.txt"]),
    ("max count", ["-n", "-m", "2", "hit", "ctx.txt"]),
    ("max count zero", ["-m", "0", "hit", "ctx.txt"]),
    ("max count context", ["-n", "-m", "2", "-A", "3", "hit", "ctx.txt"]),
    ("max count count", ["-c", "-m", "3", "hit", "ctx.txt"]),
    ("max count -l", ["-l", "-m", "1", "hit", "ctx.txt"]),
    ("passthru", ["-n", "--passthru", "hit", "ctx.txt"]),
    ("passthru color", ["--color", "always", "--passthru", "beta", "plain.txt"]),
    ("passthru then -A", ["-n", "--passthru", "-A", "1", "hit", "ctx.txt"]),
    ("stop on nonmatch", ["-n", "--stop-on-nonmatch", "line", "ctx.txt"]),
    # quiet and the summary modes
    ("quiet match", ["-q", "alpha", "plain.txt"]),
    ("quiet no match", ["-q", "zzz", "plain.txt"]),
    ("count matches", ["--count-matches", "alpha", "ws.txt", "plain.txt"]),
    ("only matching count", ["-o", "-c", "alpha", "ws.txt"]),
    ("invert count matches", ["-v", "--count-matches", "alpha", "ws.txt"]),
    ("files without match", ["--files-without-match", "beta", "plain.txt", "crlf.txt", "empty.txt"]),
    ("include zero", ["-c", "--include-zero", "beta", "plain.txt", "crlf.txt"]),
    ("null after path", ["-0", "-l", "alpha", "plain.txt", "crlf.txt"]),
    ("null after path lines", ["-0", "-H", "-n", "beta", "plain.txt"]),
    ("null with count", ["-0", "-c", "alpha", "plain.txt", "crlf.txt"]),
    # prelude fields
    ("byte offset", ["-b", "alpha", "plain.txt"]),
    ("byte offset -n", ["-b", "-n", "-H", "alpha", "plain.txt"]),
    ("column", ["--column", "alpha", "ws.txt"]),
    ("no column", ["--column", "--no-column", "-n", "alpha", "ws.txt"]),
    ("only matching", ["-o", "-n", "alpha", "ws.txt"]),
    ("only matching -b", ["-o", "-b", "alpha", "ws.txt"]),
    ("only matching color", ["--color", "always", "-o", "a.p", "ws.txt"]),
    ("vimgrep", ["--vimgrep", "alpha", "ws.txt"]),
    ("vimgrep heading", ["--vimgrep", "--heading", "alpha", "ws.txt", "plain.txt"]),
    ("trim", ["--trim", "-n", "alpha", "ws.txt"]),
    ("trim color", ["--color", "always", "--trim", "alpha", "ws.txt"]),
    ("max columns", ["-M", "12", "alpha", "ws.txt", "plain.txt"]),
    ("max columns only matching", ["-M", "3", "-o", "alpha", "ws.txt"]),
    ("max columns color", ["--color", "always", "-M", "12", "alpha", "ws.txt"]),
    ("path separator", ["-H", "--path-separator", "#", "alpha", "plain.txt"]),
    ("colors", ["--color", "always", "--colors", "match:fg:blue", "--colors", "match:style:nobold", "--colors", "line:none", "--colors", "path:bg:0x10", "--colors", "column:fg:200,1,0", "-n", "--column", "-H", "alpha", "plain.txt"]),
    ("colors intense underline", ["--color", "always", "--colors", "match:style:intense", "--colors", "match:style:underline", "--colors", "path:fg:yellow", "--colors", "path:style:intense", "-H", "alpha", "plain.txt"]),
    ("pretty", ["-p", "alpha", "plain.txt"]),
    ("ansi", ["--color", "ansi", "alpha", "plain.txt"]),
    # patterns
    ("patterns from file", ["-n", "-f", "pats.txt", "plain.txt"]),
    ("patterns from file and -e", ["-n", "-f", "pats.txt", "-e", "beta", "plain.txt"]),
    ("duplicate patterns", ["-c", "-e", "alpha", "-e", "alpha", "plain.txt"]),
    ("dash dash", ["-n", "--", "-x", "plain.txt"]),
    ("equals value", ["-n", "--regexp=gamma", "--max-count=1", "plain.txt"]),
    # explicit binary through the line buffer (more than 10 paths: no memory map) and whole
    ("explicit late nul, read", ["-c", "alpha", "late_nul_explicit.txt"] + ["empty.txt"] * 10),
    ("explicit late nul, read lines", ["after", "late_nul_explicit.txt"] + ["empty.txt"] * 10),
    ("explicit late nul, mmap", ["-n", "after", "late_nul_explicit.txt"]),
    ("explicit late nul, no mmap", ["--no-mmap", "-n", "after", "late_nul_explicit.txt"]),
    ("binary as text", ["-a", "-c", "alpha", "binary.bin"]),
    ("binary flag", ["--binary", "-n", "alpha", "binary.bin"]),
    # JSON Lines and statistics (timings normalized)
    ("json", ["--json", "alpha", "plain.txt", "crlf.txt"]),
    ("json context", ["--json", "-C", "1", "hit", "ctx.txt"]),
    ("json invert context", ["--json", "-v", "-C", "1", "line", "ctx.txt"]),
    ("json non utf8", ["--json", "-a", "alpha", "binary.bin", "utf8.txt"]),
    ("json binary", ["--json", "alpha", "binary.bin"]),
    ("json max count", ["--json", "-m", "1", "alpha", "plain.txt"]),
    # the control bytes themselves: the interim regex engine has no \x escapes
    ("json escapes", ["--json", "-a", "\x01|\t|\"", "esc.txt"]),
    ("json no match", ["--json", "zzz", "plain.txt"]),
    ("json quiet", ["--json", "-q", "alpha", "plain.txt"]),
    ("stats", ["--stats", "alpha", "plain.txt", "crlf.txt"]),
    ("stats count", ["--stats", "-c", "alpha", "plain.txt", "crlf.txt"]),
    ("stats quiet", ["--stats", "-q", "alpha", "plain.txt"]),
]

# cases with a RIPGREP_CONFIG_PATH file: (name, args, config text)
CONFIG_CASES = [
    ("config", ["alpha", "plain.txt"], b"# a comment\n\n  -n  \n--context=1\n"),
    ("config then flags", ["-N", "alpha", "plain.txt"], b"-n\n"),
    ("no config", ["--no-config", "alpha", "plain.txt"], b"-n\n"),
]

# cases fed through stdin: (name, args, stdin bytes)
STDIN_CASES = [
    ("stdin implicit", ["-n", "alpha"], b"x\nalpha one\ny alpha\n"),
    ("stdin dash", ["-H", "alpha", "-"], b"alpha\n"),
    ("stdin and file", ["alpha", "-", "plain.txt"], b"alpha from stdin\n"),
    ("stdin count", ["-c", "a"], b"a\nb\na\n"),
    ("stdin binary", ["alpha"], b"alpha\x00\nalpha\n"),
    ("stdin patterns", ["-f", "-", "plain.txt"], b"beta\nagain\n"),
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
    ("walk context heading", ["-C", "1", "alpha"]),
    ("walk no ignore vcs", ["-l", "--no-ignore-vcs", "alpha"]),
    ("walk no ignore dot", ["-l", "--no-ignore-dot", "alpha"]),
    ("walk no ignore exclude", ["-l", "--no-ignore-exclude", "alpha"]),
    ("walk ignore after no ignore", ["-l", "--no-ignore", "--ignore", "alpha"]),
    ("walk -u", ["-l", "-u", "alpha"]),
    ("walk -uu", ["-l", "-uu", "alpha"]),
    ("walk -uuu", ["-c", "-uuu", "alpha"]),
    ("walk files", ["--files"]),
    ("walk files hidden", ["--files", "--hidden"]),
    ("walk files null", ["--files", "-0"]),
    ("walk files without match", ["--files-without-match", "alpha"]),
    ("walk quiet", ["-q", "alpha"]),
    ("walk count matches", ["--count-matches", "alpha"]),
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


ENV = {k: v for k, v in os.environ.items() if k != "RIPGREP_CONFIG_PATH"}


def normalize(out):
    """Timings are the only bytes allowed to differ: --stats and --json's elapsed fields."""
    out = re.sub(rb'"secs":\d+', b'"secs":0', out)
    out = re.sub(rb'"nanos":\d+', b'"nanos":0', out)
    out = re.sub(rb'"human":"[0-9.]+s"', b'"human":"0s"', out)
    return re.sub(rb"\d+\.\d{6} seconds", b"0.000000 seconds", out)


def run(exe, args, extra=(), cwd=FIX, stdin=None, env=None):
    # stdin closed unless the case feeds it: with no path and a readable stdin, rg would
    # search stdin instead
    if stdin is None:
        r = subprocess.run([exe, *extra, *args], cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, env=env or ENV)
    else:
        r = subprocess.run([exe, *extra, *args], cwd=cwd, capture_output=True, input=stdin, env=env or ENV)
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
    cases = [(n, c, FIX, False, None) for n, c in CASES] + [(n, c, tree, True, None) for n, c in TREE_CASES]
    cases = [(n, c, cwd, sort, stdin, None) for n, c, cwd, sort, stdin in cases]
    cases += [(n, c, FIX, False, i, None) for n, c, i in STDIN_CASES]
    cases += [(n, c, FIX, False, None, cfg) for n, c, cfg in CONFIG_CASES]
    for name, args, cwd, sort, stdin, cfg in cases:
        if a.k not in name:
            continue
        env = None
        if cfg is not None:
            path = os.path.join(FIX, "rgconfig")
            with open(path, "wb") as f:
                f.write(cfg)
            env = dict(ENV, RIPGREP_CONFIG_PATH=path)
        g = run(a.grepper, args, ["-j1"], cwd, stdin, env)
        r = run(a.rg, args, ["-j1"], cwd, stdin, env)
        g, r = (g[0], normalize(g[1])), (r[0], normalize(r[1]))
        if sort:
            g = g[0], b"".join(sorted(g[1].splitlines(True)))
            r = r[0], b"".join(sorted(r[1].splitlines(True)))
        if r[0] == 2:
            # an error on both sides would compare equal while testing nothing
            print(f"NOTE {name}: rg exited 2")
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
