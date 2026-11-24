// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strings"

Color_When :: enum { Auto, Always, Never }

// The command line, as ripgrep's flags of the same names. A flag grepper does not know is an
// error, never ignored: an agent then falls back to rg instead of trusting a partial search.
Options :: struct {
	patterns:      [dynamic]string,
	paths:         [dynamic]string,
	fixed:         bool,  // -F
	ignore_case:   bool,  // -i
	line_number:   Maybe(bool),  // -n / -N; default: on when stdout is a terminal
	with_filename: Maybe(bool),  // -H / -I; default: on when several files may be searched
	heading:       Maybe(bool),  // --heading / --no-heading; default: on when stdout is a terminal
	files_with_matches: bool,    // -l
	files:         bool,  // --files: list the files that would be searched, search nothing
	count:         bool,  // -c
	color:         Color_When,
	hidden:        bool,  // --hidden
	no_ignore:     bool,  // --no-ignore
	threads:       int,   // -j; 0 = the number of CPUs
}

Args_Error :: struct { msg: string }

// ripgrep's short forms, expanded first: a value attached to its flag (`-j1`, `-eFOO`) and
// several flags in one argument (`-nH`, `-Fn`)
expand_short :: proc(args: []string) -> []string {
	out: [dynamic]string
	done := false
	for a in args {
		if done || a == "--" || len(a) <= 2 || a[0] != '-' || a[1] == '-' {
			if a == "--" { done = true }
			append(&out, a)
			continue
		}
		for k := 1; k < len(a); k += 1 {
			c := a[k:k + 1]
			if c == "e" || c == "j" {
				append(&out, strings.concatenate({"-", c}))
				if k + 1 < len(a) { append(&out, a[k + 1:]) }
				break
			}
			append(&out, strings.concatenate({"-", c}))
		}
	}
	return out[:]
}

parse_args :: proc(raw: []string) -> (o: Options, err: Maybe(Args_Error)) {
	args := expand_short(raw)
	i := 0
	no_more_flags := false
	value :: proc(args: []string, i: ^int, flag: string) -> (string, Maybe(Args_Error)) {
		if i^ + 1 >= len(args) {
			return "", Args_Error{strings.concatenate({"missing value for ", flag})}
		}
		i^ += 1
		return args[i^], nil
	}
	for ; i < len(args); i += 1 {
		a := args[i]
		if no_more_flags || len(a) < 2 || a[0] != '-' {
			if len(o.patterns) == 0 && !has_e(args) && !has_flag(args, "--files") {
				append(&o.patterns, a)
			} else {
				append(&o.paths, a)
			}
			continue
		}
		switch a {
		case "--":
			no_more_flags = true
		case "-F", "--fixed-strings":
			o.fixed = true
		case "-i", "--ignore-case":
			o.ignore_case = true
		case "-n", "--line-number":
			o.line_number = true
		case "-N", "--no-line-number":
			o.line_number = false
		case "-H", "--with-filename":
			o.with_filename = true
		case "-I", "--no-filename":
			o.with_filename = false
		case "--heading":
			o.heading = true
		case "--no-heading":
			o.heading = false
		case "--files":
			o.files = true
		case "-l", "--files-with-matches":
			o.files_with_matches = true
		case "-c", "--count":
			o.count = true
		case "--hidden", "-.":
			o.hidden = true
		case "--no-ignore":
			o.no_ignore = true
		case "-e", "--regexp":
			v := value(args, &i, a) or_return
			append(&o.patterns, v)
		case "-j", "--threads":
			v := value(args, &i, a) or_return
			n, ok := parse_uint(v)
			if !ok { return o, Args_Error{strings.concatenate({"invalid thread count: ", v})} }
			o.threads = n
		case "--color", "--colour":
			v := value(args, &i, a) or_return
			switch v {
			case "auto": o.color = .Auto
			case "always", "ansi": o.color = .Always
			case "never": o.color = .Never
			case: return o, Args_Error{strings.concatenate({"invalid --color value: ", v})}
			}
		case:
			return o, Args_Error{strings.concatenate({"unknown flag: ", a})}
		}
	}
	if len(o.patterns) == 0 && !o.files {
		return o, Args_Error{"no pattern given"}
	}
	return o, nil
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for a in args {
		if a == "--" { return false }
		if a == flag { return true }
	}
	return false
}

// -e anywhere means every positional argument is a path
has_e :: proc(args: []string) -> bool {
	for a in args {
		if a == "--" { return false }
		if a == "-e" || a == "--regexp" { return true }
	}
	return false
}

parse_uint :: proc(s: string) -> (n: int, ok: bool) {
	if len(s) == 0 { return 0, false }
	for c in transmute([]u8)s {
		if c < '0' || c > '9' { return 0, false }
		n = n * 10 + int(c - '0')
	}
	return n, true
}

is_terminal :: proc() -> bool {
	return os.is_tty(os.stdout)
}
