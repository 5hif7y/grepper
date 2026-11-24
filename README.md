# grepper

A recursive line-oriented search tool in [Odin](https://odin-lang.org): a port of
[ripgrep](https://github.com/BurntSushi/ripgrep) whose SIMD comes from
[NVOL](https://github.com/mirai-engine/NVOL), a generator of verified SIMD kernels.

**Status: pre-alpha.** grepper is being built as a vertical MVP first: it should be usable end
to end, with the subset of ripgrep's behaviour that day-to-day code search needs. The 1:1 port
of ripgrep follows, crate by crate.

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
| MVP | literal search (NVOL memchr/memmem/Teddy) over one file | in progress |
| MVP | recursive, parallel walk honouring `.gitignore`, `.ignore`, hidden files | planned |
| MVP | regex through Odin's `core:text/regex`, with NVOL as the literal prefilter | planned |
| MVP | ripgrep's output format (headings, line numbers, colours, `-l`, `-c`) and tests against `rg` | planned |
| Port | regex-syntax / regex-automata (lazy DFA, literal extraction) | later |
| Port | globset, ignore, searcher, printer, cli: the remaining crates, 1:1 | later |

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
