// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:os"

// The command line as the OS gives it: bytes, which ripgrep also takes as they are on Unix.
program_args :: proc() -> []string {
	return os.args
}

SEP :: "/"

// ripgrep's default path colour on Unix (crates/printer/src/color.rs)
COLOR_PATH_DEFAULT :: Color_Kind.Magenta

// grep-cli's is_readable_stdin on Unix: not a terminal, and a file, a FIFO or a socket
is_readable_stdin :: proc() -> bool {
	if os.is_tty(os.stdin) { return false }
	fi, err := os.fstat(os.stdin, context.temp_allocator)
	if err != nil { return false }
	return fi.type == .Regular || fi.type == .Named_Pipe || fi.type == .Socket
}
