// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build windows
package grepper

import "core:os"
import win32 "core:sys/windows"

// The command line as UTF-8. Odin's os.args comes from the C entry point's argv, in the ANSI
// code page, so a pattern such as `café` arrives altered on Windows; ripgrep reads the UTF-16
// command line, and so does this.
program_args :: proc() -> []string {
	n: i32
	argv := win32.CommandLineToArgvW(win32.GetCommandLineW(), &n)
	if argv == nil {
		return os.args
	}
	defer win32.LocalFree(rawptr(argv))
	out := make([]string, n)
	for i in 0 ..< int(n) {
		s, err := win32.wstring_to_utf8(argv[i], -1, context.allocator)
		if err != nil {
			return os.args
		}
		out[i] = s
	}
	return out
}

// the separator ripgrep joins walked paths with on Windows (the root stays as given)
SEP :: "\\"

// ripgrep's default path colour on Windows (crates/printer/src/color.rs)
COLOR_PATH :: "\x1b[0m\x1b[36m"
