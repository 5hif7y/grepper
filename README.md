# grepper

A recursive line-oriented search tool in [Odin](https://odin-lang.org): a port of
[ripgrep](https://github.com/BurntSushi/ripgrep) whose SIMD comes from
[NVOL](https://github.com/mirai-engine/NVOL), a generator of verified SIMD kernels.

**Status: pre-alpha.** The vertical MVP is done; the 1:1 port of ripgrep 14.1.1 is under way,
crate by crate. [docs/PARITY.md](docs/PARITY.md) lists every ripgrep flag and its status.

## Goal

The same results as ripgrep, and equal or better speed, measured, not assumed:
- **SIMD:** NVOL's kernels are already at parity with or ahead of the crates ripgrep uses
  (memchr, aho-corasick's Teddy, bstr), and give byte-identical results to them.
- **Everything else:** the SIMD is only about 1-10 % of ripgrep's time. The rest has to be
  ported and measured layer by layer:
  - the regex engine;
  - the parallel directory walk with gitignore rules;
  - the I/O strategy.

## Plan

| Stage | What | Status |
|---|---|---|
| MVP | literal search (NVOL memchr/memmem/Teddy) | done |
| MVP | recursive, parallel walk honouring `.gitignore`, `.ignore`, `.rgignore`, `.git/info/exclude`, hidden files | done |
| MVP | regex through Odin's `core:text/regex`, with NVOL as the literal prefilter | done |
| MVP | ripgrep's output format (headings, line numbers, colours, `-l`, `-c`, binary files) | done |
| Port | the command line (every flag, negation and alias), grep-searcher, grep-printer (standard, summary, JSON) | done |
| Port | ignore and globset: globs, file types, parent and global ignore files, sorting | next |
| Port | regex-syntax / regex-automata (lazy DFA, literal extraction, Unicode) | later |

`tests/compare.py` runs grepper and ripgrep on the same arguments and compares their output
and exit code byte for byte (timings aside). Today all 168 cases match ripgrep 14.1.1.

### Speed

`tests/bench.py` reports wall time, best of 3, for both tools with their default threads. It
first checks that their sorted outputs are identical. The corpus is a tree of 30,415 files on
an i5-7400 under Windows 10:

| search | lines | grepper | ripgrep | ratio |
|---|---:|---:|---:|---:|
| literal, common | 224507 | 1.51 s | 3.26 s | 0.46 |
| literal, rare | 1 | 1.56 s | 3.03 s | 0.51 |
| literal, `-c` | 2871 | 1.57 s | 2.81 s | 0.56 |
| literal, `-l` | 414 | 1.49 s | 2.70 s | 0.55 |
| regex with a literal | 38003 | 1.49 s | 3.12 s | 0.48 |
| regex, no literal | 8670 | 1.33 s | 2.72 s | 0.49 |
| regex, anchored | 9549 | 1.38 s | 2.78 s | 0.50 |
| `-i` (ASCII) | 2329 | 2.42 s | 2.92 s | 0.83 |

**Caveats:**
- This is a single machine and a single OS, and Linux has not been measured yet.
- grepper does less than ripgrep: no Unicode case folding yet (see the known differences).
- The 8-literal search is left out: ripgrep printed 0 or 8 lines of a file with a late NUL
  across identical runs.

See [docs/odin-findings.md](docs/odin-findings.md) for the Odin behaviours grepper works
around.

### Supported today

ripgrep's command line is parsed whole: every flag, negation and alias, with ripgrep's
messages, and `RIPGREP_CONFIG_PATH`. What grepper does not implement yet is refused with an
error naming the flag, never ignored; [docs/PARITY.md](docs/PARITY.md) has the list. Among
what works: context (`-A -B -C`, separators), `-v -m -q -o -b --column --vimgrep --passthru
--trim -M -0 --colors -p`, `-c --count-matches -l --files-without-match --include-zero`,
`--json`, `--stats`, `-f`, stdin, binary files (`-a`, `--binary`, `-uuu`) and memory-map
semantics.

### Known differences from ripgrep

- **`-i`, `\d \w \s`:** ASCII only. ripgrep's are Unicode. They come from the interim regex
  engine and are lifted by the regex-automata port.
- **Filters:** no `--glob`/`-g`, `--type`, `-w`/`-x`, `-r` or `-U` yet, and ignore files
  in parent directories and the global gitignore (`core.excludesFile`) are not read yet.

## Building

```sh
git clone --recurse-submodules git@github.com:5hif7y/grepper.git
cd grepper
odin build src -collection:nvol=vendor/NVOL/generated -o:speed -out:grepper
```

NVOL is a git submodule (`vendor/NVOL`). Its `generated/odin` package is committed there, so
grepper builds without Python.

## Agent sessions

[`skills/grepper`](skills/grepper/SKILL.md) is a skill for coding agents (Claude Code and
compatible harnesses). It tells an agent to search with grepper in place of grep and ripgrep.
Install it by copying the directory into the agent's skills directory (for Claude Code,
`~/.claude/skills/`).

## Origin and licence

grepper is a port of ripgrep by Andrew Gallant, which is dual-licensed under the Unlicense and
MIT. This port takes it under the Unlicense, and is licensed under the MIT licence
([LICENSE](LICENSE)). ripgrep remains the reference for grepper's behaviour.
