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
| multiline | `-U --multiline-dotall` | done (the regex runs on the PikeVM alone in this mode; the lazy DFA is for lines) |
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
| B6 | A root path that does not exist is reported in two forms depending on the thread count: walkdir's `IO error for operation on P:` with one thread, the bare OS message from the parallel walker | `rg -j1 -l alpha nope plain.txt` prints `rg: nope: IO error for operation on nope: The system cannot find the file specified. (os error 2)`, `-j4` prints `rg: nope: The system cannot find the file specified. (os error 2)`; rg 16.0.0 the same | not reported | already: grepper prints the one-thread form at any thread count |

### Fixed upstream after 14.1.1

From ripgrep's CHANGELOG (15.0.0 to 16.0.0), the fixes that touch what grepper ports. Each is
reproduced against rg 14.1.1 before it is fixed; one that does not reproduce on Windows is
recorded here as such.

| Upstream | Bug | Area | Status |
|---|---|---|---|
| #1332 #3001 | `rg -vf file` with an empty `file` should match every line | patterns | fixed, also under `-i`/`-S`, where 16.0.0 still prints nothing |
| regex #1354 (regex 1.13.1, regex-automata 0.4.18) | the reverse suffix (and reverse inner) search reports the first literal candidate it confirms, even when a match starting earlier ends at a later one: `rg -o '[a-c][^
]*xz|z'` on `a z xz` prints `z` twice, where the leftmost-first match is `a z xz` (rg 16.0.0 prints `a z xz`) | regex | fixed: both strategies are used only when regex-automata 0.4.18's proofs hold (`src/meta_prefix.odin`, `src/meta_reverse_inner.odin`, unit tests in `src/meta_prefix_test.odin`; regex's own 20 regression tests for them in `tests/regex_regression.py`: grepper 39/39 searches, rg 14.1.1 19/39); 0.4.18's proofs are conservative (rg 16.0.0 keeps `-U '[A-Z][a-z]+Error'` on the Core search, 1,458 ms on the 524 MiB file); grepper adds two of its own (P8: 376 ms, rg 14.1.1 407), checked by `tests/reverse_proof_fuzz.py` against rg 16.0.0 |
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
| #2094 #3076 | `-m` with `-U` shows too many matches | multiline | fixed in the multi line search only; upstream moved `-m` to the searcher in every mode (a6e0be3), which is where #3593, R16-1 and R16-2 came from, so line mode keeps 14.1.1's |
| #3180 | `-U` with `-r` panics | multiline | fixed (grepper's port panicked the same way) |
| #1983 #3364 | `--json` emits one match per multiline match block | multiline | fixed |
| #3503 | multi-line match discovery gives up past `MAX_LOOK_AHEAD` | multiline | todo, with `-P`: only a look-ahead regex (PCRE2) can match in the search and not in the printer's capped view; ripgrep's own test skips without PCRE2 |
| #3342 | compressed files detected by extension only, not by magic number | `-z` | todo, with `-z` |
| #3222 | decompression commands do not separate flags from paths | `-z` | todo, with `-z` |

### ripgrep 16.0.0 regressions grepper does not have

Found comparing the official 16.0.0 Windows build (`ripgrep-16.0.0-x86_64-pc-windows-msvc.zip`,
SHA-256 checked) with 14.1.1 and grepper. Written down here, not reported: issues and pull
requests go to other projects only once grepper and NVOL are finished (decided 2026-11-24).

| # | Bug | Reproduction | grepper |
|---|---|---|---|
| R16-1 | panic `assertion failed: start <= end` (crates/matcher/src/lib.rs:82), exit 127 | `printf 'a\nc\nfoox\nfoo\na\nc\nfoox\n' > h; rg -n -v -m1 -A3 foo h` (`-A2` and `-A1` do not panic); 25 of 500 random `-v -m -A` searches panicked | never panics (`tests/line_paths.py`) |
| R16-2 | the slow line path (a regex with `\A` or `\z`) and the fast one disagree under `-m` with context: past the limit the slow path prints lines as context, the fast path as matches | `printf '1\nx\n2\nx\n3\n' > v; rg -n -v -m2 -A2 x v` prints `5:3`, `rg -n -v -m2 -A2 '\Ax' v` prints `5-3`; 222 of 500 random pairs (`\Afoo`/`^foo`, `foo\z`/`foo$`) differ, 0 with 14.1.1 | both paths agree, as in 14.1.1 (`tests/line_paths.py`: 300/300 on seeds 1-3; 16.0.0 gives 187/300 on seed 1) |
| R16-3 | under `-U`, `-v -m1` prints every inverted line, not the first | `printf 'start
foo
bar baz
qux

foo bar
end
' > m; rg -U -v -n -m1 'foo
bar' m` prints lines 1, 4, 5, 6 and 7; 14.1.1 prints `1:start` | prints `1:start`, as 14.1.1 |

## Pending (regenerated 2026-11-25, after the Speed phase)

Every SIMD step is an NVOL kernel: written and tested in NVOL first (against its interpreter,
benchmarked against the crate it replaces), then used here. "NVOL: has" names a kernel NVOL
already ships; "NVOL: new" one to write there. The order is the order of work. Items finished
since the previous list are under "Done" at the end, with their commits.

### 1. Speed: beat rg on every row of `tests/bench.py`, and in `-U`

| # | Item | NVOL |
|---|---|---|
| P6 | **debt (2026-11-25, the maintainer's call: the host is busy with other work, so a full benchmark now would not be clean).** The full `tests/bench.py` again, Windows and Linux, on a quiet host (the last runs were noisy: rg itself moved 2x between runs), row by row against rg 14.1.1 and 16.0.0; a row slower than rg becomes an item of its own. Until then each speed item is measured by alternating builds and taking the minimum, its noise noted | none |
| P12b | the full dense DFA when no lazy DFA fits: rg 14.1.1 builds it for regexes of up to 1000 NFA states under its own 1 MiB limit, which `--dfa-size-limit` does not touch, so `--dfa-size-limit 1K -c '[a-z]+ [a-z]+'` over 50 MB takes 240 ms in rg and 1,192 in grepper (PikeVM). Only with a tiny `--dfa-size-limit`; default searches are level (P12) | none |
| P9 | the hang to watch: one Windows run of `-j8 -c -F return` over the Research-LLOG tree passed a 30 s timeout once in 30 runs (a66f938's stress test) and never again in 660 runs. `tests/stress_walk.py` (953f3fb) is the watch: run it after each change to the walk's stack (a deadlocked build is reported 3 hangs in 3 runs; on Linux it dumps every thread with gdb) | none |

### 2. Features of rg 14.1.1 still missing

| # | Item | Flags | NVOL |
|---|---|---|---|
| F1 | grapheme clusters for the preview of long lines | `--max-columns-preview` | none (Unicode tables, scalar) |
| F2 | encodings: BOM sniffing, UTF-16 to UTF-8, the WHATWG labels encoding_rs knows | `-E` | new: UTF-16 to UTF-8 transcoding; new: full UTF-8 validation (NVOL item 36, Keiser-Lemire, also for `--json`'s text check); has: `first_non_ascii` for the ASCII fast path |
| F3 | decompression through external tools, with #3342 (magic numbers) and #3222 (flags apart from paths) | `-z` | none |
| F4 | preprocessors | `--pre --pre-glob` | none |
| F5 | the regex size limit, and `--engine` | `--regex-size-limit --engine` | none |
| F6 | PCRE2's features on grepper's own engine (D1): look-around, backreferences, the PCRE syntax and its errors, with #3503 | `-P --pcre2-version` | new: whatever SIMD steps the ported features need |
| F7 | hyperlinks | `--hyperlink-format --hostname-bin` | none |
| F8 | skipping the file stdout is redirected to, with #3617 | | none |
| F9 | the `--debug` and `--trace` logs (they would also show the meta strategy chosen, which today needs a debug build) | `--debug --trace` | none |
| F10 | rg's exact help and version text, the man page and the completions | `-h --help -V --generate` | none |
| F11 | the flags rg added after 14.1.1, under grepper's own names (D2) | per flag | none |

### 3. rg bugs waiting on something (section 6)

| # | Bug | Waits on |
|---|---|---|
| W1 | #3609 | nothing now: the Linux runs exist (WSL Arch); to reproduce and fix |
| W2 | #2958 | a console harness (T3) |
| W3 | #2552, #3534 | nothing now on Linux (symlinks work there); still directory junctions on Windows |
| W4 | #3382 | a test that makes a read fail mid-search |
| W5 | B5 (relative `..` paths against `--ignore-file`) | a fix of grepper's own: rg 16.0.0 has it too |

### 4. Testing and platforms

| # | Item |
|---|---|
| T1 | `-L` and `--one-file-system` cases, on Linux where symlinks and mounts can be made (ported, untested) |
| T3 | a console harness for what rg does only on a terminal (#2958, colour defaults) |
| T4 | the fuzzers (`regex_fuzz.py`, `multiline_fuzz.py`, `line_paths.py`) over more seeds in one go, and patterns aimed at each meta strategy in `regex_fuzz.py` too (its `\z` patterns rarely reach a search that prints positions) |
| T5 | more of regex's own testdata through `tests/regex_regression.py`: the other strategies' regression tests, and the tests with options (match kind, Unicode off) that grepper can express as flags |
| T6 | `tests/linux_suite.sh` in the repository: the Linux run lives in a scratch script today (copy, build, every suite, the Odin unit test) |

### 5. Local notes for upstream (sent only when grepper and NVOL are finished)

| # | Project | Note |
|---|---|---|
| N1 | Odin | `os.open` on Linux fills `File.name` with readlink of `/proc/self/fd/N` on every open (`core/os/file_linux.odin`, `_new_file` -> `_get_full_path`): one syscall per file that a caller may never use (8,904 on `/usr/include`); grepper opens with `open(2)` itself (5243715) |
| N2 | Odin | `sync.cond_signal` makes a futex syscall on every call, waiters or not (`core/sync/primitives_atomic.odin`); grepper counts its waiters (a66f938) |
| N3 | ripgrep | B6 (the two forms of a missing root's error) and B2's race seen again (`-l alpha sub d1` loses `sub/deep/` in 41 of 100 runs at `-j4`) |

### 6. Decisions

| # | Question |
|---|---|
| D1 | **Decided 2026-11-24:** nothing external. PCRE2's features are ported onto grepper's own engine, and every SIMD step they need is written in NVOL; no C library is linked |
| D2 | **Decided 2026-11-24:** the flags rg added after 14.1.1 (`--in`, `-G/--glob-not`, `RIPGREP_THREADS`, `--max-bytes`, POSIX classes in globs, jj repositories, `GIT_CONFIG_GLOBAL`) are taken where useful, under names of grepper's own: generic where possible, and never naming grepper or ripgrep (an environment variable such as `RIPGREP_THREADS` gets a generic name). Each is decided when it is ported |

### Done since the list of 2026-11-24

| # | What | Commits |
|---|---|---|
| P2 | regex-automata's three reverse strategies, ported from 0.4.18 with regex 1.13.1's soundness proofs (rust-lang/regex#1354; ripgrep 14.1.1's versions report wrong matches: section 6). They find the literal with the forward prefilter and run only the DFA backwards, so P2 needed no reverse memmem from NVOL (the previous list said it did). ReverseAnchored (`\z`): `-U -c '[a-z]+\n\z'` 1412 -> 19 ms (rg 50), `-c '[a-z]+\z'` 1607 -> 713 (rg 948). ReverseSuffix: `-U -c '\s+Holmes'` 2105 -> 769 (rg 869, rg 16.0.0 811). ReverseInner: `-U -c '[a-z]+_parse_[a-z]+'` 1300 -> 307 (rg 337, rg 16.0.0 306). Also the fast line path under `-U` for a regex that cannot match a newline: `-U -c '[0-9]ms'` 392 -> 71 ms on Linux (rg 72) | fac79a4, dae29e5, f7250c8, 935bca6, 349c3c5 |
| P4 | `--dfa-size-limit`, parsed and ignored before: the lazy DFAs' cache in bytes (1000 MiB by default, as grep-regex), no lazy DFA below the minimum capacity, and regex-automata's give-up rule (3 clears, under 10 bytes searched per state). Default searches do not change (no cache was ever cleared on the 524 MiB file); `-U -c '\w+\s+Holmes\s+\w+'` at 64K 370 ms vs rg 491 | 2fc031c |
| P5a | capture groups resolved over the match's span only, as Core::search_slots: `-r X -o '(\w)(\w+)ing'` 245,378 -> 23,306 ms (rg 912; the rest is P10) | 38c9499 |
| P10 | Unicode classes compiled as regex-automata compresses them (Utf8Compiler forward, the suffix map in reverse): Unicode `\w` 3,261 -> 312 NFA states (upstream 283); `-r X -o '(\w)(\w+)ing'` on 524 MiB 19,706 -> 689 ms (rg 646), `-r '<$1>' 'Sherlock (\w+)'` 37,161 -> 2,076 (rg 2,253), `-c '\w{30}'` on 4 MiB 475 -> 51 (rg 118) | 293cdcc |
| P1 (part) | fixed strings through the meta strategy (`-F -c -f` 500 words over 300 s -> 2,252 ms, rg 1,485), and leftmost-first Aho-Corasick (5000 words 15,355 -> 2,422 ms, rg 1,848; `tests/aho_fuzz.py`) | 7400fc9, ce6613b |
| P1 | aho-corasick's contiguous NFA past 500 patterns (one u32 array, byte classes, sparse classes four to a u32): `-F -c -f` 5000 words on 524 MiB 2,716 -> 1,874 ms (rg 2,065; alternating builds, Windows) | 974f66f |
| P0 | closed without a change (2026-11-25): grepper already scans a mapped file as fast as rg or faster (524 MiB, Windows: `-F zq_never_here_7` 304 ms vs rg 333, `-c -F the` 521 vs 553, `[A-Z][a-z]+Error` 324 vs 347). Tried and rejected: PrefetchVirtualMemory over the whole view, +12 % on all three (342, 556, 362; warm cache, best of 5, builds alternating); posix_madvise SEQUENTIAL and WILLNEED on Linux, no change (43/42, 232/227, 53/54 ms) | none |
| P5 | the one-pass DFA for anchored capture searches, run first over the span the lazy DFAs found (`-r '$2 $1' '(\w+) (Holmes)'` on 524 MiB 2,924 -> 1,970 ms, rg 2,136) | 8b5abd4 |
| P12 | closed without a change (2026-11-25): rg 14.1.1 builds a full dense DFA for regexes of up to 1000 NFA states (`dfa_size_limit` 1 MiB) and prefers it to the lazy DFA; grepper's lazy DFA is level with it on every such pattern measured (524 MiB, Windows, best of 3: `-c '[a-z]{3}[0-9]'` 1342 vs rg 1404, `-c '(?-u)[0-9]+'` 910 vs 1015, `-c '(?-u)[a-z]+@[a-z]+\.[a-z]+'` 345 vs 479; `-c '(?-u)\w+\s+\w+'` and `-o '(?-u)\w+ing'` moved between 0.53x and 1.17x of rg across three reruns, host noise; over the Research-LLOG tree 0.46-0.62x of rg). A full DFA would only remove the lazy DFA's warm-up, which no row shows | none |
| P11 | the PikeVM laid out as regex-automata's (a slot table per NFA state, sparse scans that stop past the byte, 20-byte compact states), store forwarding stalls removed from its closure (Odin finding 9), and earliest searches stopped at the first match: `--dfa-size-limit 1K -c '\w{30}'` on 4 MiB, Linux 919 -> 354 ms (rg 303); 50 MB, Windows 9,126 -> ~4,250 (rg ~3,850); `-c '\w+ing'` 271 -> 191 (rg 190). New checks: `test_pike_slots` (PikeVM against the backtracker, slot for slot) and `regex_fuzz.py --no-lazy-dfa` | 875abfc, 181935e, 430eced, f2c0c44 |
| P8 | two reverse suffix proofs past regex 1.13.1's: the first consuming child of the prefix takes exactly one byte and nothing after it can consume the literal's first byte (an earlier match would have the first candidate inside its prefix part, past its first byte), and trailing looks dropped before stripping. `-U -c '[A-Z][a-z]+Error'` on 524 MiB 1,394 -> 376 ms (rg 14.1.1 407 through its unsound strategy, rg 16.0.0 1,458); `[A-Z][a-z]+Error` 1,425 -> 384. `tests/reverse_proof_fuzz.py` searches for counterexamples against rg 16.0.0 (rg 14.1.1 fails it 35-37 times in 400; a proof accepting everything 1-4 times; these proofs pass 26 seeds, 10,400 patterns) | a5d3593, 76b712e |
| survey | 25 patterns against rg on the 524 MiB file (2026-11-25): grepper ahead or level on 21. The 20x gap found (`-c 'Holmes.{0,40}Watson'` 12,428 ms vs rg 779) was the lazy DFA's table growing a row at a time with Odin's `resize`, quadratic on Windows: doubled, 718 ms (9196575; Odin finding 8) | 9196575 |
| P9 | `tests/stress_walk.py`, the watch for P9's hang | 953f3fb |
| P3 | accelerated lazy DFA states: `^\s*$` 1686 -> 770 ms on the 523 MiB file (rg ~820) | earlier |
| P4 (part) | the lazy DFA in multi line mode: `-U -c 'fn\s+\w+\s*\('` 110670 -> 452 ms (rg 501) | earlier |
| P5 (part) | the bounded backtracker, and positions from the lazy DFAs as Core::search finds them: `-o -i '[a-z]+ing\b'` 2444 -> 474 ms (rg 552) | earlier |
| P0 (part) | memory maps where rg maps, 64 KiB reads otherwise: `-l` on one 523 MiB file 240 -> 18 ms (rg 44) | earlier |
| P6/P7 | the walk on Linux: readdir without a stat per entry, a parallel walk with every entry on a shared stack (files too, as WalkParallel), files searched on the thread that finds them, stdout streamed on one thread, no readlink per open, no clock read per file without `--stats`, the stack signalled only when a thread waits. 15 alternating runs: grepper's minimum below rg's on every tree row tried (`/usr/share -j1 -F zq_never_here_7` 202 ms vs rg 276; 4 threads 87 vs 104). Two bugs found on the way and fixed: `.gitignore` rules lost at `-j4` (a freed path), and given files not searched at `-j>1` (abca4f8) | d46589c, 75c4fd7, 6cbd6ff, abca4f8, 051ac86, 5243715, 12ebf93, a66f938 |
| T2 | the whole suite and the benchmark on Linux (WSL Arch, rg 14.1.1 built with PCRE2) | runs with each commit since d46589c |
