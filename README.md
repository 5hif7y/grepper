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
| MVP | literal search (NVOL memchr/memmem/Teddy) | done |
| MVP | recursive, parallel walk honouring `.gitignore`, `.ignore`, `.rgignore`, `.git/info/exclude`, hidden files | done |
| MVP | regex through Odin's `core:text/regex`, with NVOL as the literal prefilter | done |
| MVP | ripgrep's output format (headings, line numbers, colours, `-l`, `-c`, binary files) | done |
| Port | regex-syntax / regex-automata (lazy DFA, literal extraction, Unicode) | next |
| Port | globset, ignore, searcher, printer, cli: the remaining crates, 1:1 | later |

`tests/compare.py` runs grepper and ripgrep on the same arguments and compares their output
and exit code byte for byte. Today all 66 cases match ripgrep 14.1.1.

### Supported today

`-F -i -e -n -N -H -I --heading --no-heading -l -c --color -j --hidden --no-ignore`; short
flags combine and take attached values (`-nH`, `-j1`), as in ripgrep. Any other flag is an
error, never ignored.

### Known differences from ripgrep

- **`-i`, `\d \w \s`:** ASCII only. ripgrep's are Unicode. They come from the interim regex
  engine and are lifted by the regex-automata port.
- **stdin:** with no path, grepper searches the current directory. ripgrep searches stdin when
  it is not a terminal.
- **Configuration and filters:** no `--glob`/`-g`, `--type`, context lines (`-A/-B/-C`), `-o`,
  `-w`, `-v`, replacement or JSON output yet, and no global gitignore (`core.excludesFile`).

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
