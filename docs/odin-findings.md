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
