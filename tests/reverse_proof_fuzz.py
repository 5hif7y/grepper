#!/usr/bin/env python3
# Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
"""A counterexample search for the reverse strategies' proofs, against ripgrep 16.0.0.

ripgrep 14.1.1's reverse suffix and reverse inner searches can report a later match than the
leftmost-first one (rust-lang/regex#1354), so the reference here is rg 16.0.0, whose
regex-automata (0.4.18 and later) only takes those strategies when a proof says the literal
candidates come in the order of the matches. grepper's proofs go further (docs/PARITY.md, P8);
this search is where a wrong proof would show.

Patterns sit on the proofs' edges: a prefix of classes, repetitions, inner alternations of
different lengths and optional groups, over a small alphabet that shares bytes with the
literal; the literal; sometimes a trailing look; sometimes a top-level alternation with a
short branch (the shape of #1354). Each pattern comes with a sampler of the strings its parts
match, and the haystacks are made of those samples (whole matches, prefix parts alone, the
literal, the short branch) and noise, so a match that starts earlier and ends at a later
candidate is likely to be there. Each is searched with -o -b (every match and its offset),
with -U or without; stdout and exit code must equal rg 16.0.0's.

usage: python tests/reverse_proof_fuzz.py [--seed N] [-n N] [--grepper PATH] [--rg16 PATH]
"""
import argparse
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ALPHABET = "aAbcEXxz! \t\n0"
# each class, and the haystack bytes it matches
CLASSES = {
    "[A-Z]": "AEX", "[a-z]": "abcxz", "[a-c]": "abc", "[A-Ca-c]": "Aabc", "[^a]": "AbcEXxz! \t0",
    "[^\\n]": "aAbcEXxz! \t0", "\\w": "aAbcEXxz0", "\\s": " \t\n", "[a-zE]": "abcxzE",
    "[EX]": "EX", "[ \\t]": " \t", "\\d": "0", "[xE ]": "xE ", "[a-wyz]": "abcz", "[ac-z]": "acxz",
}
# repetition suffix -> (min, max) of the sampler
REPS = [("", 1, 1), ("", 1, 1), ("+", 1, 3), ("*", 0, 3), ("?", 0, 1), ("{1,3}", 1, 3), ("{2}", 2, 2), ("+?", 1, 3)]
LITERALS = ["Error", "EE", "aba", "xz", "Ex", "abab", " E", "zz", "aEa", "b", "E", "z"]
TAILS = ["", "", "", "\\b", "\\B", "$", "(?m:$)"]


def esc(c):
    return {"\t": "\\t", "\n": "\\n", " ": " "}.get(c, c)


class Node:
    """A pattern fragment and a sampler of the strings it matches."""

    def __init__(self, text, sample):
        self.text, self.sample = text, sample


def lit_node(s):
    return Node("".join(esc(c) for c in s), lambda rnd: s)


def class_node(rnd):
    name = rnd.choice(list(CLASSES))
    chars = CLASSES[name]
    return Node(name, lambda r: r.choice(chars))


def rep_node(rnd, sub):
    suffix, lo, hi = rnd.choice(REPS)
    if suffix == "":
        return sub
    text = sub.text if len(sub.text) == 1 or sub.text.startswith("[") or sub.text.startswith("\\") else "(?:" + sub.text + ")"
    return Node(text + suffix, lambda r: "".join(sub.sample(r) for _ in range(r.randint(lo, hi))))


def concat(nodes):
    return Node("".join(n.text for n in nodes), lambda r: "".join(n.sample(r) for n in nodes))


def piece(rnd, lit):
    nodes = []
    for _ in range(rnd.randint(1, 3)):
        n = class_node(rnd) if rnd.random() < 0.6 else lit_node(rnd.choice([lit[0], lit[-1], "a", "x"]))
        if rnd.random() < 0.3:
            k = rnd.choice([2, 3])
            n = Node(n.text + "{%d}" % k, (lambda m, kk: lambda r: "".join(m.sample(r) for _ in range(kk)))(n, k))
        nodes.append(n)
    return concat(nodes)


def atom(rnd, lit):
    k = rnd.random()
    if k < 0.2:
        # an inner alternation with branches of different lengths, the shape of regex's
        # reverse-suffix-start-of-match-failure tests ('(?:[a-z]cb|c)[a-z]*b')
        a, b = piece(rnd, lit), piece(rnd, lit)
        return Node("(?:" + a.text + "|" + b.text + ")", lambda r: r.choice([a, b]).sample(r))
    if k < 0.3:
        a = piece(rnd, lit)
        return Node("(?:" + a.text + ")?", lambda r: a.sample(r) if r.random() < 0.6 else "")
    if k < 0.4:
        return lit_node(rnd.choice(["x", "E", "a"]))
    return rep_node(rnd, class_node(rnd))


def gen(rnd):
    lit = rnd.choice(LITERALS)
    parts = [atom(rnd, lit) for _ in range(rnd.randint(1, 4))]
    if rnd.random() < 0.15:
        parts[0] = Node("(" + parts[0].text + ")", parts[0].sample)
    prefix = concat(parts)
    whole = concat([prefix, lit_node(lit)])
    samples = [whole, whole, prefix, lit_node(lit)]
    if rnd.random() < 0.35:
        # a top-level alternation whose branches share the literal's end, the shape of
        # rust-lang/regex#1354 ('[a-c][^\n]*xz|z')
        cut = rnd.randint(0, len(lit) - 1)
        short = concat(([class_node(rnd)] if rnd.random() < 0.5 else []) + [lit_node(lit[cut:])])
        if rnd.random() < 0.5:
            lead = rnd.choice([("[^\\n]*", "aAbcEXxz! \t0"), ("[a-zE ]*", "abcxzE "), (".*", "aAbcEXxz! \t0")])
            chars = lead[1]
            whole = concat([Node(lead[0], lambda r: "".join(r.choice(chars) for _ in range(r.randint(0, 4)))), whole])
        text = whole.text + "|" + short.text if rnd.random() < 0.6 else short.text + "|" + whole.text
        samples = [whole, short, prefix, lit_node(lit)]
    else:
        text = whole.text
    text += rnd.choice(TAILS)

    def haystack(r):
        out = []
        for _ in range(r.randint(2, 12)):
            if r.random() < 0.75:
                out.append(r.choice(samples).sample(r))
            else:
                out.append("".join(r.choice(ALPHABET) for _ in range(r.randint(1, 3))))
        return "".join(out) + "\n"
    return text, haystack


def main():
    sys.stdout.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--grepper", default=os.path.join(ROOT, "grepper.exe" if os.name == "nt" else "grepper"))
    ap.add_argument("--rg16", default=os.environ.get("RG16"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-n", type=int, default=400)
    a = ap.parse_args()
    if not a.rg16:
        print("rg 16.0.0 is needed: --rg16 PATH or RG16")
        return 2
    rnd = random.Random(a.seed)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        hay_path = os.path.join(tmp, "hay.txt")
        for k in range(a.n):
            pat, haystack = gen(rnd)
            with open(hay_path, "w", newline="\n") as f:
                for _ in range(rnd.randint(1, 6)):
                    f.write(haystack(rnd))
            args = ["-U", "-o", "-b", "-e", pat, hay_path]
            if rnd.random() < 0.3:
                args = ["-o", "-b", "-e", pat, hay_path]
            outs = []
            for exe in (a.rg16, a.grepper):
                r = subprocess.run([exe, *args], capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                outs.append((r.returncode, r.stdout))
            if outs[0] != outs[1]:
                bad += 1
                print(f"DIFF run {k}: {' '.join(args[:-1])!r}")
                with open(hay_path, "rb") as f:
                    print(f"  haystack {f.read()[:200]!r}")
                g, r_ = outs[1][1].splitlines(), outs[0][1].splitlines()
                for i, (x, y) in enumerate(zip(r_, g)):
                    if x != y:
                        print(f"  line {i}: rg16 {x!r} grepper {y!r}")
                        break
                else:
                    print(f"  rg16 {len(r_)} lines rc {outs[0][0]}, grepper {len(g)} lines rc {outs[1][0]}")
    print(f"{a.n - bad}/{a.n} reverse strategy patterns match rg 16.0.0 (seed {a.seed})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
