# Glossary of algorithms

Every algorithm grepper runs, grouped by stage: what it does, where it lives, and what it is
ported from: ripgrep 14.1.1's crates (grep-regex, grep-searcher, grep-printer, ignore,
globset), and the regex crates it locks, regex-syntax 0.8.4 and regex-automata 0.4.7, unless
an entry says otherwise. **Beyond rg** marks where grepper does more than rg 14.1.1, or takes
a later fix. The SIMD kernels are NVOL's (`vendor/NVOL`): its `README.md` lists them with
their references (memchr 2.8.3, aho-corasick 1.1.5) and its `docs/GLOSSARY.md` explains them.
grepper never writes SIMD of its own.

A search goes through the stages in this order: the pattern is parsed and translated (1),
its literals extracted (2), a prefilter and a strategy chosen (3, 5), the engines built (4),
the files found (7) and each one searched line by line or as a whole (6), and the results
printed (8).

## 1. Regex front end (regex-syntax)

| Algorithm | What it does | Where |
|---|---|---|
| **Parser** | The pattern to an abstract syntax tree: groups, classes (with `&&`, `--`, `~~` set operations and nesting), repetitions, flags, escapes, and the same error messages and spans as regex-syntax's `ast::parse` | `regex_parse.odin`, `regex_ast.odin` |
| **Translator** | The syntax tree to the high-level IR (Hir): Unicode classes from the tables, case folding of classes (simple case folding, the `(?i)` of each class), `.` and its variants, the look-around assertions, captures, and the UTF-8 checks | `regex_translate.odin`, `unicode_tables.odin` |
| **Hir smart constructors** | Concatenations and alternations built flattened and simplified (adjacent literals merged, `x{1}` to `x`, `x{0}` to empty), with each node's properties (minimum and maximum length, the look sets at the edges, captures, whether it is a literal), as `Hir::concat` and friends | `hir.odin` |
| **Class set algebra** | Union, intersection, difference, symmetric difference, negation and canonicalization of byte and Unicode interval sets (the surrogates skipped) | `hir.odin` |
| **Line terminator stripping** | grep-regex's `strip_from_match`: the line terminator removed from what the regex can match, so no match crosses a line in line mode | `grep_regex.odin` |
| **Word and line boundaries** | `-w` and `-x` as grep-regex's `into_word` and `into_whole_line` wrap the Hir: between `\b{start-half}` and `\b{end-half}` (ASCII or Unicode), or between line anchors | `grep_regex.odin` |

## 2. Literals

| Algorithm | What it does | Where |
|---|---|---|
| **Literal extractor** | regex-syntax's `hir::literal::Extractor`: the finite set of prefixes (or suffixes) every match starts (or ends) with, each exact or inexact, with its limits on class size, repetition and total length. Checked against a Rust oracle over 1,869 patterns (`tests/literal_oracle.py`) | `hir_literal.odin` |
| **Literal sequence operations** | `Seq`'s cross products (forward and reverse), union, dedup, minimization by preference (a prefix trie), longest common prefix and suffix, and the "poisonous" test for literals too short or too common to search for | `hir_literal.odin` |
| **Inner literals** | grep-regex's `InnerLiterals`: literals every match contains somewhere inside, for the fast line path; skipped when the regex already has a fast prefilter, unless it has a Unicode word boundary | `inner_literals.odin` |
| **Non-matching bytes** | grep-regex's `non_matching_bytes`: the bytes no match can contain, from the Hir; it decides whether a regex can match a line terminator (and so whether `-U` needs multi line search at all) | `multiline.odin`, `matcher.odin` |

## 3. Literal search: the prefilter and its kernels

| Algorithm | What it does | Where |
|---|---|---|
| **Prefilter choice** | regex-automata's `Choice`: one needle of one byte is memchr, two or three single bytes are memchr2/memchr3, one longer needle is memmem, a set is Teddy, else a byte set; plus whether the choice is "fast" (a byte set is not; Teddy only with needles of 3 bytes or more) | `prefilter.odin` |
| **memchr, memchr2, memchr3** (NVOL) | The first position of one, two or three bytes: SSE2 and AVX2 (32 or 64 bytes a step, four vectors unrolled), NEON, a SWAR kernel for 1-15 bytes, scalar. memchr 2.7's algorithm | `nvol.memchr*` |
| **memrchr** (NVOL) | The same, backwards: used to find line starts | `nvol.memrchr` |
| **memmem** (NVOL) | memchr's `memmem`: the "packed pair" prefilter (two rare bytes of the needle, chosen by a byte-frequency table, compared together in each vector), Two-Way for long needles, Rabin-Karp for short haystacks | `nvol.memmem_finder`, `nvol.memmem_find` |
| **Teddy** (NVOL) | aho-corasick's packed searcher for up to 64 literals: nibble masks looked up with `pshufb` (Slim: 8 buckets, SSSE3 128-bit or AVX2 256-bit; Fat: 16 buckets, AVX2), masks over the first 1 to 4 bytes of the literals, candidates verified, leftmost-first; Rabin-Karp for haystacks too short for a vector | `nvol.teddy_build`, `nvol.teddy_find_in` |
| **count** (NVOL) | The number of occurrences of a byte: the line terminators counted for line numbers | `nvol.count`, in `lines.odin` |
| **first_non_ascii** (NVOL) | The first byte at or above 0x80 (bstr's): the JSON printer's test of whether a line is text, ASCII skipped at vector speed | `nvol.first_non_ascii`, in `printer_json.odin` |
| **Byte set** | A 256-entry table for prefixes that are many single bytes: scanned in grepper, not fast | `prefilter.odin` |

## 4. Regex engines (regex-automata)

| Algorithm | What it does | Where |
|---|---|---|
| **Thompson NFA compiler** | The Hir to an NFA (byte ranges, sparse transitions, unions, captures, looks), forward or **reverse** (concatenations reversed, the looks mirrored), UTF-8 sequences compiled per class | `regex_nfa.odin` |
| **PikeVM** | Simulates the NFA over the haystack with all threads at once, in priority order, keeping the capture slots of each: linear time, any regex, leftmost-first. The fallback for everything else | `regex_nfa.odin` |
| **Bounded backtracker** | Depth-first search of the NFA with a visited set of (state, position) pairs that keeps it linear; used for capture groups when the haystack fits the set (256 KiB of bits), as the meta engine orders it | `regex_backtrack.odin` |
| **Lazy DFA** | regex-automata's hybrid DFA: DFA states built from sets of NFA states on demand, cached, the cache cleared and rebuilt when it fills. Three match semantics: **Earliest** (the first end, for "is there a match"), **Leftmost-first** (the end of the match the regex prefers) and **All** (every end, for the reverse search). One flat table of 257 entries a state (each byte, and the end of input), targets premultiplied, with negative specials (unknown, match, quit, no end) and tagged transitions for start, match and accelerated states | `regex_dfa.odin` |
| **Look-around in the lazy DFA** | The context each byte leaves (start, `\n`, `\r`, word byte, other, non-ASCII), reduced to the distinctions the regex's looks need, so bytes the regex treats alike lead to one state. Unicode word boundaries quit on non-ASCII bytes, and the search falls back to the PikeVM | `regex_dfa.odin` |
| **Accelerated DFA states** | A state that loops on itself for all but one to three bytes skips ahead with memchr, memchr2 or memchr3 to the next of those bytes. **Beyond rg:** regex-automata accelerates only its dense DFAs, not the lazy one (`^\s*$`: 1686 -> 770 ms on 523 MiB, rg ~820) | `regex_dfa.odin` |
| **Prefilter in the DFA** | In an unanchored start state, the prefilter jumps to the next place a match can start | `regex_dfa.odin` |
| **Reverse search** | The start of a match: the reverse DFA (All, over the reverse NFA) run anchored from the match's end | `regex_dfa.odin` (`dfa_find_rev`) |
| **Limited reverse search** | `meta::limited`: the reverse search given up (quadratic) when it would read below a minimum start, or when it reaches the start of the input alive with a later match ("false positive" guard) | `regex_dfa.odin` (`dfa_find_rev_limited`) |
| **Anchored, earliest and stop-at forward search** | The leftmost-first DFA started anchored at a known start, stopped at the first match state (earliest), or reporting where it died when there is no match (`meta::stopat`) | `regex_dfa.odin` (`dfa_find_fwd`) |

## 5. The meta engine: which engine runs a search

| Algorithm | What it does | Where |
|---|---|---|
| **Literal matcher** | `Pre::from_prefixes`: a regex whose prefixes are exact, with no captures and no looks, is those literals; memchr, memmem or Teddy run it alone, no regex engine | `matcher.odin` (`matcher_from_hir`) |
| **Core** | The default: the forward leftmost-first lazy DFA for the end of a match, then the reverse DFA for its start; the backtracker or PikeVM for capture groups, or when a DFA quits | `matcher.odin` |
| **Reverse anchored** | For a regex always anchored at the end (`\z`) and not at the start: the reverse DFA from the end of the input, the only place a match can end. `-U -c '[a-z]+\n\z'`: 1412 -> 19 ms (rg 50) | `matcher.odin` |
| **Reverse suffix** | When the prefix prefilter is not fast but the regex's suffixes share a longest common suffix with a fast prefilter: each occurrence of the suffix gets a limited reverse scan for a start, and the forward DFA, anchored there, gives the end | `matcher.odin` |
| **Reverse inner** | For a top-level concatenation with inner literals that have a fast prefilter: each occurrence gets a limited reverse scan of the part before it (its own reverse NFA and DFA), then the stop-at forward search; quadratic cases fall back to Core | `matcher.odin`, `meta_reverse_inner.odin` |
| **Soundness proofs of the reverse strategies** | **Beyond rg** (regex 1.13.1, regex-automata 0.4.18, rust-lang/regex#1354): the reverse suffix and inner searches are used only when a conservative proof shows the first candidate confirmed is the leftmost-first match: the prefix before the literal has a fixed length, or a required class at its edge disjoint from the rest and from the literal, or cannot contain the literal. rg 14.1.1 has no such check and reports wrong matches (`-o '[a-c][^\n]*xz|z'` on `a z xz`) | `meta_prefix.odin`, `meta_reverse_inner.odin` |

## 6. The searcher (grep-searcher)

| Algorithm | What it does | Where |
|---|---|---|
| **Fast line path** | The regex (or the inner literals) run over many lines at once; the line holding a candidate is found around it with memchr and memrchr, then confirmed. Also under `-U` when no match can hold a line terminator (as `is_line_by_line_fast`'s second branch) | `searcher.odin` (`core_match_by_line_fast`) |
| **Slow line path** | Each line, its terminator removed, tested alone: for regexes with haystack anchors, `--passthru`, and NUL line terminators | `searcher.odin` (`core_match_by_line_slow`) |
| **Multi line search** | `-U` with a regex that can match the line terminator: the whole input in memory, matches found one after another, and the lines they touch merged into blocks | `multiline.odin` |
| **Context** | `-A`, `-B`, `-C`: the lines before a match found backwards with memrchr from it, the lines after counted down as the search goes | `searcher.odin` |
| **Roll buffer** | Reads of 64 KiB into a buffer that keeps the last partial line (and the context lines needed) when it refills | `searcher.odin` (`lb_roll`, `lb_fill`) |
| **Memory maps** | The file mapped (MapViewOfFile, mmap) where ripgrep maps: up to 10 paths, all of them files; otherwise reads. On Unix the searched files are opened with `open(2)` directly (Odin's `os.open` adds a readlink per file) | `mmap_windows.odin`, `mmap_other.odin` |
| **Binary detection** | A NUL byte stops the search (`quit`, for walked files) or is replaced by the line terminator (`convert`, for given files), as grep-searcher decides, in the first buffer and in every match | `searcher.odin` (`core_detect_binary`) |
| **Line stepping** | The lines of a buffer by their terminator (LF, or CRLF with `--crlf`), and the line around a match | `lines.odin` |

## 7. Finding the files (ignore, globset, walkdir)

| Algorithm | What it does | Where |
|---|---|---|
| **Glob matching** | globset's per-glob strategies, cheapest first: the whole path as a literal, the basename as a literal, an extension, a prefix, a suffix, a required extension plus a regex, else a regex. The regex is an NFA over the path's bytes, simulated with a per-thread scratch | `glob.odin` |
| **Gitignore rules** | `.gitignore`, `.ignore`, `.rgignore`, `.git/info/exclude` and the global excludes file: each line a glob with its anchoring, directory-only and whitelist (`!`) forms; the last rule that matches decides. Beyond rg: 15.x-16.x fixes (a BOM, `!` alone, trailing spaces) | `gitignore.odin` |
| **Ignore hierarchy** | The ignore crate's `Ignore` tree: each directory's rules on top of its parent's, the parents of a root directory read too, the absolute base kept for rules that name paths below the root. Beyond rg: B2 (root order) and B3 (directories between root and file) fixed | `ignore_dir.odin` |
| **File types** | `-t`, `-T`, `--type-add`: the default type table as globs, a type matched through the same glob set | `types.odin`, `default_types.odin` |
| **Directory listing** | The entries of a directory with their type and no stat per entry: readdir and `d_type` on Unix (lstat only when the type is unknown), FindFirstFileExW with the basic info level on Windows | `dir_other.odin`, `dir_windows.odin` |
| **Sequential walk** | Depth-first, each directory's entries in the order the OS gives (by name with `--sort path`), every entry checked against its directory's rules, hidden files, `--max-depth`, `--max-filesize`; symlinks followed with `-L` with a loop check against the ancestors, `--one-file-system` by device | `walk.odin` |
| **Parallel walk** | The ignore crate's `WalkParallel`: one stack shared by the threads, holding directories and also files, so one large directory spreads over the threads; the walk ends when the stack is empty and no thread holds a job. Each thread searches the files it takes. The stack signals a waiter only when one waits | `walk.odin` |
| **Sorting** | `--sort` and `--sortr` by path (component by component), modification, access or creation time: the files collected first, then searched on one thread | `walk.odin` |

## 8. Output (grep-printer)

| Algorithm | What it does | Where |
|---|---|---|
| **Standard printer** | Paths, line and column numbers, byte offsets, headings, separators, context, `--only-matching`, `--vimgrep`, `--max-columns` and the colours of each part | `printer_standard.odin`, `color.odin` |
| **Summary printer** | `-c`, `--count-matches`, `-l`, `--files-without-match`, `-q` | `printer_summary.odin` |
| **JSON printer** | grep-printer's JSON Lines: begin, match, context, end and summary messages, text or base64 bytes, the stats | `printer_json.odin` |
| **Replacement** | `-r`: `$0`, `$1`, `${name}` interpolation of capture groups into each match | `replace.odin` |
| **Buffered output** | One buffer per file when several threads search, written whole under a lock (ripgrep's `BufferWriter`, with `--file-separator` between files); stdout written in 64 KiB blocks while one thread searches, as ripgrep's block-buffered stdout | `walk.odin`, `sink.odin` |
