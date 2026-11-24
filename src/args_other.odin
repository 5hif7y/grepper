// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:os"

// The command line as the OS gives it: bytes, which ripgrep also takes as they are on Unix.
program_args :: proc() -> []string {
	return os.args
}
