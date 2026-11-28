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
    # more output than one 64 KiB block: on one thread it is written as the buffer fills
    "wide.txt": b"".join(b"row %05d alpha %s\n" % (i, b"x" * 40) for i in range(4000)),
    # a match that starts before the first suffix occurrence it could end at (regex #1354)
    "rsuffix.txt": b"a z xz\nq zz z\n",
    # grapheme clusters for --max-columns-preview: combining marks, a ZWJ emoji, flags,
    # Hangul jamo, a Prepend, CR LF, whitespace (bstr's ASCII fast path skips it), invalid UTF-8
    "graphemes.txt": "éé\U0001f469‍\U0001f4bb needle ë needle\n".encode()
    + "flag \U0001f1fa\U0001f1f8\U0001f1e6\U0001f1fa x 각 ؀a needle\n".encode()
    + b"ab\r\n \t abc needle\n"
    + b"bad \xff\xe2\x82 \xf0\x9f\x91 needle\n",
    # more fixed strings than Teddy takes (64): the meta strategy's path, not a literal loop
    "many_words.txt": b"".join(b"line %d\n" % i for i in range(0, 5000, 50)),
    "long.txt": b"".join(b"line %d %s\n" % (i, b"needle" if i % 97 == 0 else b"hay") for i in range(5000)),
    "utf8.txt": "café ü naïve\nnothing\nCAFÉ\n".encode(),
    "binary.bin": b"text with alpha\x00\x01\x02 more alpha\n",
    "hash.txt": b"#include <a.h>\nx #include y\n  #inc\nno hash\n",
    # context: matches at lines 3, 5, 12 and 20 of 24
    "ctx.txt": b"".join(b"%s %d\n" % (b"hit" if i in (3, 5, 12, 20) else b"line", i) for i in range(1, 25)),
    "ws.txt": b"  \t lead alpha\n\tx alpha y alpha\nalpha\n",
    "pats.txt": b"gamma\r\nlast\n\nzzz",
    "esc.txt": b"tab\there\nquote\"d\nctl\x01x\x7f\n",
    "multi.txt": b"start\nfoo\nbar baz\nqux\n\nfoo bar\nend\n",
    # a match across the 64 KiB fill, and lines longer than MAX_LOOK_AHEAD
    "multi_big.txt": b"x" * 70000 + b"\nfoo\nbar\n" + (b"y" * 300 + b"\n") * 3 + b"tail foo\nbar\n",
    "multi_nul.txt": b"foo\nbar\n" + b"z\n" * 10 + b"\x00foo\nbar\n",
    "look3180.txt": b" b b b b b b b b\nc\n",
    "mixed_eol.txt": b"hello\nworld\r\nalpha beta\r\n",
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
    # one-pass regexes with capture groups (the one-pass DFA resolves them): a lazy group
    # whose match wins over going on, a greedy one, an alternation, a word boundary
    ("one-pass lazy group", ["-r", "[$1]", "l(p)??", "plain.txt"]),
    ("one-pass greedy group", ["-r", "[$1|$2]", "(a)(l)?", "plain.txt"]),
    ("one-pass alternation", ["-r", "<$1><$2>", "(g)amma|(d)elta", "plain.txt"]),
    ("one-pass word boundary", ["-r", "<$1>", "\\b(\\w+) again", "plain.txt"]),
    ("many fixed strings, count", ["-F", "-c", "-f", "many_words.txt", "long.txt"]),
    ("many fixed strings, only matching", ["-F", "-o", "-n", "-f", "many_words.txt", "long.txt"]),
    ("many fixed strings, words", ["-F", "-w", "-c", "-f", "many_words.txt", "long.txt"]),
    # a DFA cache too small for any lazy DFA: every search on the backtracker and PikeVM
    ("no lazy DFA, lines", ["--dfa-size-limit", "1K", "-n", "alpha|delta", "plain.txt"]),
    ("no lazy DFA, captures", ["--dfa-size-limit", "1K", "-o", "-r", "<$1>", "(a)l(p)ha", "plain.txt"]),
    ("no lazy DFA, multi line", ["--dfa-size-limit", "1K", "-U", "-n", "beta\\ngamma", "plain.txt"]),
    ("no lazy DFA, word", ["--dfa-size-limit", "1K", "-w", "-c", "alpha", "plain.txt"]),
    # \z ends each line's search: the reverse anchored strategy, in the candidate search too
    ("end anchored, count", ["-c", "[a-z]+\\z", "plain.txt"]),
    ("end anchored, only matching", ["-o", "-n", "\\w+\\s*\\z", "plain.txt"]),
    ("end anchored, inverted", ["-v", "-n", "a\\z", "plain.txt"]),
    ("output past one block", ["-F", "-n", "alpha", "wide.txt"]),
    ("output past one block, heading", ["-j1", "-H", "--heading", "-F", "alpha", "wide.txt", "plain.txt"]),
    ("output past one block, stats", ["-j1", "--stats", "-F", "alpha", "wide.txt", "plain.txt"]),
    ("output past one block, json", ["-j1", "--json", "-F", "alpha", "wide.txt", "plain.txt"]),
    ("output past one block, context", ["-j1", "-C1", "-F", "row 0", "wide.txt", "long.txt"]),
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
    # --max-columns-preview: the first N grapheme clusters (bstr's UAX #29 segmentation)
    ("max columns preview", ["-M", "5", "--max-columns-preview", "-e", "needle", "graphemes.txt"]),
    ("max columns preview, matches", ["-M", "9", "--max-columns-preview", "--color", "always", "-e", "needle|e", "graphemes.txt"]),
    ("max columns preview, one more match", ["-M", "2", "--max-columns-preview", "-r", "R", "-e", "c", "graphemes.txt"]),
    ("max columns preview, only matching", ["-M", "3", "--max-columns-preview", "-o", "-e", "needle.*", "graphemes.txt"]),
    ("max columns preview, context", ["-M", "4", "--max-columns-preview", "-C1", "-n", "-e", "flag", "graphemes.txt"]),
    ("max columns preview, invalid utf-8", ["-M", "6", "--max-columns-preview", "-a", "-e", "bad", "graphemes.txt"]),
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
    # \A and \z: grep-regex gives the matcher no line terminator, so lines are searched one
    # by one and the anchors match at each line's ends
    ("haystack anchor start", ["-n", "\\Aalpha", "plain.txt"]),
    ("haystack anchor end", ["-n", "-c", "a\\z", "plain.txt", "crlf.txt"]),
    ("haystack anchor inverted", ["-n", "-v", "\\Aalpha", "plain.txt"]),
    ("haystack anchor inverted max count context", ["-n", "-v", "-m", "2", "-A", "1", "\\Agamma", "plain.txt"]),
    ("haystack anchor only matching", ["-o", "--column", "\\A\\w+", "words.txt"]),
    # -r/--replace: captures by number and name, $$, unknown and malformed references,
    # empty matches, -o, context, colours and the column of the replaced line
    ("replace", ["-r", "X", "alpha", "plain.txt"]),
    ("replace whole match", ["-n", "-r", "[$0]", "alpha", "plain.txt"]),
    ("replace groups", ["-r", "${1}_$2", "(al)(pha)", "plain.txt"]),
    ("replace named group", ["-r", "<$w>", "(?P<w>al)pha", "plain.txt"]),
    ("replace dollars", ["-r", "$$-$x-$", "alpha", "plain.txt"]),
    ("replace odd references", ["-r", "${1a}$1a$01$9${}${1", "(a)", "plain.txt"]),
    ("replace group not taking part", ["-o", "-r", "<$1>", "a(l)?p", "plain.txt"]),
    ("replace empty", ["-r", "", "alpha", "plain.txt"]),
    ("replace empty matches", ["-r", "Z", "x*", "words.txt"]),
    ("replace empty matches only", ["-o", "-r", "Z", "x*", "words.txt"]),
    ("replace unicode", ["-r", "<$0>", "-i", "σοφός|café", "words.txt"]),
    ("replace column", ["-n", "--column", "-r", "ZZZZ", "a", "plain.txt"]),
    ("replace vimgrep", ["--vimgrep", "-r", "Z", "al", "plain.txt"]),
    ("replace invert context", ["-v", "-r", "Z", "-C1", "gamma", "plain.txt"]),
    ("replace context", ["-C1", "-r", "Z", "gamma", "plain.txt"]),
    ("replace literals", ["-r", "Z", "-F", "-e", "alpha", "-e", "beta", "plain.txt"]),
    ("replace literal", ["-r", "[$0|$1]", "-F", "alpha", "plain.txt"]),
    ("replace colour", ["--color", "always", "-r", "Z$0", "alpha", "plain.txt"]),
    ("replace max count", ["-m", "1", "-r", "Z", "alpha", "plain.txt"]),
    ("replace passthru", ["--passthru", "-r", "Z", "beta", "plain.txt"]),
    ("replace max columns", ["-M", "8", "-r", "ZZZZZZZZZZ", "alpha", "plain.txt"]),    ("replace crlf", ["--crlf", "-r", "<$0>", "a.", "crlf.txt"]),
    ("replace word", ["-w", "-r", "Z", "alpha", "words.txt"]),
    ("replace count ignores it", ["-c", "-r", "Z", "alpha", "plain.txt"]),
    ("replace json ignores it", ["--json", "-r", "Z", "beta", "plain.txt"]),
    # -U/--multiline: the MultiLine strategy and the multi line printer paths
    ("multiline", ["-U", "-n", "foo\\nbar", "multi.txt"]),
    ("multiline joined lines", ["-U", "-n", "o\\n|r\\s", "multi.txt"]),
    ("multiline only matching", ["-U", "-o", "-n", "--column", "o\\n\\w+", "multi.txt"]),
    ("multiline vimgrep", ["-U", "--vimgrep", "a\\w*\\n\\w", "multi.txt"]),
    ("multiline dotall", ["-U", "--multiline-dotall", "-c", "start.*end", "multi.txt"]),
    ("multiline no dotall", ["-U", "-c", "start.*end", "multi.txt"]),
    ("multiline count matches", ["-U", "--count-matches", "\\w+\\n", "multi.txt"]),
    ("multiline invert context", ["-U", "-v", "-n", "-C1", "foo\\nbar", "multi.txt"]),
    ("multiline context", ["-U", "-n", "-A1", "-B1", "qux\\n\\n", "multi.txt"]),
    ("multiline byte offset", ["-U", "-b", "-n", "baz\\nqux", "multi.txt"]),
    ("multiline max count", ["-U", "-m", "1", "-n", "foo", "multi.txt"]),
    ("multiline replace", ["-U", "-r", "<$0>", "foo\\n", "multi.txt"]),
    ("multiline colour", ["-U", "--color", "always", "-n", "o\\nb", "multi.txt"]),
    ("multiline json", ["-U", "--json", "o\\nb", "multi.txt"]),
    ("multiline passthru", ["-U", "--passthru", "baz\\nqux", "multi.txt"]),
    ("multiline no line terminator in regex", ["-U", "-n", "ba.", "multi.txt"]),
    ("multiline big file", ["-U", "-n", "-c", "foo\\nbar", "multi_big.txt"]),
    ("multiline big file lines", ["-U", "-o", "-b", "foo\\nbar|y\\ny", "multi_big.txt"]),
    ("multiline big file no mmap", ["-U", "--no-mmap", "-n", "-o", "foo\\nbar", "multi_big.txt"]),
    ("multiline binary", ["-U", "foo\\nbar", "multi_nul.txt"]),
    ("multiline binary text", ["-U", "-a", "-c", "foo\\nbar", "multi_nul.txt"]),
    ("multiline several files", ["-U", "-c", "foo\\nbar", "multi.txt", "multi_big.txt", "plain.txt"]),
    ("multiline crlf", ["-U", "--crlf", "-n", "alpha\\r?\\n\\w", "crlf.txt"]),
    ("multiline max columns", ["-U", "-M", "4", "-n", "foo\\nbar", "multi.txt"]),
    ("anchored class", ["-c", "^\\s*$", "plain.txt", "only_newlines.txt"]),
    # JSON Lines and statistics (timings normalized)
    ("json", ["--json", "alpha", "plain.txt", "crlf.txt"]),
    ("json context", ["--json", "-C", "1", "hit", "ctx.txt"]),
    ("json invert context", ["--json", "-v", "-C", "1", "line", "ctx.txt"]),
    # both files match: a file without one is left out of 14.1.1's summary (RG_BUGS U3178)
    ("json non utf8", ["--json", "-a", "alpha|café", "binary.bin", "utf8.txt"]),
    ("json binary", ["--json", "alpha", "binary.bin"]),
    ("json max count", ["--json", "-m", "1", "alpha", "plain.txt"]),
    # the control bytes themselves: the interim regex engine has no \x escapes
    ("json escapes", ["--json", "-a", "\x01|\t|\"", "esc.txt"]),
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
    ("multiline stdin", ["-U", "-n", "b\\nc"], b"a\nb\nc\nd\n"),
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
    ("walk regex", ["-n", "^int [a-z]+;$"]),
    ("walk regex -l", ["-l", "al.ha (in|kept)"]),
    ("walk multiline", ["-U", "-n", "alpha.*\\n.*"]),
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


SCHEME_TYPE = [
    (b"lisp: *.el, *.jl, *.lisp, *.lsp, *.sc, *.scm\n", b"lisp: *.el, *.jl, *.lisp, *.lsp\n"),
    (b"scala: *.sbt, *.scala\n", b"scala: *.sbt, *.scala\nscheme: *.sc, *.scm, *.sld, *.ss\n"),
]

# ripgrep 14.1.1's bugs that grepper fixes (docs/PARITY.md section 6). Each case gives the
# right answer as `expect`: either other rg arguments that ask the same question without
# hitting the bug (("rg", [args, ...]), their outputs concatenated), or (rc, stdout). rg is
# run on the case too: if it gives the right answer, the case no longer shows the bug, and
# that is reported as a failure, so every case keeps documenting a real difference. An "rg"
# answer may name a third item, the directory to run it from. ("rg_sub", args, [(old, new),
# ...]) is rg 14.1.1's output for args with each old bytes replaced, once, by new.
# (name, bug, args, directory under fixtures or "", sorted, expect)
RG_BUGS = [
    ("not-equal property", "B1", ["-o", "-n", "\\p{sc!=Greek}+", "words.txt"], "", False,
     ("rg", [["-o", "-n", "\\P{sc=Greek}+", "words.txt"]])),
    ("negated not-equal property", "B1", ["-o", "\\P{sc!=Greek}+", "words.txt"], "", False,
     ("rg", [["-o", "\\p{sc=Greek}+", "words.txt"]])),
    ("not-equal property in a class", "B1", ["-c", "[\\p{sc!=Latin}&&\\pL]", "words.txt"], "", False,
     ("rg", [["-c", "[\\P{sc=Latin}&&\\pL]", "words.txt"]])),
    # the parent .gitignore has docs/**/draft*: rg 14.1.1 matches docs' paths against src's
    # absolute base when src is walked first, and prints docs/a/b/draft1.md
    ("walk two roots", "B2", ["-F", "-l", "alpha", "src", "docs"], "tree", True,
     ("rg", [["-F", "-l", "alpha", "src"], ["-F", "-l", "alpha", "docs"]])),
    ("walk two roots, one deeper", "B2", ["-F", "-l", "alpha", "src/deep", "docs"], "tree", True,
     ("rg", [["-F", "-l", "alpha", "src/deep"], ["-F", "-l", "alpha", "docs"]])),
    # zero patterns match nothing, so -v matches every line; rg 14.1.1 quits before searching
    # (and 16.0.0 still matches everything with -i or -S, so -v prints nothing there). The
    # answer is -v with a pattern that matches nothing, the empty class [a&&b].
    ("invert zero patterns", "U1332", ["-n", "-v", "-f", "empty.txt", "plain.txt"], "", False,
     ("rg", [["-n", "-v", "-e", "[a&&b]", "plain.txt"]])),
    ("invert zero patterns, count", "U1332", ["-c", "-v", "-f", "empty.txt", "plain.txt", "words.txt"], "", False,
     ("rg", [["-c", "-v", "-e", "[a&&b]", "plain.txt", "words.txt"]])),
    ("invert zero patterns, ignore case", "U1332", ["-v", "-i", "-f", "empty.txt", "plain.txt"], "", False,
     ("rg", [["-v", "-i", "-e", "[a&&b]", "plain.txt"]])),
    ("invert zero patterns, smart case, words", "U1332", ["-v", "-S", "-w", "-f", "empty.txt", "plain.txt"], "", False,
     ("rg", [["-v", "-S", "-w", "-e", "[a&&b]", "plain.txt"]])),
    ("invert zero patterns, only matching", "U1332", ["-v", "-o", "-F", "-f", "empty.txt", "plain.txt"], "", False,
     ("rg", [["-v", "-o", "-e", "[a&&b]", "plain.txt"]])),
    # -q --files-without-match: success when some file has no match. rg 14.1.1 inverts it;
    # the answer is the exit code of the same search without -q
    ("quiet files without match, all match", "U3108", ["-q", "--files-without-match", "alpha", "plain.txt", "words.txt"], "", False,
     (1, b"")),
    ("quiet files without match, none match", "U3108", ["-q", "--files-without-match", "zzz", "plain.txt", "empty.txt"], "", False,
     (0, b"")),
    ("quiet files without match, walk", "U3108", ["-q", "--files-without-match", "zzz"], "tree", False,
     (0, b"")),
    # a UTF-8 BOM opens bom/.gitignore: rg 14.1.1 reads its first pattern as BOM+before.txt
    ("ignore file with a BOM", "U2177", ["-l", "hit", "bom"], "tree5", True,
     (0, os.path.join("bom", "other.txt").encode() + b"\n")),
    # a lone ! (and a lone /) is no pattern: rg 14.1.1 compiles ! to a whitelist of
    # everything, which brings back x.tmp and the hidden file
    ("ignore file with a lone !", "U3527", ["-l", "hit", "bang"], "tree5", True,
     (0, os.path.join("bang", "y.txt").encode() + b"\n")),
    # "sp2\   ": rg 14.1.1 trims it to "sp2\", a parse error, and lists "sp2 "; the file
    # list is compared, since Windows cannot open a name ending in a space
    ("ignore file with trailing spaces", "U3477", ["--files", "space"], "tree5", True,
     (0, os.path.join("space", "keep").encode() + b"\n")),
    # a glob ending in '.': rg 14.1.1 gives such a path no base name, so -g foo. matches
    # nothing and the walk lists nothing
    ("glob ending in a dot", "U2990", ["--files", "-g", "foo.", "dot"], "tree5", True,
     (0, os.path.join("dot", "foo.").encode() + b"\n")),
    ("glob ending in a dot, ignored", "U2990", ["--files", "-g", "!foo.", "dot"], "tree5", True,
     (0, os.path.join("dot", "bar").encode() + b"\n")),
    # a glob class never matches '/': rg 14.1.1 lets [!x] and [/] match it, and ignores
    # cls/a/b.txt and cls/c/d.txt
    ("ignore class with the separator", "U2745", ["--files", "cls"], "tree5", True,
     (0, b"".join(os.path.join("cls", *p.split("/")).encode() + b"\n" for p in ["a/b.txt", "c/d.txt", "keep.txt"]))),
    ("glob class with the separator", "U2745", ["--files", "--no-ignore", "-g", "*[/]*", "cls"], "tree5", True,
     (1, b"")),
    # --stats "bytes searched" when the search stops early on a read file: rg 14.1.1 says 0;
    # the answer is what a memory map gives, the bytes up to the end of the last line looked at
    ("stats bytes searched, stopped early", "U2944", ["--no-mmap", "-m1", "--stats", "-c", "alpha", "plain.txt"], "", False,
     ("rg", [["--mmap", "-m1", "--stats", "-c", "alpha", "plain.txt"]])),
    # --json's summary counts every search: rg 14.1.1 leaves out those without a match (here
    # both, so "searches":0 and "bytes_searched":0); the answer is rg 16.0.0's, timings zeroed
    ("json summary of searches without a match", "U3178", ["--json", "zzz", "empty.txt", "plain.txt"], "", False,
     (1, b'{"data":{"elapsed_total":{"human":"0s","nanos":0,"secs":0},"stats":{"bytes_printed":0,"bytes_searched":51,'
         b'"elapsed":{"human":"0s","nanos":0,"secs":0},"matched_lines":0,"matches":0,"searches":2,"searches_with_match":0}},'
         b'"type":"summary"}\n')),
    # --ignore-file is rooted at the working directory: rg 14.1.1 roots it at "", so with an
    # absolute search path /haystack never matches; the answer is the same search from there
    # with no path, its paths made absolute
    ("ignore file anchored, absolute root", "U3179", ["--files", "--ignore-file", os.path.join(FIX, "tree5", "anchor.ignore"), os.path.join(FIX, "tree5", "a")], "tree5/a/b/c", True,
     (0, os.path.join(FIX, "tree5", "a", "b", "c", "other").encode() + b"\n")),
    # -g '!cls/' from inside cls, on the tree above: the walk meets cls as the glob's root,
    # which rg 14.1.1 strips to nothing and keeps; the answer is the search run from tree5
    ("glob dir from inside it", "U3581", ["--files", "--no-ignore", "-g", "!cls/", os.path.join(FIX, "tree5")], "tree5/cls", True,
     ("rg", [["--files", "--no-ignore", "-g", "!cls/", os.path.join(FIX, "tree5")]], "tree5")),
    # Scheme is its own type, no longer part of lisp (*.sc and *.scm move, *.ss and *.sld are
    # new); the rest of the table stays 14.1.1's
    ("type list", "U3484", ["--type-list"], "", False,
     ("rg_sub", ["--type-list"], SCHEME_TYPE)),
    ("type list added", "U3484", ["--type-add", "zzz:*.zzz", "--type-clear", "rust", "--type-list"], "", False,
     ("rg_sub", ["--type-add", "zzz:*.zzz", "--type-clear", "rust", "--type-list"], SCHEME_TYPE)),
    ("type lisp", "U3484", ["--files", "-t", "lisp", "types"], "tree5", True,
     (0, os.path.join("types", "c.el").encode() + b"\n")),
    ("type scheme", "U3484", ["--files", "-t", "scheme", "types"], "tree5", True,
     (0, b"".join(os.path.join("types", f).encode() + b"\n" for f in ["a.scm", "b.ss"]))),
    # -r keeps each line's own terminator: with --crlf, rg 14.1.1 ends the replaced "hello\n"
    # with \r\n; the answer is the input itself, as $0 for a whole line changes nothing
    ("replace keeps the line terminator", "U3100", ["--crlf", "-r", "$0", ".+", "mixed_eol.txt"], "", False,
     (0, b"hello\nworld\r\nalpha beta\r\n")),
    # -U -m counts matches: rg 14.1.1 counts the blocks of touching matches, so -m1 '^' prints
    # the whole file; the answers are rg 16.0.0's
    ("multiline max count, touching matches", "U3076", ["-U", "-m1", "^", "multi.txt"], "", False,
     (0, b"start\n")),
    ("multiline max count, lines", "U3076", ["-U", "-m2", "-n", "\\w+\\n", "multi.txt"], "", False,
     (0, b"1:start\n2:foo\n")),
    ("multiline max count, count matches", "U3076", ["-U", "-m1", "--count-matches", "\\w+\\n", "multi.txt"], "", False,
     (0, b"1\n")),
    # --json splits a multi line block at the line ends no match crosses: rg 14.1.1 writes one
    # message for two matches; the answer is rg 16.0.0's
    ("multiline json, two matches in a block", "U1983", ["-U", "--json", "t\\nfoo|z\\nqux", "multi.txt"], "", False,
     (0, b'{"type":"begin","data":{"path":{"text":"multi.txt"}}}\n{"type":"match","data":{"path":{"text":"multi.txt"},"lines":{"text":"start\\nfoo\\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"t\\nfoo"},"start":4,"end":9}]}}\n{"type":"match","data":{"path":{"text":"multi.txt"},"lines":{"text":"bar baz\\nqux\\n"},"line_number":3,"absolute_offset":10,"submatches":[{"match":{"text":"z\\nqux"},"start":6,"end":11}]}}\n{"type":"end","data":{"path":{"text":"multi.txt"},"binary_offset":null,"stats":{"elapsed":{"secs":0,"nanos":0,"human":"0s"},"searches":1,"searches_with_match":1,"bytes_searched":35,"bytes_printed":424,"matched_lines":4,"matches":2}}}\n{"data":{"elapsed_total":{"human":"0s","nanos":0,"secs":0},"stats":{"bytes_printed":424,"bytes_searched":35,"elapsed":{"human":"0s","nanos":0,"secs":0},"matched_lines":4,"matches":2,"searches":1,"searches_with_match":1}},"type":"summary"}\n')),
    # -U -r with a match that ends past the matched lines: rg 14.1.1 panics (slice index starts
    # at 18 but ends at 17); the answer is rg 16.0.0's, its regression test r3180
    ("multiline replace past the range", "U3180", ["(^|[^a-z])((([a-z]+)?)\\s)?b(\\s([a-z]+)?)($|[^a-z])", "look3180.txt", "-U", "-rx"], "", False,
     (0, b"xbxbx\n")),
    # rg 14.1.1's reverse suffix search stops at the first suffix occurrence a match ends at,
    # though a match starting earlier ends later: it prints "z" twice for "a z xz"; the
    # leftmost-first matches are "a z xz" and, on the second line, "z", "z" and "z"
    # (regex 1.13.1, rust-lang/regex#1354; rg 16.0.0 agrees)
    ("reverse suffix, earlier match", "RX1354", ["-o", "[a-c][^\\n]*xz|z", "rsuffix.txt"], "", False,
     (0, b"a z xz\nz\nz\nz\n")),
    ("reverse suffix, earlier match, multi line", "RX1354", ["-U", "-o", "[a-c][^\\n]*xz|z", "rsuffix.txt"], "", False,
     (0, b"a z xz\nz\nz\nz\n")),
    # tree4's .gitignore has docs/a/b/draft*, which git applies to docs/a/b/draft1.md: rg
    # 14.1.1 drops the directories between the root and the file, matches docs/draft1.md,
    # and prints it
    ("parent rule below the root", "B3", ["-l", "alpha", "docs"], "tree4", True,
     ("rg", [["-l", "alpha"]])),
    ("parent rule below the root, root deeper", "B3", ["-l", "alpha", "docs/a"], "tree4", True,
     (0, b"docs/a\\final.md\n" if os.name == "nt" else b"docs/a/final.md\n")),
    ("parent rule below the working directory", "B3", ["-l", "alpha"], "tree4/docs", True,
     (0, b"a\\final.md\n" if os.name == "nt" else b"a/final.md\n")),
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


# ignore-file syntax that ripgrep 14.1.1 reads unlike git, one directory per case
TREE5 = {
    "bom/.gitignore": b"\xef\xbb\xbfbefore.txt\nafter.txt\n",
    "bom/before.txt": b"hit\n",
    "bom/after.txt": b"hit\n",
    "bom/other.txt": b"hit\n",
    "bang/.gitignore": b"*.tmp\n!\n",
    "bang/x.tmp": b"hit\n",
    "bang/y.txt": b"hit\n",
    "bang/.hidden": b"hit\n",
    "bang/sub/.gitignore": b"!\n/\n",
    "bang/sub/z.tmp": b"hit\n",
    # trailing spaces: "sp2\ " keeps one escaped space; "trail" loses its three
    "space/.gitignore": b"sp2\\   \ntrail   \n",
    "space/sp2 ": b"hit\n",
    "space/trail": b"hit\n",
    "space/keep": b"hit\n",
    # a name ending in '.'
    "dot/foo.": b"hit\n",
    "dot/bar": b"hit\n",
    # classes that would match '/'
    "cls/.gitignore": b"a[!x]b.txt\nc[/]d.txt\n",
    "cls/a/b.txt": b"hit\n",
    "cls/c/d.txt": b"hit\n",
    "cls/ayb.txt": b"hit\n",
    "cls/keep.txt": b"hit\n",
    "types/a.scm": b"hit\n",
    "types/b.ss": b"hit\n",
    "types/c.el": b"hit\n",
    # an --ignore-file pattern anchored at the working directory
    "anchor.ignore": b"/haystack\n",
    "a/b/c/haystack": b"hit\n",
    "a/b/c/other": b"hit\n",
}

# a wide tree for the parallel walk: the rules hold a '/', so each entry is stripped against
# the directory of every node above it, which a parallel walk must keep alive after the
# thread that listed that directory has moved on
TREE6 = {".gitignore": b"d*/s1/skip.txt\n/d1*/\n"}
for _i in range(60):
    TREE6[f"d{_i}/.gitignore"] = b"s2/keep.txt\n"
    for _j in range(4):
        for _f in ("keep.txt", "skip.txt"):
            TREE6[f"d{_i}/s{_j}/{_f}"] = b"alpha\n"

TREE6_CASES = [
    ("wide tree, files", ["--files"]),
    ("wide tree, search", ["-c", "alpha"]),
]

# parent-directory rules that name directories below the search root (PARITY B3)
TREE4 = {
    ".gitignore": b"docs/a/b/draft*\n",
    "docs/a/b/draft1.md": b"alpha draft\n",
    "docs/a/final.md": b"alpha final\n",
}


def write_tree(name, files, mtimes=False):
    tree = os.path.join(FIX, name)
    shutil.rmtree(tree, ignore_errors=True)
    for i, (rel, data) in enumerate(sorted(files.items())):
        path = os.path.join(tree, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.name == "nt" and rel.endswith((" ", ".")):
            # Win32 drops a trailing space or dot from a name (abspath too); the \\?\ form
            # keeps it
            path = "\\\\?\\" + os.path.join(os.path.abspath(os.path.dirname(path)), rel.split("/")[-1])
        with open(path, "wb") as f:
            f.write(data)
        if mtimes:
            # distinct modification times, in reverse name order, for --sort modified
            t = 1_700_000_000 + (len(files) - i) * 60
            os.utime(path, (t, t))
    return tree


def write_fixtures():
    os.makedirs(FIX, exist_ok=True)
    # the fixtures are a git repository of their own: rg and grepper read .gitignore files
    # only inside one (require_git), and a copy of grepper without its .git would test none
    os.makedirs(os.path.join(FIX, ".git"), exist_ok=True)
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
    write_tree("tree4", TREE4)
    write_tree("tree5", TREE5)
    write_tree("tree6", TREE6)
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
    # a report holds patterns and bytes the Windows console's code page cannot encode
    sys.stdout.reconfigure(errors="backslashreplace")
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
    cases += [(n, c, os.path.join(FIX, "tree6"), True, None) for n, c in TREE6_CASES]
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
    # every case again with grepper on 4 threads, against rg on one: the file order is then
    # not fixed, so the lines are compared sorted. Not only walks: several paths given (or
    # stdin and a path) are searched in parallel too, and a version that searched no given
    # file there passed the walked cases alone. rg -j4 is no reference: it loses parent
    # rules at random with two roots (PARITY B2)
    par_bad, par_total = 0, 0
    for name, args, cwd, sort, stdin, cfg in cases:
        if a.k not in name:
            continue
        par_total += 1
        env = None
        if cfg is not None:
            path = os.path.join(FIX, "rgconfig")
            with open(path, "wb") as f:
                f.write(cfg)
            env = dict(ENV, RIPGREP_CONFIG_PATH=path)
        g = run(a.grepper, args, ["-j4"], cwd, stdin, env)
        r = run(a.rg, args, ["-j1"], cwd, stdin, env)
        # -0 ends paths with NUL instead of a newline: records end in NUL only when nothing
        # else ends them (--files -0); with -c a record is still a line, path NUL count
        split = lambda b: sorted(b.splitlines(True) if b"\n" in b else b.split(b"\0"))
        g = g[0], split(normalize(g[1]))
        r = r[0], split(normalize(r[1]))
        if g != r:
            par_bad += 1
            print(f"DIFF -j4 {name}: {args}")
            print(f"  grepper rc={g[0]} {g[1][:400]!r}")
            print(f"  rg      rc={r[0]} {r[1][:400]!r}")
    if par_total:
        print(f"{par_total - par_bad}/{par_total} cases match rg with -j4")
    bad += par_bad
    fixed_bad, fixed_total = 0, 0
    for name, bug, args, sub, sort, expect in RG_BUGS:
        if a.k not in name:
            continue
        fixed_total += 1
        cwd = os.path.join(FIX, sub) if sub else FIX
        if expect[0] == "rg":
            ref_cwd = os.path.join(FIX, expect[2]) if len(expect) > 2 else cwd
            outs = [run(a.rg, x, ["-j1"], ref_cwd) for x in expect[1]]
            want = (0 if any(o[0] == 0 for o in outs) else outs[0][0], b"".join(normalize(o[1]) for o in outs))
        elif expect[0] == "rg_sub":
            rc, out, _ = run(a.rg, expect[1], ["-j1"], cwd)
            for old, new in expect[2]:
                assert old in out, (name, old)
                out = out.replace(old, new, 1)
            want = (rc, normalize(out))
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
