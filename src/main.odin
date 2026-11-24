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
	if len(o.paths) == 0 {
		fmt.eprintln("grepper: a PATH is required for now (no directory walk yet); use rg")
		return 2
	}
	tty := is_terminal()
	p := Printer{
		color = o.color == .Always || (o.color == .Auto && tty),
		line_number = o.line_number.? or_else tty,
		with_filename = o.with_filename.? or_else len(o.paths) > 1,
		heading = o.heading.? or_else tty,
	}
	mode := Mode.Files if o.files_with_matches else (Mode.Count if o.count else Mode.Lines)
	found, failed := false, false
	for path in o.paths {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("grepper: %s: %v", path, err)
			failed = true
			continue
		}
		if is_binary(data) { delete(data); continue }
		if search_buffer(&m, data, path, &p, mode) > 0 { found = true }
		delete(data)
	}
	flush(&p)
	return 2 if failed else (0 if found else 1)
}
