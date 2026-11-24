"""Literal extraction, grepper's port (src/hir_literal.odin) against regex-syntax 0.8.4
(tools/literal_oracle): for every pattern of a hand-written corpus plus random ones from a fixed
seed, the prefix and suffix sequences, raw and after optimize_*_by_preference, must be the same
line for line (literal order and exact/inexact flags included).

    python tests/literal_oracle.py [-n RANDOM_COUNT] [--seed SEED] [--hir] [--keep]

--hir prints regex-syntax's HIR for each mismatch (to tell a port bug from a translator
difference); --keep leaves the pattern and output files in build/literal_oracle/."""
import argparse
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORACLE_DIR = os.path.join(ROOT, "tools", "literal_oracle")
ORACLE_EXE = os.path.join(ORACLE_DIR, "target", "release", "literal_oracle" + (".exe" if os.name == "nt" else ""))
WORK = os.path.join(ROOT, "build", "literal_oracle")

# One per Extractor / Seq branch, roughly in the order of src/hir/literal.rs.
HAND = [
    # empty, looks
    r"", r"^", r"$", r"^$", r"\b", r"\B", r"\b{start}", r"\b{end}", r"\<", r"\>", r"(?m)^", r"(?m)$",
    r"\A", r"\z", r"^foo", r"foo$", r"^foo$", r"\bfoo\b", r"(?-u:\b)foo(?-u:\B)", r"a^b", r"a$b",
    # literals
    r"a", r"foo", r"foobar", r"Sherlock Holmes", r"\x00", r"\xFF", r"(?-u:\xFF)", r"(?-u:\xFF\xFE)",
    r"(?-u:a\xFFb)", r"é", r"日本語", r"😀", r"\u{10FFFF}", r"a\nb", r"\t", r"\\", r"\.", r"\"",
    "a" * 99, "a" * 100, "a" * 101, "b" * 150, "x" + "y" * 120 + "z", r"(?-u:\xC0\xC1)",
    # classes under and over limit_class (10)
    r"[a]", r"[ab]", r"[a-c]", r"[a-j]", r"[a-k]", r"[a-l]", r"[0-9]", r"[0-9a]", r"[0-9ab]",
    r"[a-ex-z]", r"[a-ex-zA]", r"[a-ex-zAB]", r"[^a]", r"\d", r"\w", r"\s", r"(?-u:\d)", r"(?-u:\s)",
    r"[é-ë]", r"[α-κ]", r"[α-λ]", r"[\x00-\x09]", r"[\x00-\x0A]", r"(?-u:[\x80-\x89])",
    r"(?-u:[\x80-\x8A])", r"(?-u:[\xF0-\xFF])", r"[\u{D7FE}-\u{E001}]", r"[\u{D7FF}\u{E000}]",
    r"[😀-😉]", r"[😀-😊]", r"[a😀]", r"[[:digit:]]", r"[[:xdigit:]]", r"[[:punct:]]", r"[a-c][x-z]",
    r"[a-c][x-z][0-2]", r"[a-e][a-e][a-e][a-e]", r"[ab][cd][ef][gh][ij][kl][mn][op]", r"\pN", r"\p{Greek}",
    r".", r"(?s).", r"(?-u:.)", r"(?s-u:.)", r"[^\n]", r"foo[a-c]", r"[a-c]foo", r"foo[a-z]bar",
    r"foo[a-j]bar", r"foo\dbar", r"[a-c]+", r"[a-c]*foo", r"[ab]{3}", r"[abc]{5}", r"[a-e]{4}",
    # repetitions
    r"a*", r"a+", r"a?", r"a*?", r"a+?", r"a??", r"a{0}", r"a{1}", r"a{2}", r"a{3}", r"a{10}", r"a{11}",
    r"a{20}", r"a{0,1}", r"a{0,1}?", r"a{0,2}", r"a{0,2}?", r"a{1,2}", r"a{2,3}", r"a{2,}", r"a{3,5}?",
    r"(?:ab){3}", r"(?:ab){10}", r"(?:ab){11}", r"(?:ab){0,}", r"(?:ab)*c", r"(?:ab)+c", r"(?:ab)?c",
    r"(?:ab)??c", r"c(?:ab)*", r"c(?:ab)+", r"c(?:ab)?", r"c(?:ab)??", r"foo*bar", r"fo+bar", r"fo?bar",
    r"fo??bar", r"(?:a|b)*", r"(?:a|b)+", r"(?:a|b){3}", r"(?:a|b){2,4}", r"(?:a|bc){3}",
    r"(?:foo|bar){2}baz", r"(?:[a-c]x){3}", r"(?:[a-c]{2}){3}", r"(?:[a-f]{2}){3}", r"(?:a*){3}",
    r"(?:a*)+", r"(?:a+)*", r"(?:)*", r"(?:^)+", r"(?:$)*", r"(?:\b)?", r"a{1000}", r"(?:abc){1,1000}",
    r"(?U)a*b", r"(?U)a+?b", r"(?U)ab?c", r"(?U)(?:ab)??c", r"x*y*z*", r"x+y+z+", r"x?y?z?", r"x??y??z??",
    r"(?:a?){10}", r"(?:a?){11}", r"(?:a?b?){4}", r"(?:ab?){6}", r"[ab]?[cd]?[ef]?[gh]?",
    # captures
    r"(foo)", r"(?<name>foo)bar", r"((a)(b))c", r"(a|b)(c|d)", r"(a)*", r"(a)+b", r"(?:(a)|b)c",
    r"()", r"(())", r"(|a)", r"(a|)", r"(a||b)",
    # concat with an inexact early exit
    r"ab*c", r"ab+cd", r"a.b", r"a\wb", r"foo.*bar", r"foo\w+bar", r"foo[^x]bar", r"a(?:b|c*)d",
    r"(?:foo|bar.*)baz", r"(?:foo|ba+r)baz", r"x(?:y|z+)w(?:u|v)", r"\w+foo", r"foo\w+", r"a[^b]c[^d]e",
    # alternations
    r"a|b", r"a|b|c", r"foo|bar", r"foo|bar|baz", r"foo|foobar", r"foobar|foo", r"foo|fo|f",
    r"f|fo|foo", r"a|a", r"foo|foo", r"ab|a|abc", r"abc|ab|a", r"|a", r"a|", r"a||b", r"(?:|)",
    r"foo|b.r", r"foo|\w", r"foo|[a-z]+", r"(?:a|b)(?:c|d)", r"(?:a|b)(?:c|d)(?:e|f)",
    r"(?:ab|cd)(?:ef|gh)", r"(?:a|bc)(?:d|ef)", r"Sherlock|Holmes|Watson|Irene|Adler|John|Baker",
    r"samwise|sam", r"sam|samwise", r"bar|foo|bar", r"(?:foo|bar)+", r"(?:foo|bar)*", r"(?:foo|)bar",
    r"(?:|foo)bar", r"a(?:b|c|d)e", r"zzz|zz|z", r"abc|abd|abe", r"xabc|yabc|zabc",
    r"foo1|foo2|foo3|foo4|foo5|foo6|foo7|foo8|foo9|foo10|foo11|foo12|foo13|foo14|foo15|foo16|foo17",
    r"abcdef|abcdeg|abcdeh", r"abcdefgh|abcdefgi", r"ab|ac|ad", r"qx|qy|qz", r"ea|eb|ec",
    r"Zab|Zcd", r"Zabcd|Zefgh", r"Za|Zb|Zc|Zd", r"Zab1|Zab2", r"ab1|ab2", r"ab12|ab13",
    r"a1|b2|c3|d4|e5|f6|g7|h8|i9|j10|k11|l12|m13|n14|o15|p16|q17|r18",
    # alternations exceeding limit_total (250)
    r"[a-j][a-j][a-j]", r"[a-j][a-j][a-j][a-j]", r"(?:[a-j][a-j][a-j])|foo", r"[a-j]{3}", r"[a-j]{2}x",
    r"(?:[a-e][a-e][a-e][a-e])", r"[a-e]{4}[a-e]", r"(?:[ab]{8})", r"(?:[ab]{7})", r"(?:[ab]{9})",
    r"(?:[a-c]{5})", r"(?:[a-c]{6})", r"(?:abc[a-j]{2}|xyz[a-j]{2}|[a-j]{2}qqq)",
    r"(?:\d\d\d)", r"(?:\d\d)(?:\d\d)", r"[0-9]{2}-[0-9]{2}", r"[a-c]{2}[a-c]{2}[a-c]{2}",
    "|".join("w%03d" % i for i in range(260)), "|".join("lit%dxyz" % i for i in range(130)),
    "|".join("%c%c" % (a, b) for a in "abcdefghijklmnop" for b in "abcdefghijklmnop"),
    "|".join("prefix_%d_long_literal" % i for i in range(300)),
    "|".join(chr(0x3b1 + i) * 3 for i in range(20)),
    # case insensitive
    r"(?i)a", r"(?i)foo", r"(?i)k", r"(?i)s", r"(?i)ß", r"(?i)σ", r"(?i)ǅ", r"(?i)foobar", r"(?i)abcdef",
    r"(?i)[a-c]", r"(?i)[a-e]", r"(?i)[a-f]", r"(?i)\w", r"(?i)foo|bar", r"(?i)sherlock", r"(?i)k+",
    r"(?i)(?:ab){3}", r"(?i)ab|cd", r"(?-u)(?i)k", r"(?i-u)foo", r"(?i)é", r"(?i)Σίσυφος", r"(?i:a)b",
    r"a(?i:b)c", r"(?i)ss", r"(?i)Ǆ", r"(?i)ﬀ", r"(?i)ſ", r"(?i)\u{212A}", r"(?i)[k-l]",
    # unicode / bytes
    r"\pL", r"\p{Lu}", r"\p{Han}", r"(?-u)\w", r"(?-u)[^a]", r"(?-u:[\x00-\x05])", r"(?-u:\xE6\x97\xA5)",
    r"日|本", r"日本|中文", r"[日本]", r"[日本語]+", r"é|e", r"(?-u:[a\xFF])", r"[\x{100}-\x{109}]",
    # anchors and word boundaries in context
    r"^foo|bar$", r"\bfoo|bar\b", r"^(?:foo|bar)$", r"\b(?:a|b)\b", r"(?m)^foo$", r"\Afoo\z",
    r"foo\b.*bar", r"^\w+$", r"^.*$", r"^$|foo",
    # poisonous / optimize_by_preference edge cases
    r"e", r"a|e", r"[ae]", r"t|e|a", r"e|xyz", r" ", r" |x", r"\n", r"Q", r"Q|J", r"[QJ]x",
    r"e.*", r"[ea]b+", r"(?:e|a)\w", r"xyz.*|abc.*", r"z+", r"Qa|Qb|Qc", r"Qab|Qac", r"Qabc|Qabd",
    r"Qabcd|Qabce", r"Qabcde|Qabcdf", r"eab|eac", r"xa|xb|xc|xd|xe|xf|xg|xh|xi|xj|xk",
    r"(?:abc|def|ghi|jkl|mno|pqr|stu|vwx|yz0|123|456|789)[0-9]+",
    r"(?:abcd|efgh|ijkl|mnop|qrst|uvwx|yzab|cdef|ghij|klmn|opqr|stuv|wxyz|ABCD|EFGH|IJKL|MNOP)",
    "|".join("%c%c%c%c%c%c" % (a, b, a, b, a, b) for a in "abcd" for b in "wxyz"),
    "|".join("%s.*" % w for w in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda"]),
    "|".join("m%dn" % i for i in range(70)), "|".join("mn%dop" % i for i in range(70)),
    "|".join("xy%02d" % i for i in range(65)), "|".join("xy%02d" % i for i in range(64)),
    "|".join("Jkl%02d" % i for i in range(20)), "|".join("jkl%02d" % i for i in range(20)),
    r"a\w|b\w|c\w|d\w|e\w|f\w|g\w|h\w|i\w|j\w|k\w",
    # rank boundaries: '9' ranks 200, 'v' 201, 'a' 249, 't' 251
    r"9x|9y", r"9xy|9xz", r"9xyz|9xyw", r"vx|vy", r"vxy|vxz", r"a|b", r"t|b", r"(?:9|v)\w", r"a\w|t\w", r"(?:ab|ac)(?:de|df)(?:gh|gi)(?:jk|jl)",
    # parse errors
    r"(", r"a{2,1}", r"[z-a]", r"\p{Nope}", r"(?<n>a)(?<n>b)", r"a**", r"\8",
]

ATOMS = list("abcxyzABCXYZ0123 _-.eQ") + ["é", "ß", "σ", "Σ", "K", "ſ", "日", "foo", "bar", "sherlock", "\\xFF", "(?-u:\\xFF)"]
CLASSES = ["[a-c]", "[^a ]", "[A-Z]", "[0-9]", "[[:alpha:]]", "[\\w-]", "[é-ü]", "[^\\s]",
           "[a-z&&[^aeiou]]", "\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\pL", "\\p{Greek}",
           "\\p{Lu}", "\\PL", ".", "(?-u:\\w)", "(?-u:.)", "[ab]", "[xyz]", "[a-j]", "[a-k]", "[0-4]",
           "[α-ε]", "(?-u:[\\x80-\\x85])"]
LOOKS = ["^", "$", "\\b", "\\B", "\\b{start}", "\\b{end}", "\\<", "\\>"]
QUANTS = ["*", "+", "?", "{2}", "{1,3}", "{2,}", "*?", "+?", "??", "{1,2}?", "{3}", "{0,1}", "{11}", "{0}"]
FLAGS = ["(?i)", "(?-i)", "(?u)", "(?-u)", "(?s)", "(?U)", "(?x)"]


def gen(r, depth=0):
    parts = []
    for _ in range(r.randint(1, 4)):
        k = r.random()
        if k < 0.40:
            a = r.choice(ATOMS)
            if a in ".-":
                a = "\\" + a
        elif k < 0.62:
            a = r.choice(CLASSES)
        elif k < 0.70:
            a = r.choice(LOOKS)
        elif k < 0.75:
            a = r.choice(FLAGS)
        elif depth < 2:
            inner = gen(r, depth + 1)
            for _ in range(r.choice([0, 1, 1, 2, 4])):
                inner += "|" + gen(r, depth + 1)
            a = r.choice(["(", "(?:", "(?i:", "(?<n%d>" % r.randint(0, 9999)]) + inner + ")"
        else:
            a = r.choice(ATOMS)
        if a not in FLAGS and (r.random() < 0.3 and a not in LOOKS and not a.startswith("(?") or (a.startswith("(") and r.random() < 0.3)):
            a += r.choice(QUANTS)
        parts.append(a)
    return "".join(parts)


def run(cmd, env=None, cwd=ROOT):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True)
    if r.returncode != 0:
        sys.stdout.write(r.stdout.decode(errors="replace"))
        sys.stdout.write(r.stderr.decode(errors="replace"))
        sys.exit("failed: " + " ".join(cmd))
    return r.stdout


def by_index(text):
    d = {}
    for line in text.splitlines():
        i, rest = line.split(" ", 1)
        d.setdefault(int(i), []).append(rest)
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=1500, help="random patterns")
    ap.add_argument("--seed", type=int, default=20261124)
    ap.add_argument("--hir", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--max-show", type=int, default=20)
    a = ap.parse_args()

    r = random.Random(a.seed)
    pats = list(HAND)
    seen = set(pats)
    while len(pats) < len(HAND) + a.n:
        p = gen(r)
        if p not in seen and "\n" not in p:
            seen.add(p)
            pats.append(p)
    os.makedirs(WORK, exist_ok=True)
    pat_path = os.path.join(WORK, "patterns.txt")
    out_path = os.path.join(WORK, "odin.txt")
    with open(pat_path, "w", encoding="utf-8", newline="\n") as f:
        for p in pats:
            f.write(p + "\n")

    run(["cargo", "build", "--release", "--offline", "--quiet"], cwd=ORACLE_DIR)
    rust = run([ORACLE_EXE] + (["--hir"] if a.hir else []) + [pat_path]).decode("utf-8")
    env = dict(os.environ, LITERAL_ORACLE_PATTERNS=pat_path, LITERAL_ORACLE_OUT=out_path)
    if os.path.exists(out_path):
        os.remove(out_path)
    run(["odin", "test", "src", "-collection:nvol=vendor/NVOL/generated", "-define:ODIN_TEST_NAMES=grepper.test_literal_oracle",
         "-out:" + os.path.join(WORK, "literal_test" + (".exe" if os.name == "nt" else ""))], env=env)
    with open(out_path, encoding="utf-8") as f:
        odin = f.read()
    rd, od = by_index(rust), by_index(odin)
    ok = 0
    bad = []
    for i, p in enumerate(pats):
        rl = [x for x in rd.get(i, []) if not x.startswith("HIR ")]
        if rl == od.get(i, []):
            ok += 1
        else:
            bad.append(i)
    for i in bad[:a.max_show]:
        print("pattern %d: %r" % (i, pats[i]))
        rl, ol = rd.get(i, []), od.get(i, [])
        for x in rl:
            if x.startswith("HIR "):
                print("  rust " + x)
        rl = [x for x in rl if not x.startswith("HIR ")]
        for k in range(max(len(rl), len(ol))):
            x = rl[k] if k < len(rl) else "<none>"
            y = ol[k] if k < len(ol) else "<none>"
            if x != y:
                print("  rust %s\n  odin %s" % (x, y))
    print("%d/%d patterns match regex-syntax" % (ok, len(pats)))
    if not a.keep and not bad:
        for p in (pat_path, out_path):
            os.remove(p)
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
