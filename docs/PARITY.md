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
]*xz|z'` on `a z xz` prints `z` twice, where the leftmost-first match is `a z xz` (rg 16.0.0 prints `a z xz`) | regex | fixed: the strategy is used only when regex-automata 0.4.18's proofs hold (`src/meta_prefix.odin`, its unit tests in `src/meta_prefix_test.odin`); like 0.4.18 they are conservative, so `-U '[A-Z][a-z]+Error'` keeps the Core search (rg 14.1.1 800 ms, rg 16.0.0 1684 ms, grepper 1547 ms on the 524 MiB file) |
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

## Pending (regenerated 2026-11-24)

Every SIMD step is an NVOL kernel: written and tested in NVOL first (against its interpreter,
benchmarked against the crate it replaces), then used here. "NVOL: has" names a kernel NVOL
already ships; "NVOL: new" one to write there. The order is the order of work.

### 1. Speed: beat rg on every row of `tests/bench.py`

| # | Item | NVOL |
|---|---|---|
| P1 | literal extraction for regexes (regex-syntax's `Extractor`: prefixes, suffixes, inner literals) and regex-automata's prefilter choice, so a regex with a literal is searched by a literal kernel first | has: memchr, memchr2, memchr3, memmem, Teddy; new: Rabin-Karp for sets Teddy refuses (scalar, kept in NVOL with the rest of the family) |
| P2 | the reverse-suffix and reverse-inner strategies (a literal found, then the regex run backwards from it) | new: reverse memmem (NVOL PENDING item 40) |
| P3 | accelerated DFA states: a state that loops on itself except for one to three bytes skips ahead with memchr. regex-automata does it in its dense DFAs, not in the lazy one, so this goes past rg | done: `^\s*$` 1686 -> 770 ms on the 523 MiB file (rg ~820) |
| P4 | the lazy DFA in multi line mode (today `-U` runs on the PikeVM alone), and the cache size limits (`--dfa-size-limit`) | partial: `-U` finds match positions with a forward leftmost-first and a reverse lazy DFA (`-U -c 'fn\s+\w+\s*\('` 110670 -> 452 ms on the 523 MiB file, rg 501); the cache size limits remain |
| P5 | the one-pass DFA and the bounded backtracker for capture groups (`-o`, `-r`, colours), as regex-automata's meta engine picks them | partial: the bounded backtracker is in (`-o -i '[a-z]+ing\b'` 2444 -> 1359 ms on the 523 MiB file, rg 616); positions without captures from a forward leftmost-first and a reverse lazy DFA, as the meta engine's Core::search finds them (`-o -i '[a-z]+ing\b'` 1238 -> 474 ms, rg 552), the backtracker and PikeVM only for capture groups or when a DFA quits; the one-pass DFA remains |
| P0 | real file input: a memory map (MapViewOfFile, mmap) where ripgrep maps, and reads of 64 KiB at a time otherwise | done: on one 523 MiB file `-l` went from 240 to 18 ms (rg 44). Open: rows that scan the whole mapped file pay its page faults (~310 ms, rg ~336); reading it whole took ~278 ms but changes binary detection, so a faster way to fault the map in (a prefetch ahead of the search) is still to try | none |
| P6 | the benchmark again after P1-P5, on Windows and Linux, best of several idle runs; a row slower than rg is a pending item of its own | partial: Unix lists directories with readdir (no stat per entry) and the walk is parallel (a shared directory stack, as WalkParallel). Windows, the Research-LLOG tree (30,457 files): 0.46-0.53 of rg on every row. Linux trees (/usr/include, /usr/share) remain 1.5-1.9x slower on most rows, and the single file's 8 literals (~2.0x) and `-i` (1.3-1.9x) rows too: P7 |
| P7 | the Linux gaps P6 left: the tree rows (where the time goes per directory and per file, against rg under perf) and the single file's output-heavy rows (page faults, `clear_page` and the heap allocator in the first profile) | partial: stdout streamed on one thread (8 literals: 116,228 -> 916 page faults, rg 971; CPU 299 ms vs rg 279, 5 runs); files searched on the thread that walks them (`/usr/share -j1 -F zq_never_here_7` 778 -> 336 ms, rg ~290; `--files` 29 ms vs rg 38). With 4 threads one large directory ran on one thread (`man/man3`: 9,790 of 26,398 files); files now go on the shared stack as in WalkParallel (`/usr/share -F zq_never_here_7` minimum 147 -> 133 ms). Per file on Unix: no readlink of `/proc/self/fd/N` (Odin's `os.open` makes one; 8,904 on `/usr/include`) and no clock read without `--stats`; the stack signals only when a thread waits (futex calls ~6,700 -> 1,517, rg 618). After these, 15 alternating runs put grepper's minimum below rg's on every tree row tried, at `-j1` and with 4 threads (`/usr/share -j1 -F zq_never_here_7` 202 ms vs rg 276; 4 threads 87 vs 104). Left: the full `tests/bench.py` again on a quiet host, row by row; and one Windows run of `-j8 -c -F return` over the Research-LLOG tree that passed a 30 s timeout once in 30 runs and never again in 660 runs of this and the previous build (watch for a hang). Tried without effect: taking the output lock only for files with output | none |

### 2. Features of rg 14.1.1 still missing

| # | Item | Flags | NVOL |
|---|---|---|---|
| F1 | grapheme clusters for the preview of long lines | `--max-columns-preview` | none (Unicode tables, scalar) |
| F2 | encodings: BOM sniffing, UTF-16 to UTF-8, the WHATWG labels encoding_rs knows | `-E` | new: UTF-16 to UTF-8 transcoding; new: full UTF-8 validation (NVOL item 36, Keiser-Lemire, also for `--json`'s text check); has: `first_non_ascii` for the ASCII fast path |
| F3 | decompression through external tools, with #3342 (magic numbers) and #3222 (flags apart from paths) | `-z` | none |
| F4 | preprocessors | `--pre --pre-glob` | none |
| F5 | the regex size limit, and `--engine` | `--regex-size-limit --engine` | none |
| F6 | PCRE2, with #3503 | `-P --pcre2-version` | depends on decision D1 |
| F7 | hyperlinks | `--hyperlink-format --hostname-bin` | none |
| F8 | skipping the file stdout is redirected to, with #3617 | | none |
| F9 | the `--debug` and `--trace` logs | `--debug --trace` | none |
| F10 | rg's exact help and version text, the man page and the completions | `-h --help -V --generate` | none |

### 3. rg bugs waiting on something (section 6)

| # | Bug | Waits on |
|---|---|---|
| W1 | #3609 | a Linux run (T2) |
| W2 | #2958 | a console harness (T3) |
| W3 | #2552, #3534 | symlinks: directory junctions on this account, or Linux (T2) |
| W4 | #3382 | a test that makes a read fail mid-search |
| W5 | B5 (relative `..` paths against `--ignore-file`) | a fix of grepper's own: rg 16.0.0 has it too |

### 4. Testing and platforms

| # | Item |
|---|---|
| T1 | `-L` and `--one-file-system` cases (ported, untested) |
| T2 | the whole suite and the benchmark on Linux (WSL Arch), and the Unix-only paths |
| T3 | a console harness for what rg does only on a terminal (#2958, colour defaults) |
| T4 | the fuzzers (`regex_fuzz.py`, `multiline_fuzz.py`, `line_paths.py`) run over more seeds in one go |

### 5. Decisions

| # | Question |
|---|---|
| D1 | **Decided 2026-11-24:** nothing external. PCRE2's features are ported onto grepper's own engine, and every SIMD step they need is written in NVOL; no C library is linked |
| D2 | **Decided 2026-11-24:** the flags rg added after 14.1.1 (`--in`, `-G/--glob-not`, `RIPGREP_THREADS`, `--max-bytes`, POSIX classes in globs, jj repositories, `GIT_CONFIG_GLOBAL`) are taken where useful, under names of grepper's own: generic where possible, and never naming grepper or ripgrep (an environment variable such as `RIPGREP_THREADS` gets a generic name). Each is decided when it is ported |
