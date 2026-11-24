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
    grepper [OPTIONS] -e PATTERN ... [PATH ...]

OPTIONS (ripgrep's, a subset):
    -F, --fixed-strings     PATTERN is a literal string
    -i, --ignore-case       case-insensitive search
    -e, --regexp PATTERN    a pattern (repeatable)
    -n, --line-number       show line numbers (default on a terminal)
    -N, --no-line-number
    -H, --with-filename     show the path of each match
    -I, --no-filename
        --heading           group matches under each path (default on a terminal)
        --no-heading
    -l, --files-with-matches
    -c, --count             matching lines per file
        --color WHEN        auto, always, never
        --hidden            search hidden files and directories
        --no-ignore         do not honour .gitignore and .ignore files
    -j, --threads N
    -V, --version
`

main :: proc() {
	os.exit(run(program_args()[1:]))
}

// exit codes as ripgrep: 0 a match, 1 none, 2 an error
run :: proc(args: []string) -> int {
	if len(args) == 1 && (args[0] == "--version" || args[0] == "-V") {
		fmt.println("grepper", VERSION)
		return 0
	}
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		fmt.print(USAGE)
		return 0
	}
	o, perr := parse_args(args)
	if e, bad := perr.?; bad {
		fmt.eprintfln("grepper: %s", e.msg)
		fmt.eprint(USAGE)
		return 2
	}
	if !o.fixed || o.ignore_case {
		fmt.eprintln("grepper: only fixed-string search (-F) without -i is implemented yet; use rg")
		return 2
	}
	m := matcher_literals(o.patterns[:])
	// no path: the current directory, its entries printed without a "./" prefix (as ripgrep)
	paths := o.paths[:] if len(o.paths) > 0 else []string{""}
	several := len(paths) > 1
	for path in paths {
		if fi, err := os.stat(path if path != "" else ".", context.temp_allocator); err == nil && fi.type == .Directory {
			several = true
		}
	}
	tty := is_terminal()
	p := Printer{
		color = o.color == .Always || (o.color == .Auto && tty),
		line_number = o.line_number.? or_else tty,
		with_filename = o.with_filename.? or_else several,
		heading = o.heading.? or_else tty,
	}
	mode := Mode.Files if o.files_with_matches else (Mode.Count if o.count else Mode.Lines)
	return search_paths(&o, &m, p, mode, paths)
}

eprint_error :: proc(path: string, err: os.Error) {
	fmt.eprintfln("grepper: %s: %v", path if path != "" else ".", err)
}
