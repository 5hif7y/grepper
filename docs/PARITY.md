# Feature parity with ripgrep 14.1.1

Every flag and behaviour of ripgrep 14.1.1, and where grepper stands on it. A row is done only
when `tests/compare.py` has cases for it that match ripgrep byte for byte (stdout and exit code).

SIMD rule: every vectorised step is an NVOL kernel. Where ripgrep's dependencies use SIMD that
NVOL lacks, the kernel is written in NVOL first (with its tests against NVOL's interpreter and
its benchmark against the crate it replaces), then used here.

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
| replacement, with `$1 ${name}` captures | `-r` | todo |
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
