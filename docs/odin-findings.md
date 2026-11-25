# Odin behaviours found while building grepper

Odin's behaviours that grepper works around. Each one is to be audited before anything is
reported upstream: reproduced on Odin's current master, checked against its documentation and
issues, and confirmed as a bug and not a design choice. None has been reported yet.

Odin: `dev-2026-10-nightly:84bc3fc`, Windows 10.

## 1. `os.args` on Windows loses characters outside the ANSI code page

`base:runtime` builds `args__` from the C entry point's `argv`, which is in the ANSI code page,
and `core:os` takes `os.args` from it. A UTF-8 argument such as `café` reaches the program
altered, so a pattern such as `grepper café` found nothing.

grepper reads the command line with `GetCommandLineW` and `CommandLineToArgvW` instead
(`src/args_windows.odin`), as Rust's `std::env::args` does.

## 2. `core:text/regex` reads an unescaped `#` as a comment without `Ignore_Whitespace`

`regex.create("^#inc", {})` compiles to `^` alone, and matches every string at `[0, 0]`.
`\#inc` and `[#]inc` are right. The flag's documentation mentions whitespace only.

grepper escapes each bare `#` outside a class before compiling (`escape_hash` in
`src/regexm.odin`).

## 3. `core:text/regex` multiline anchors consume the newline

With `{.Multiline}`, `^$` finds no empty line in `"a\n\nb"`, and `$` matches `[1, 2)` (the
newline itself) instead of the empty span `[1, 1)`.

grepper checks each line alone and never searches a buffer in multiline mode
(`src/regexm.odin`).

## 4. `os.read_directory` on Windows opens every entry

`find_data_to_file_info` opens each entry with `CreateFile` to read its file id through
`GetFileInformationByHandleEx`. A walk of 30,415 files took 5.3 s, against 0.78 s for
`FindFirstFileExW` alone, which already gives the name, type and attributes.

This is a cost, not a wrong result. grepper lists directories itself on Windows
(`src/dir_windows.odin`).

## 5. `os.read_directory` on Unix stats every entry

The same on Linux: each entry gets a stat, though `readdir` already gives its type
(`d_type`). `--files` over `/usr/share` (26,398 files, WSL Arch) took 352 ms, against 96 ms
with `opendir`/`readdir` alone (rg -j1: 75 ms). A cost, not a wrong result. grepper lists
directories itself on Unix (`src/dir_other.odin`, bfba3b0), and stats an entry only when
`d_type` is unknown or `--max-filesize` needs the size.

## 6. `os.open` on Linux reads the file's name back from `/proc`

`_open` ends in `_new_file`, which allocates a `File` and fills its name with
`_get_full_path`: a `readlink("/proc/self/fd/N")` on every open (`core/os/file_linux.odin`).
A search of `/usr/include` (8,903 files) made 8,904 of them; rg makes none. On WSL they are
costly: `/usr/share -j1 -F zq_never_here_7` went from 349 to 222 ms (minimum of 15) once
grepper opened its files with `open(2)` itself (`src/mmap_other.odin`, 5243715). It may be a
design choice, since the name is part of `File`; a cost, not a wrong result.

## 7. `sync.cond_signal` makes a futex syscall on every call

`atomic_cond_signal` adds to the condition's state and calls `futex_signal` whether or not a
thread waits (`core/sync/primitives_atomic.odin`). With every walked file pushed on the
parallel walk's stack, `perf trace -s` counted ~6,700 futex calls over `/usr/include` (rg:
~115). grepper counts its waiters under the lock and signals only when one waits
(`src/walk.odin`, a66f938): 1,517 calls, 5-7 % less wall time with 4 threads. A cost, not a
wrong result: glibc's `pthread_cond_signal` returns early when no thread waits, but Rust's
futex `Condvar::notify_one` does not either, so it may be a deliberate trade.
