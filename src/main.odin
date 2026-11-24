// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
//
// grepper: a recursive line-oriented search tool, a port of ripgrep to Odin.
package grepper

import "core:fmt"
import "core:os"

VERSION :: "0.0.1"

USAGE :: `grepper ` + VERSION + `
A recursive line-oriented search tool (a port of ripgrep to Odin).

USAGE:
    grepper [OPTIONS] PATTERN [PATH ...]

Pre-alpha: no search yet.
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 1 && (args[0] == "--version" || args[0] == "-V") {
		fmt.println("grepper", VERSION)
		os.exit(0)
	}
	fmt.eprint(USAGE)
	os.exit(2)
}
