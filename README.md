# grepper

A recursive line-oriented search tool in [Odin](https://odin-lang.org): a port of
[ripgrep](https://github.com/BurntSushi/ripgrep) whose SIMD comes from
[NVOL](https://github.com/mirai-engine/NVOL), a generator of verified SIMD kernels.

**Status: pre-alpha.** The vertical MVP is done; the 1:1 port of ripgrep 14.1.1 is under way,
crate by crate. [docs/PARITY.md](docs/PARITY.md) lists every ripgrep flag and its status;
[docs/GLOSSARY.md](docs/GLOSSARY.md) describes every algorithm grepper runs.

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
| Port | ignore and globset: globs, file types, parent and global ignore files, sorting | done |
| Port | regex-syntax / regex-automata (lazy DFA, literal extraction, Unicode) | next |

`tests/compare.py` runs grepper and ripgrep on the same arguments and compares their output
and exit code byte for byte (timings aside), and stderr when ripgrep fails. Today all 216
cases match ripgrep 14.1.1.

### Speed

`tests/bench.py` reports wall time, best of 3, for both tools with their default threads. It
first checks that their sorted outputs are identical. The corpus is a tree of 30,415 files on
an i5-7400 under Windows 10:

| search | lines | grepper | ripgrep | ratio |
|---|---:|---:|---:|---:|
| literal, rare | 1 | 1.62 s | 2.36 s | 0.69 |
| literal, `-c` | 2878 | 1.70 s | 2.87 s | 0.59 |
| literal, `-l` | 416 | 1.66 s | 2.36 s | 0.70 |
| 8 literals (Teddy) | 66005 | 2.31 s | 2.81 s | 0.82 |
| regex with a literal | 38003 | 1.90 s | 2.62 s | 0.72 |
| regex, no literal | 8671 | 1.86 s | 2.67 s | 0.70 |
| regex, anchored | 9549 | 1.73 s | 2.70 s | 0.64 |

Since the ignore crate was ported whole (parent directories' and the global ignore files,
ripgrep's precedence between them), the walk does more work than the MVP's and grepper's
lead shrank from about 0.5 to 0.6-0.8 of ripgrep's time. grepper still walks on one thread;
ripgrep walks on all of them.

**Caveats:**
- This is a single machine and a single OS, and Linux has not been measured yet.
- grepper does less than ripgrep: no Unicode case folding yet (see the known differences).
- ripgrep prints a different number of lines across identical runs for files with a late
  NUL (ripgrep's tests/data/sherlock-nul.txt in this corpus), so the searches whose output
  includes such a file are compared and timed only when ripgrep's run agrees.

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
