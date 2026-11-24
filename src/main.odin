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
	case .Types:
		// --type-list: every type with its globs, sorted; exit 1 if there are none
		o: Out
		for d in h.types.defs {
			out_str(&o, d.name)
			out_str(&o, ": ")
			for g, i in d.globs {
				if i > 0 { out_str(&o, ", ") }
				out_str(&o, g)
			}
			out_str(&o, "\n")
		}
		write_stdout(o.buf[:])
		return 0 if len(h.types.defs) > 0 else 1
	case .Generate:
		unreachable()     // refused in hi_from_low
	}
	if matched && (h.quiet || !messages_errored) { return 0 }
	if messages_errored { return 2 }
	return 1
}

// literals go to NVOL directly: -F, or patterns without a regex metacharacter (as ripgrep
// extracts them); the rest to the interim regex engine
build_matcher :: proc(h: ^Hi_Args) -> (m: Matcher, err: Maybe(string)) {
	// grep-regex's ConfiguredHIR: unless every pattern is a plain literal, they are joined as
	// (?:p1)|(?:p2)... and parsed by regex-syntax, whose errors ripgrep prints as they are
	if !rg_is_fixed_strings(h) {
		b: strings.Builder
		for p, i in h.patterns {
			if i > 0 { strings.write_byte(&b, '|') }
			strings.write_string(&b, "(?:")
			strings.write_string(&b, rg_escape(p) if h.fixed_strings else p)
			strings.write_byte(&b, ')')
		}
		if _, perr := regex_parse(strings.to_string(b)); perr != nil {
			return m, suggest_pcre2(ast_error_string(perr.?))
		}
	}
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

// regex_syntax::escape: every meta character preceded by a backslash
rg_escape :: proc(p: string) -> string {
	b: strings.Builder
	for r in p {
		if is_regex_meta_character(r) { strings.write_byte(&b, '\\') }
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// Config::is_fixed_strings: every pattern a literal (-F, or no meta character) without the
// line terminator, and no case folding
rg_is_fixed_strings :: proc(h: ^Hi_Args) -> bool {
	if h.case_mode != .Sensitive { return false }
	term: u8 = 0 if h.null_data else '\n'
	has_term :: proc(p: string, term: u8, crlf: bool) -> bool {
		for c in transmute([]u8)p {
			if c == term || (crlf && (c == '\r' || c == '\n')) { return true }
		}
		return false
	}
	for p in h.patterns {
		if !h.fixed_strings {
			for r in p { if is_regex_meta_character(r) { return false } }
		}
		if !h.multiline && has_term(p, term, h.crlf) { return false }
	}
	return true
}

// hiargs.rs's suggest_pcre2 (ripgrep 14.1.1 is built with PCRE2): a hint after errors about
// backreferences and look-around
suggest_pcre2 :: proc(msg: string) -> string {
	if !strings.contains(msg, "backreferences") && !strings.contains(msg, "look-around") { return msg }
	return strings.concatenate({msg, "\n\nConsider enabling PCRE2 with the --pcre2 flag, which can handle backreferences\nand look-around."})
}
