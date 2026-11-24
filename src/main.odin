// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
//
// grepper: a recursive line-oriented search tool, a port of ripgrep to Odin.
package grepper

import "core:fmt"
import "core:os"
import "core:strings"

VERSION :: "0.0.1"

USAGE :: `grepper ` + VERSION + `
A recursive line-oriented search tool: a port of ripgrep 14.1.1 to Odin, with NVOL's SIMD.

USAGE:
    grepper [OPTIONS] PATTERN [PATH ...]
    grepper [OPTIONS] -e PATTERN ... [PATH ...]
    grepper [OPTIONS] --files [PATH ...]

Flags are ripgrep's, with ripgrep's meaning. A flag grepper does not implement yet is an
error, never ignored; docs/PARITY.md lists what is done.
`

main :: proc() {
	os.exit(run(program_args()[1:]))
}

eprint_error :: proc(msg: string) {
	fmt.eprintfln("grepper: %s", msg)
}

// ripgrep's config file: RIPGREP_CONFIG_PATH, one argument per line, blank lines and lines
// starting with `#` skipped, each line trimmed
config_args :: proc() -> (args: [dynamic]string) {
	path := os.get_env("RIPGREP_CONFIG_PATH", context.allocator)
	if path == "" { return }
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		eprint_error(strings.concatenate({"failed to read the file specified in RIPGREP_CONFIG_PATH: ", path, ": ", os_error_message(err)}))
		return
	}
	rest := string(data)
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		line = strings.trim_space(line)
		if len(line) == 0 || line[0] == '#' { continue }
		append(&args, line)
	}
	return
}

// exit codes as ripgrep: 0 a match, 1 none, 2 an error
run :: proc(args: []string) -> int {
	low := low_args_default()
	if e := parse_low(args, &low); e != "" {
		eprint_error(e)
		return 2
	}
	switch low.special {
	case .None:
	case .Help_Short, .Help_Long:
		fmt.print(USAGE)
		return 0
	case .Version_Short, .Version_Long:
		fmt.println("grepper", VERSION)
		return 0
	case .Version_PCRE2:
		fmt.println("PCRE2 is not available in this build of grepper.")
		return 1
	}
	if !low.no_config {
		if extra := config_args(); len(extra) > 0 {
			all: [dynamic]string
			append(&all, ..extra[:])
			append(&all, ..args)
			low = low_args_default()
			if e := parse_low(all[:], &low); e != "" {
				eprint_error(e)
				return 2
			}
		}
	}
	h, herr := hi_from_low(&low)
	if herr != "" {
		eprint_error(herr)
		return 2
	}
	matched := false
	switch h.mode.kind {
	case .Search:
		if !matches_possible(&h) { break }
		m, merr := build_matcher(&h)
		if msg, bad := merr.?; bad {
			eprint_error(msg)
			return 2
		}
		matched = run_walk(&h, &m, false)
	case .Files:
		matched = run_walk(&h, nil, true)
	case .Types, .Generate:
		unreachable()     // refused in hi_from_low
	}
	if matched && (h.quiet || !messages_errored) { return 0 }
	if messages_errored { return 2 }
	return 1
}

// literals go to NVOL directly: -F, or patterns without a regex metacharacter (as ripgrep
// extracts them); the rest to the interim regex engine
build_matcher :: proc(h: ^Hi_Args) -> (m: Matcher, err: Maybe(string)) {
	ignore_case := h.case_mode == .Insensitive
	plain := !ignore_case
	if plain && !h.fixed_strings {
		for p in h.patterns {
			if has_meta(p) { plain = false }
		}
	}
	if plain {
		return matcher_literals(h.patterns[:]), nil
	}
	return matcher_regex(join_patterns(h.patterns[:], h.fixed_strings), ignore_case)
}
