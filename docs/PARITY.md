# Feature parity with ripgrep 14.1.1

Every flag and behaviour of ripgrep 14.1.1, and where grepper stands on it. A row is done only
when `tests/compare.py` has cases for it that match ripgrep byte for byte (stdout and exit code).

The exception is ripgrep's own bugs (section 6): grepper fixes them instead of copying them. A
fixed bug's case carries the expected output, and the test also runs rg 14.1.1 and reports
whether it still shows the bug, so the difference stays documented.

SIMD rule: every vectorised step is an NVOL kernel. Where ripgrep's dependencies use SIMD that
NVOL lacks, the kernel is written in NVOL first (with its tests against NVOL's interpreter and
its benchmark against the crate it replaces), then used here.

Speed: grepper is meant to beat ripgrep on every row of `tests/bench.py`, not to tie it.
NVOL is grepper's own SIMD, so a slow row is fixed in NVOL (a new or better kernel) or in
how grepper uses it, never accepted as a limit of a dependency.

Status: `done`, `partial` (what is missing is said), `todo`.

## 1. Searcher and standard printer (grep-searcher, grep-printer)

| Feature | Flags | Status |
|---|---|---|
| line numbers, headings, filenames, colours | `-n -N -H -I --heading --no-heading --color` | done |
| count, files with matches | `-c -l` | done |
| binary files: quit when walked, note when explicit | | done |
| context lines and separators | `-A -B -C --context-separator --no-context-separator` | done |
| invert match | `-v` | done |
| max count | `-m` | done |
| print every line | `--passthru` | done |
| quiet | `-q` | done |
| byte offset, column | `-b --column` | done |
| only matching | `-o` | done |
| vim format | `--vimgrep` | done |
| replacement, with `$1 ${name}` captures | `-r` | done (standard printer; `--json` ignores it, as 14.1.1) |
| count every match, files without a match, zero counts | `--count-matches --files-without-match --include-zero` | done |
| NUL after paths, path separator | `-0 --path-separator` | done |
| field separators | `--field-match-separator --field-context-separator` | done |
| long lines | `-M --max-columns-preview` | partial: `--max-columns-preview` needs grapheme clusters |
| trim leading whitespace | `--trim` | done |
| colour specs | `--colors` | done |
| pretty | `-p` | done |
| buffering | `--line-buffered --block-buffered` | done: accepted; grepper writes each file's output whole |
| statistics | `--stats` | done |
| JSON Lines output (base64 for invalid UTF-8) | `--json` | done |
| hyperlinks | `--hyperlink-format --hostname-bin` | todo |
| stdin when no path and stdin is not a terminal; `-` as a path | | done |
| search binary files | `--binary -a` | done |
| line terminators | `--crlf --null-data` | done |
| stop on the first non-matching line after a match | `--stop-on-nonmatch` | done |
| memory maps | `--mmap --no-mmap` | done |

## 2. Regex (regex-syntax, regex-automata)

| Feature | Flags | Status |
|---|---|---|
| ripgrep's regex syntax, parsed by a port of regex-syntax (errors as ripgrep's) | | done |
| Unicode classes, `\p{..}`, Unicode `\d \w \s \b`, simple case folding | | done |
| case modes | `-i -s -S` | done |
| word and line patterns | `-w -x` | done |
| multiline | `-U --multiline-dotall` | todo |
| no Unicode | `--no-unicode` | done |
| patterns from a file | `-f` | done |
| literal extraction (prefixes, inner, suffixes) feeding NVOL prefilters | | partial: patterns that are only literals go to NVOL memmem or Teddy; a regex has no prefilter yet |
| engines: lazy DFA, PikeVM, bounded backtracker, one-pass | `--engine --dfa-size-limit --regex-size-limit` | partial: lazy DFA and PikeVM; the size limits are parsed and not applied; `--engine` is refused |
| PCRE2 | `-P --pcre2-version` | todo: ripgrep links PCRE2 (C); decide later |

## 3. Walk and filters (ignore, globset)

| Feature | Flags | Status |
|---|---|---|
| `.gitignore`, `.ignore`, `.rgignore`, `.git/info/exclude`, hidden files (the Windows hidden attribute too) | `--hidden --no-ignore` | done |
| skipping the file stdout is redirected to | | todo |
| glob overrides, case-insensitive | `-g --iglob --glob-case-insensitive` | done |
| file types (ripgrep's default table) | `-t -T --type-add --type-clear --type-list` | done |
| the ignore toggles | `--no-ignore-dot -exclude -files -global -parent -vcs --no-require-git` | done |
| global gitignore (`core.excludesFile`), parent directories' ignore files | | done |
| extra ignore files | `--ignore-file --ignore-file-case-insensitive` | done |
| unrestricted | `-u -uu -uuu` | done |
| depth, size, symlinks, one file system | `-d --max-filesize -L --one-file-system` | partial: `-L` and `--one-file-system` are ported but have no test (symlinks need privileges on Windows) |
| sorting | `--sort --sortr --sort-files` | done |
| file listing | `--files` | done |

## 4. Input (encoding, decompression, preprocessors)

| Feature | Flags | Status |
|---|---|---|
| BOM sniffing, UTF-16 transcoding, explicit encodings | `-E` | todo; needs an NVOL UTF-16 to UTF-8 kernel |
| decompression through external tools | `-z` | todo |
| preprocessors | `--pre --pre-glob` | todo |

## 5. Command line and configuration

| Feature | Flags | Status |
|---|---|---|
| short flags combined, attached values | | done |
| every `--no-` negation ripgrep accepts | | done |
| configuration file | `RIPGREP_CONFIG_PATH --no-config` | done |
| messages | `--no-messages --no-ignore-messages --debug --trace` | partial: `--no-messages`; the others are accepted and log nothing |
| help, version, man page and completions | `-h --help -V --generate` | partial: grepper's own help and version text |
| threads | `-j` | done |

## 6. ripgrep 14.1.1 bugs that grepper fixes

Status: `todo`, `fixed` (with its case in `tests/compare.py`), `already` (grepper never had it).

### Found during the port

Each one reproduced with rg 14.1.1 on Windows.

| # | Bug | Reproduction | Upstream | Status |
|---|---|---|---|---|
| B1 | `\p{name!=value}` matches as `\p{name=value}`: regex-syntax 0.8.4's translator reads the class's `negated` field instead of `is_negated()` | `printf 'alpha \xce\xb1\xce\xb2\n' \| rg -o '\p{sc!=Greek}+'` prints `αβ` | fixed in regex-syntax 0.8.12 (`is_negated()`) | fixed |
| B2 | Parent-directory ignore rules with several roots depend on root order and thread scheduling: the cached ancestor nodes keep the `absolute_base` of the root that built them | in `tests/fixtures/tree` (`.gitignore` has `docs/**/draft*`), `rg -l alpha src docs` prints `docs\a\b\draft1.md` in 6 of 8 runs; with `-j1` in 8 of 8; `rg -l alpha docs` in 0 of 8 | 15.2.0, BUG #3320 #3376 #3419 | fixed |
| B3 | Parent-directory ignore rules miss paths below the root: the path is made absolute after stripping the matching node's directory, not the root's, so the directories between them are lost | a git repo with `.gitignore` = `docs/a/b/draft*`: `rg -l alpha docs` prints `docs\a\b\draft1.md`, which `git check-ignore` ignores | 15.0.0, BUG #829 #2731 #2747 #2770 #2778 #2836 #2933 #3067 | fixed |
| B4 | A NUL past the first 64 KiB fill: which lines print before the binary cut depends on how many bytes each read returns | three identical runs of an 8-literal search over the Research-LLOG tree printed 0, 8 and 8 lines of `ripgrep/tests/data/sherlock-nul.txt` (NUL at 77041) | not reported | already: grepper models full reads and prints the same lines every run |
| B5 | `--ignore-file` and global gitignore patterns anchored at the working directory miss a search path given with `..` | from `a/b/c`, with `/haystack` in the ignore file, `rg --files --ignore-file F ../../..` lists `../../../a/b/c/haystack` (rg 16.0.0 too); with the absolute path, 16.0.0 ignores it | not fixed upstream | todo |

### Fixed upstream after 14.1.1

From ripgrep's CHANGELOG (15.0.0 to 16.0.0), the fixes that touch what grepper ports. Each is
reproduced against rg 14.1.1 before it is fixed; one that does not reproduce on Windows is
recorded here as such.

| Upstream | Bug | Area | Status |
|---|---|---|---|
| #1332 #3001 | `rg -vf file` with an empty `file` should match every line | patterns | fixed, also under `-i`/`-S`, where 16.0.0 still prints nothing |
| #2177 | a UTF-8 BOM at the start of `.gitignore` (and the other ignore files) is part of the first pattern | ignore | fixed |
| #2944 | `--stats` "bytes searched" can be wrong | printer | fixed |
| #2990 | globs ending in `.` are mishandled | globset | fixed |
| #3100 | `-r` drops line terminators | replace | fixed |
| #3108 | `-q --files-without-match` inverts the exit code | exit codes | fixed |
| #3173 | ancestor ignore filter wrong for whitelisted hidden files | ignore | fixed with B3 (the `.` root case is part of that code); on Windows 14.1.1 does not show it, since prefixes are stripped by components |
| #3178 | `--json` summary statistics wrong | printer | fixed |
| #3179 | absolute paths with a global gitignore | ignore | fixed (`--ignore-file` and the global gitignore) |
| #3593 | `-v -m N -A k` prints the rest of the input as matches | searcher | does not apply: 14.1.1 prints the issue's case right (`1:a 2:b 3-foo`); the bug came with 15.x. `tests/line_paths.py` holds grepper to the behaviour the issue expects |
| #3581 #1764 | `-g !DIRNAME/` does not match when the working directory is `DIRNAME` | globs | fixed |
| #3605 #3604 | an ignore file stops being read at an invalid UTF-8 line | ignore | already: grepper reads the lines after it, with no message, as 16.0.0 |
| #3527 | a lone `!` line in a gitignore is not a no-op | ignore | fixed |
| #3477 | trailing spaces in gitignore patterns are parsed wrongly | ignore | fixed |
| #2745 | glob character classes match the path separator | globset | fixed |
| #3609 #3603 | partial path components accepted when stripping prefixes | paths | todo: Unix only (Windows strips by components), to reproduce on Linux |
| #2958 | control codes in paths are printed raw | printer | todo: only when stdout or stderr is a terminal, which compare.py cannot see; needs a console harness |
| #3484 | Scheme files are part of the Lisp type | types | fixed: 14.1.1's table with only this change (types added after 14.1.1 are not taken) |
| #2552 | `-L` reports broken symlinks that are ignored | walk | todo: this account cannot create symlinks (WinError 1314); to try with junctions or on Linux |
| #3534 | symlink loops above the search root are not detected | walk | todo: as #2552 |
| #3382 | buffered matches lost after an error in a parallel search | walk | todo: needs a read that fails mid-search |
| #3617 | on Windows, stdout that is a pipe is compared against the searched files | walk | todo, with the stdout check |
| #2094 #3076 | `-m` with `-U` shows too many matches | multiline | todo, with `-U` |
| #3180 | `-U` with `-r` panics | multiline | todo, with `-U` |
| #1983 #3364 | `--json` emits one match per multiline match block | multiline | todo, with `-U` |
| #3503 | multi-line match discovery gives up past `MAX_LOOK_AHEAD` | multiline | todo, with `-U` |
| #3342 | compressed files detected by extension only, not by magic number | `-z` | todo, with `-z` |
| #3222 | decompression commands do not separate flags from paths | `-z` | todo, with `-z` |

### ripgrep 16.0.0 regressions grepper does not have

Found comparing the official 16.0.0 Windows build (`ripgrep-16.0.0-x86_64-pc-windows-msvc.zip`,
SHA-256 checked) with 14.1.1 and grepper. Kept here, not reported: no report goes to another
project until NVOL and grepper are mature (decided 2026-11-24, after Odin declined #8551 as a
design choice; NVOL's docs/TOOLCHAINS.md, T3).

| # | Bug | Reproduction | grepper |
|---|---|---|---|
| R16-1 | panic `assertion failed: start <= end` (crates/matcher/src/lib.rs:82), exit 127 | `printf 'a\nc\nfoox\nfoo\na\nc\nfoox\n' > h; rg -n -v -m1 -A3 foo h` (`-A2` and `-A1` do not panic); 25 of 500 random `-v -m -A` searches panicked | never panics (`tests/line_paths.py`) |
| R16-2 | the slow line path (a regex with `\A` or `\z`) and the fast one disagree under `-m` with context: past the limit the slow path prints lines as context, the fast path as matches | `printf '1\nx\n2\nx\n3\n' > v; rg -n -v -m2 -A2 x v` prints `5:3`, `rg -n -v -m2 -A2 '\Ax' v` prints `5-3`; 222 of 500 random pairs (`\Afoo`/`^foo`, `foo\z`/`foo$`) differ, 0 with 14.1.1 | both paths agree, as in 14.1.1 (`tests/line_paths.py`: 300/300 on seeds 1-3; 16.0.0 gives 187/300 on seed 1) |

## NVOL work this port needs

- **Reverse memmem** (`memchr::memmem::FinderRev`): regex-automata's reverse-suffix and
  reverse-inner strategies. NVOL PENDING item 40.
- **UTF-16 to UTF-8 transcoding** (encoding_rs's SIMD paths): `-E` and BOM sniffing.
- **Prefilter choice as regex-automata's**: memchr, memchr2, memchr3, memmem, Teddy, and
  Rabin-Karp for sets Teddy refuses. NVOL has the first five.

## Order

1. Searcher and standard printer (section 1), on the interim regex engine.
2. Walk and filters (section 3).
3. The regex-automata port (section 2), which `-w`, `-x`, Unicode, `-U` and `-r` captures wait
   on.
4. Input (section 4) and the NVOL kernels it needs.
5. Command line and configuration (section 5).

The bugs of section 6 are fixed alongside: the ones in parts already ported first (B1-B3 and
the upstream rows without a "with" note), each later one together with the feature it names.
