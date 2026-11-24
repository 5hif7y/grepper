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
COLOR_PATH :: "\x1b[0m\x1b[35m"
