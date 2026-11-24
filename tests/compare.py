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
    "words.txt": "alpha alphabet alpha_x xalpha\nALPHA Alpha\nnaïve café Σοφός σοφός\nKelvin \u212a k\n".encode(),
    "nuldata.txt": b"one alpha\x00two\x00alpha three\x00four",
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
    # the regex engine: word and line boundaries, case modes, Unicode
    ("word", ["-n", "-w", "alpha", "words.txt"]),
    ("word regex", ["-n", "-o", "-w", "al\\w+", "words.txt"]),
    ("word fixed", ["-n", "-w", "-F", "alpha", "words.txt"]),
    ("line regexp", ["-n", "-x", "ALPHA Alpha", "words.txt"]),
    ("line regexp fixed", ["-c", "-x", "-F", "-e", "ALPHA Alpha", "-e", "zzz", "words.txt"]),
    ("ignore case unicode", ["-n", "-o", "-i", "σοφός", "words.txt"]),
    ("ignore case kelvin", ["-n", "-o", "-i", "k", "words.txt"]),
    ("smart case lower", ["-n", "-S", "alpha", "words.txt"]),
    ("smart case upper", ["-n", "-S", "Alpha", "words.txt"]),
    ("case sensitive after -i", ["-n", "-i", "-s", "alpha", "words.txt"]),
    ("no unicode word", ["-n", "-o", "--no-unicode", "\\w+ve", "words.txt"]),
    ("unicode word", ["-n", "-o", "\\w+ve", "words.txt"]),
    ("unicode class", ["-n", "-o", "\\p{Greek}+", "words.txt"]),
    ("lazy", ["-o", "a.*?a", "words.txt"]),
    ("alternation priority", ["-o", "alpha|alphabet", "words.txt"]),
    ("empty matches", ["-o", "-n", "--column", "x*", "words.txt"]),
    ("crlf anchors", ["-n", "--crlf", "alpha$", "crlf.txt"]),
    ("crlf dot", ["-o", "--crlf", "a.*", "crlf.txt"]),
    ("no crlf anchors", ["-n", "alpha$", "crlf.txt"]),
    ("null data", ["--null-data", "-c", "alpha", "nuldata.txt"]),
    ("null data lines", ["--null-data", "-n", "alpha", "nuldata.txt"]),
    ("newline literal", ["-e", "a\nb", "plain.txt"]),
    ("newline class", ["[\n]", "plain.txt"]),
    ("nul banned", ["-e", "\\x00", "plain.txt"]),
    ("nul allowed as text", ["-a", "-c", "\\x00", "binary.bin"]),
    ("anchored class", ["-c", "^\\s*$", "plain.txt", "only_newlines.txt"]),
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

# walk filters, run in tests/fixtures/tree2 (sorted, but for the --sort cases)
TREE2_CASES = [
    ("glob", ["-l", "-g", "*.rs", "alpha"]),
    ("glob negated", ["-l", "-g", "!*.txt", "alpha"]),
    ("glob dir", ["-l", "-g", "sub/**", "alpha"]),
    ("glob alternates", ["-l", "-g", "*.{rs,py}", "alpha"]),
    ("glob class", ["-l", "-g", "[ab].*", "alpha"]),
    ("glob anchored", ["-l", "-g", "/*.rs", "alpha"]),
    ("glob dir only", ["-l", "-g", "!sub/", "alpha"]),
    ("iglob", ["-l", "--iglob", "*.RS", "alpha"]),
    ("glob case insensitive", ["-l", "--glob-case-insensitive", "-g", "*.rs", "alpha"]),
    ("glob case sensitive", ["-l", "-g", "*.RS", "alpha"]),
    ("glob error", ["-l", "-g", "[", "alpha"]),
    ("glob with hidden whitelist", ["-l", "-g", "*.gen", "alpha"]),
    ("type", ["-l", "-t", "rust", "alpha"]),
    ("type two", ["-l", "-t", "rust", "-t", "py", "alpha"]),
    ("type not", ["-l", "-T", "txt", "alpha"]),
    ("type make", ["-l", "-t", "make", "alpha"]),
    ("type add", ["-l", "--type-add", "mine:*.gen", "-t", "mine", "alpha"]),
    ("type add include", ["-l", "--type-add", "src:include:rust,py", "-t", "src", "alpha"]),
    ("type clear", ["-l", "--type-clear", "rust", "--type-add", "rust:*.py", "-t", "rust", "alpha"]),
    ("type unknown", ["-l", "-t", "nosuchtype", "alpha"]),
    ("type bad def", ["-l", "--type-add", "bad", "alpha"]),
    ("type list", ["--type-list"]),
    ("type list added", ["--type-add", "zzz:*.zzz", "--type-clear", "rust", "--type-list"]),
    ("max depth 0", ["--files", "-d", "0"]),
    ("max depth 1", ["--files", "--max-depth", "1"]),
    ("max depth 2", ["--files", "--maxdepth", "2"]),
    ("max filesize", ["-l", "--max-filesize", "1K", "alpha"]),
    ("max filesize bytes", ["-l", "--max-filesize", "2000", "alpha"]),
    ("max filesize bad", ["-l", "--max-filesize", "1X", "alpha"]),
    ("ignore file", ["-l", "--ignore-file", "../extra.ignore", "alpha"]),
    ("ignore file missing", ["-l", "--ignore-file", "../nope.ignore", "alpha"]),
    ("no ignore files", ["-l", "--no-ignore-files", "--ignore-file", "../extra.ignore", "alpha"]),
    ("subdir root", ["-l", "alpha", "sub"]),
    ("deep explicit root", ["-l", "alpha", "sub/deep"]),
    ("no ignore parent", ["-l", "--no-ignore-parent", "alpha", "sub"]),
    ("two roots", ["-l", "alpha", "sub", "d1"]),
    ("hidden attribute", ["-l", "--hidden", "alpha"]),
    ("no ignore dot keeps gitignore", ["-l", "--no-ignore-dot", "alpha"]),
    ("no ignore vcs keeps rgignore", ["-l", "--no-ignore-vcs", "alpha"]),
]

# --sort cases compare their order too (one thread is implied)
SORT_CASES = [
    ("sort path", ["--files", "--sort", "path"]),
    ("sortr path", ["--files", "--sortr", "path"]),
    ("sort modified", ["--files", "--sort", "modified"]),
    ("sortr modified", ["--files", "--sortr", "modified"]),
    ("sort files", ["-l", "--sort-files", "alpha"]),
    ("sort none", ["-l", "--sort", "path", "--sort", "none", "alpha"]),
    ("sort bad", ["--files", "--sort", "size"]),
]

TREE3_CASES = [
    ("not a repo", ["-l", "alpha"]),
    ("not a repo, no require git", ["-l", "--no-require-git", "alpha"]),
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


# ripgrep 14.1.1's bugs that grepper fixes (docs/PARITY.md section 6). Each case gives the
# right answer as `expect`: either other rg arguments that ask the same question without
# hitting the bug (("rg", [args, ...]), their outputs concatenated), or (rc, stdout). rg is
# run on the case too: if it gives the right answer, the case no longer shows the bug, and
# that is reported as a failure, so every case keeps documenting a real difference.
# (name, bug, args, directory under fixtures or "", sorted, expect)
RG_BUGS = [
    ("not-equal property", "B1", ["-o", "-n", "\\p{sc!=Greek}+", "words.txt"], "", False,
     ("rg", [["-o", "-n", "\\P{sc=Greek}+", "words.txt"]])),
    ("negated not-equal property", "B1", ["-o", "\\P{sc!=Greek}+", "words.txt"], "", False,
     ("rg", [["-o", "\\p{sc=Greek}+", "words.txt"]])),
    ("not-equal property in a class", "B1", ["-c", "[\\p{sc!=Latin}&&\\pL]", "words.txt"], "", False,
     ("rg", [["-c", "[\\P{sc=Latin}&&\\pL]", "words.txt"]])),
]


# a second tree for the walk filters: globs, types, depth, size, sorting, ignore-file
# precedence (.rgignore over .ignore over .gitignore), parent directories' ignore files
TREE2 = {
    ".git/HEAD": b"ref: refs/heads/main\n",
    ".gitignore": b"*.gen\n/anchored.txt\nsub/deep/\n!keep.gen\n",
    ".rgignore": b"!force.gen\n",
    ".ignore": b"ign_*.txt\n!ign_keep.txt\n",
    "a.rs": b"alpha rust\n",
    "b.py": b"alpha python\n",
    "c.txt": b"alpha text\n",
    "UPPER.RS": b"alpha upper rust\n",
    "Makefile": b"alpha make\n",
    "x.gen": b"alpha generated\n",
    "keep.gen": b"alpha kept generated\n",
    "force.gen": b"alpha forced\n",
    "anchored.txt": b"alpha anchored root\n",
    "ign_1.txt": b"alpha ign\n",
    "ign_keep.txt": b"alpha ign kept\n",
    "big.txt": b"alpha big\n" + b"x" * 2000 + b"\n",
    "sub/.gitignore": b"!re.gen\nlocal.txt\n",
    "sub/re.gen": b"alpha re-included\n",
    "sub/other.gen": b"alpha other gen\n",
    "sub/anchored.txt": b"alpha anchored sub\n",
    "sub/local.txt": b"alpha local\n",
    "sub/deep/z.txt": b"alpha deep z\n",
    "sub/ok.rs": b"alpha sub rust\n",
    "d1/one.txt": b"alpha one\n",
    "d1/d2/two.txt": b"alpha two\n",
    "d1/d2/d3/three.txt": b"alpha three\n",
    "hiddenattr.txt": b"alpha hidden by attribute\n",
}

# a tree outside any git repository of its own (its .gitignore applies only with
# --no-require-git); the grepper repository above it has no .git between
TREE3 = {
    ".gitignore": b"*.log\n",
    "a.log": b"alpha log\n",
    "b.txt": b"alpha txt\n",
}


def write_tree(name, files, mtimes=False):
    tree = os.path.join(FIX, name)
    shutil.rmtree(tree, ignore_errors=True)
    for i, (rel, data) in enumerate(sorted(files.items())):
        path = os.path.join(tree, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        if mtimes:
            # distinct modification times, in reverse name order, for --sort modified
            t = 1_700_000_000 + (len(files) - i) * 60
            os.utime(path, (t, t))
    return tree


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
    tree2 = write_tree("tree2", TREE2, mtimes=True)
    write_tree("tree3", TREE3)
    with open(os.path.join(FIX, "extra.ignore"), "wb") as f:
        f.write(b"c.txt\n*.py\n")
    if os.name == "nt":
        import ctypes
        ctypes.windll.kernel32.SetFileAttributesW(os.path.join(tree2, "hiddenattr.txt"), 2)


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
    return r.returncode, r.stdout, r.stderr


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
    tree2 = os.path.join(FIX, "tree2")
    tree3 = os.path.join(FIX, "tree3")
    cases += [(n, c, tree2, True, None) for n, c in TREE2_CASES]
    cases += [(n, c, tree2, False, None) for n, c in SORT_CASES]
    cases += [(n, c, tree3, True, None) for n, c in TREE3_CASES]
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
        g_err, r_err = g[2], r[2]
        g, r = (g[0], normalize(g[1])), (r[0], normalize(r[1]))
        if sort:
            g = g[0], b"".join(sorted(g[1].splitlines(True)))
            r = r[0], b"".join(sorted(r[1].splitlines(True)))
        if r[0] == 2:
            # an error must be the same error: stderr is compared, the program name aside
            g_msg = g_err.replace(b"grepper: ", b"rg: ")
            if g_msg != r_err:
                bad += 1
                print(f"DIFF {name} (stderr): {args}")
                print(f"  grepper {g_msg[:300]!r}")
                print(f"  rg      {r_err[:300]!r}")
                continue
        if g != r:
            bad += 1
            print(f"DIFF {name}: {args}")
            print(f"  grepper rc={g[0]} {g[1][:400]!r}")
            print(f"  rg      rc={r[0]} {r[1][:400]!r}")
    total = sum(1 for n, *_ in cases if a.k in n)
    print(f"{total - bad}/{total} cases match rg")
    fixed_bad, fixed_total = 0, 0
    for name, bug, args, sub, sort, expect in RG_BUGS:
        if a.k not in name:
            continue
        fixed_total += 1
        cwd = os.path.join(FIX, sub) if sub else FIX
        if expect[0] == "rg":
            outs = [run(a.rg, x, ["-j1"], cwd) for x in expect[1]]
            want = (0 if any(o[0] == 0 for o in outs) else outs[0][0], b"".join(normalize(o[1]) for o in outs))
        else:
            want = expect
        g = run(a.grepper, args, ["-j1"], cwd)
        r = run(a.rg, args, ["-j1"], cwd)
        g, r = (g[0], normalize(g[1])), (r[0], normalize(r[1]))
        if sort:
            g, r, want = [(x[0], b"".join(sorted(x[1].splitlines(True)))) for x in (g, r, want)]
        if g != want:
            fixed_bad += 1
            print(f"DIFF {bug} {name}: {args}")
            print(f"  grepper rc={g[0]} {g[1][:400]!r}")
            print(f"  want    rc={want[0]} {want[1][:400]!r}")
        elif r == want:
            fixed_bad += 1
            print(f"STALE {bug} {name}: rg 14.1.1 gives the right answer, so the case shows no bug")
    if fixed_total:
        print(f"{fixed_total - fixed_bad}/{fixed_total} ripgrep bugs fixed")
    return 1 if bad or fixed_bad else 0


if __name__ == "__main__":
    sys.exit(main())
