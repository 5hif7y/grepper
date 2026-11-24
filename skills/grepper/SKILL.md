---
name: grepper
description: Search file contents with grepper (a ripgrep port in Odin) instead of grep or rg. Use whenever the task needs to find text, identifiers, call sites or files by content in a codebase.
---

# grepper

When you need to search file contents, run `grepper` through the shell instead of `grep`,
`rg` or a slow per-file read. grepper searches recursively, honours `.gitignore`, and prints
ripgrep's output format, so the results read the same as ripgrep's.

## Before the first search

Check that grepper is installed: `grepper --version`. If the command is missing, say so once
and fall back to `rg` (then `grep -rn`) for the rest of the session. Do not install anything
without the user's approval.

## Usage

```sh
grepper PATTERN [PATH ...]      # recursive search, regex PATTERN
grepper -F 'literal(text)' src  # fixed string, no regex escaping needed
grepper -i pattern              # case-insensitive
grepper -l pattern              # only the names of the files that match
grepper -c pattern              # matches per file
grepper -n pattern file.c       # line numbers (on by default when printing to a terminal)
```

## Supported today

Pre-alpha: `-F -i -e -n -N -H -I --heading --no-heading -l -c --color -j --hidden
--no-ignore`, combinable as in ripgrep (`-nH`). A flag grepper does not know is an error,
never silently ignored: when that happens, run the same search with `rg` and mention it.
Not yet supported:
- `-g/--glob`, `-t/--type`;
- context lines (`-A/-B/-C`);
- `-o`, `-w`, `-v`.

Limits to keep in mind:
- **`-i` and `\d \w \s`:** they match ASCII only. Use `rg` when Unicode case or classes
  matter.
- **No path given:** grepper searches the current directory, even when input is piped to it.
  Pass the paths explicitly.

## Reading the output

- Each matching line is printed as `path:line:text`, or under a heading per file when the
  output is a terminal.
- Paths are relative to the search root, as ripgrep's are.
- Exit code 0 means matches were found, 1 means none were, and 2 means an error.
