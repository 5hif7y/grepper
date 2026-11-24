// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strings"

// ripgrep's HiArgs (crates/core/flags/hiargs.rs): the low-level flags resolved against the
// environment (is stdout a terminal, is stdin readable, which paths exist) into what the
// searcher, the printers and the walker use.

Binary_Detection_Kind :: enum { None, Quit, Convert }

Binary_Detection :: struct {
	kind: Binary_Detection_Kind,
	byte: u8,
}

Hi_Args :: struct {
	mode:                 Mode,
	patterns:             [dynamic]string,
	paths:                [dynamic]string,
	has_implicit_path:    bool,
	is_one_file:          bool,
	binary_explicit:      Binary_Detection,
	binary_implicit:      Binary_Detection,
	boundary:             Boundary_Mode,
	buffer:               Buffer_Mode,
	byte_offset:          bool,
	case_mode:            Case_Mode,
	color:                bool,
	colors:               Color_Specs,
	column:               bool,
	before_context:       int,
	after_context:        int,
	passthru:             bool,
	context_separator:    Maybe(string),
	crlf:                 bool,
	field_context_separator: string,
	field_match_separator: string,
	file_separator:       Maybe(string),
	fixed_strings:        bool,
	heading:              bool,
	hidden:               bool,
	include_zero:         bool,
	invert_match:         bool,
	is_terminal_stdout:   bool,
	line_number:          bool,
	max_columns:          Maybe(u64),
	max_columns_preview:  bool,
	max_count:            Maybe(u64),
	mmap:                 bool,
	multiline:            bool,
	no_ignore_dot:        bool,
	no_ignore_exclude:    bool,
	no_ignore_vcs:        bool,
	no_require_git:       bool,
	null_data:            bool,
	only_matching:        bool,
	path_separator:       Maybe(u8),
	path_terminator:      Maybe(u8),
	quiet:                bool,
	quit_after_match:     bool,
	replace:              Maybe(string),
	stats:                bool,
	stop_on_nonmatch:     bool,
	threads:              int,
	trim:                 bool,
	vimgrep:              bool,
	with_filename:        bool,
	no_messages:          bool,
	no_ignore_messages:   bool,
	no_ignore_parent:     bool,
	no_ignore_global:     bool,
	no_ignore_files:      bool,
	ignore_file:          [dynamic]string,
	ignore_file_case_insensitive: bool,
	overrides:            ^Gitignore,
	types:                Types,
	max_depth:            Maybe(int),
	max_filesize:         Maybe(u64),
	follow:               bool,
	one_file_system:      bool,
	sort:                 Maybe(Sort_Mode),
	no_unicode:           bool,
	multiline_dotall:     bool,
}

// What grepper does not do yet: an error, never a silently different search.
unsupported :: proc(low: ^Low_Args) -> string {
	if low.mode.kind == .Generate { return "--generate" }
	if low.encoding == .Some { return "-E/--encoding" }
	if low.search_zip { return "-z/--search-zip" }
	if low.pre != "" { return "--pre" }
	if low.engine != .Default { return "-P/--pcre2 and --engine" }
	if low.boundary != .None { return "-w/-x" }
	if low.multiline { return "-U/--multiline" }
	if low.case_mode == .Smart { return "-S/--smart-case" }
	if low.no_unicode { return "--no-unicode" }
	if low.crlf { return "--crlf" }
	if low.null_data { return "--null-data" }
	if low.hyperlink_format != "" { return "--hyperlink-format" }
	if low.replace != nil { return "-r/--replace" }
	if low.max_columns_preview { return "--max-columns-preview" }
	return ""
}

hi_from_low :: proc(low: ^Low_Args) -> (h: Hi_Args, err: string) {
	if what := unsupported(low); what != "" {
		return h, strings.concatenate({what, " is not supported by grepper yet (see docs/PARITY.md)"})
	}
	// -v --count-matches is -v --count; -o --count is --count-matches
	if low.mode.kind == .Search {
		if low.mode.search == .Count_Matches && low.invert_match {
			low.mode.search = .Count
		} else if low.mode.search == .Count && low.only_matching {
			low.mode.search = .Count_Matches
		}
	}
	h.mode = low.mode
	h.is_terminal_stdout = os.is_tty(os.stdout)
	stdin_consumed := false

	// patterns: the first positional, unless -e or -f gave some (deduplicated, in order)
	if low.mode.kind == .Search {
		if len(low.patterns) == 0 {
			if len(low.positional) == 0 {
				return h, "ripgrep requires at least one pattern to execute a search"
			}
			append(&h.patterns, low.positional[0])
			ordered_remove(&low.positional, 0)
		} else {
			seen := make(map[string]bool)
			add :: proc(h: ^Hi_Args, seen: ^map[string]bool, p: string) {
				if p in seen^ { return }
				seen[p] = true
				append(&h.patterns, p)
			}
			for src in low.patterns {
				if !src.is_file {
					add(&h, &seen, src.value)
					continue
				}
				data: []u8
				where_: string
				if src.value == "-" {
					if stdin_consumed {
						return h, "error reading -f/--file from stdin: stdin has already been consumed"
					}
					d, e := os.read_entire_file(os.stdin, context.allocator)
					if e != nil { return h, strings.concatenate({"<stdin>:", os_error_message(e)}) }
					data = d
					where_ = "<stdin>"
					stdin_consumed = true
				} else {
					d, e := os.read_entire_file(src.value, context.allocator)
					if e != nil {
						return h, strings.concatenate({src.value, ": ", os_error_message(e)})
					}
					data = d
					where_ = src.value
				}
				_ = where_
				// bstr's for_byte_line: records split on \n, a trailing \r\n or \n dropped
				rest := string(data)
				for len(rest) > 0 {
					line := rest
					if i := strings.index_byte(rest, '\n'); i >= 0 {
						line, rest = rest[:i], rest[i + 1:]
					} else {
						rest = ""
					}
					if strings.has_suffix(line, "\r") { line = line[:len(line) - 1] }
					add(&h, &seen, line)
				}
			}
		}
	}

	// paths: the rest of the positionals; none means stdin when it is readable, else ./
	for p in low.positional {
		if stdin_consumed && p == "-" {
			return h, "error: attempted to read patterns from stdin while also searching stdin"
		}
		append(&h.paths, p)
	}
	if len(h.paths) > 0 {
		h.is_one_file = len(h.paths) == 1 && (h.paths[0] == "-" || !os.is_dir(h.paths[0]))
	} else {
		use_cwd := !is_readable_stdin() || stdin_consumed || low.mode.kind != .Search
		h.has_implicit_path = true
		if use_cwd {
			append(&h.paths, "./")
			h.is_one_file = false
		} else {
			append(&h.paths, "-")
			h.is_one_file = true
		}
	}

	// binary detection: convert for explicit files, quit for walked ones (convert with
	// --binary); none with -a or --null-data
	none := low.binary == .As_Text || low.null_data
	if !none {
		h.binary_explicit = {.Convert, 0}
		h.binary_implicit = {.Convert, 0} if low.binary == .Search_And_Suppress else {.Quit, 0}
	}

	specs: [dynamic]User_Color_Spec
	append(&specs, ..default_color_specs())
	append(&specs, ..low.colors[:])
	h.colors = color_specs_new(specs[:])

	h.color = low.color == .Always || low.color == .Ansi || (low.color == .Auto && h.is_terminal_stdout)
	h.column = low.column.? or_else low.vimgrep
	if hd, ok := low.heading.?; ok {
		h.heading = hd && !low.vimgrep
	} else {
		h.heading = !low.vimgrep && h.is_terminal_stdout
	}
	if low.null { h.path_terminator = u8(0) }
	h.quiet = low.quiet
	h.quit_after_match = !low.stats && low.quiet
	if low.sort != nil || h.is_one_file {
		h.threads = 1
	} else if n, ok := low.threads.?; ok {
		h.threads = n
	} else {
		h.threads = min(max(1, os.get_processor_core_count()), 12)
	}
	h.with_filename = low.with_filename.? or_else (low.vimgrep || !h.is_one_file)

	h.before_context, h.after_context = context_get(low.ctx)
	h.passthru = low.ctx.passthru
	if low.mode.kind == .Search && low.mode.search == .Standard {
		if h.heading {
			h.file_separator = ""
		} else if !h.passthru && (h.before_context > 0 || h.after_context > 0) {
			h.file_separator = low.context_separator
		}
	}

	if ln, ok := low.line_number.?; ok {
		h.line_number = ln
	} else if low.quiet || low.mode.kind != .Search {
		h.line_number = false
	} else {
		switch low.mode.search {
		case .Files_With_Matches, .Files_Without_Match, .Count, .Count_Matches:
			h.line_number = false
		case .JSON:
			h.line_number = true
		case .Standard:
			only_stdin := len(h.paths) == 1 && h.paths[0] == "-"
			h.line_number = (h.is_terminal_stdout && !only_stdin) || h.column || low.vimgrep
		}
	}

	// memory maps for up to 10 paths that are all files (the searcher then sees one slice)
	switch low.mmap {
	case .Auto:
		all_files := len(h.paths) <= 10
		for p in h.paths {
			if p == "-" || !os.is_file(p) { all_files = false }
		}
		h.mmap = all_files
	case .Always_Try: h.mmap = true
	case .Never: h.mmap = false
	}

	h.boundary = low.boundary
	h.buffer = low.buffer
	h.byte_offset = low.byte_offset
	h.case_mode = low.case_mode
	h.context_separator = low.context_separator
	h.crlf = low.crlf
	h.field_context_separator = low.field_context_separator
	h.field_match_separator = low.field_match_separator
	h.fixed_strings = low.fixed_strings
	h.hidden = low.hidden
	h.include_zero = low.include_zero
	h.invert_match = low.invert_match
	h.max_columns = low.max_columns
	h.max_columns_preview = low.max_columns_preview
	h.max_count = low.max_count
	h.multiline = low.multiline
	h.no_ignore_dot = low.no_ignore_dot
	h.no_ignore_exclude = low.no_ignore_exclude
	h.no_ignore_vcs = low.no_ignore_vcs
	h.no_require_git = low.no_require_git
	h.null_data = low.null_data
	h.only_matching = low.only_matching
	h.path_separator = low.path_separator
	h.replace = low.replace
	// statistics: --stats, and always for --json (its summary message)
	h.stats = low.mode.kind == .Search && (low.stats || low.mode.search == .JSON)
	h.stop_on_nonmatch = low.stop_on_nonmatch
	h.trim = low.trim
	h.vimgrep = low.vimgrep
	h.no_messages = low.no_messages
	h.no_ignore_messages = low.no_ignore_messages
	h.no_ignore_parent = low.no_ignore_parent
	h.no_ignore_global = low.no_ignore_global
	h.no_ignore_files = low.no_ignore_files
	h.ignore_file = low.ignore_file
	h.ignore_file_case_insensitive = low.ignore_file_case_insensitive
	h.max_depth = low.max_depth
	h.max_filesize = low.max_filesize
	h.follow = low.follow
	h.one_file_system = low.one_file_system
	h.sort = low.sort
	h.no_unicode = low.no_unicode
	h.multiline_dotall = low.multiline_dotall

	// file types: the defaults, then each --type-add/--type-clear/-t/-T in order
	tb: Types_Builder
	types_builder_add_defaults(&tb)
	for c in low.type_changes {
		switch c.kind {
		case .Clear: types_builder_clear(&tb, c.value)
		case .Add:
			if e, bad := types_builder_add_def(&tb, c.value).?; bad { return h, e }
		case .Select: types_builder_select(&tb, c.value, false)
		case .Negate: types_builder_select(&tb, c.value, true)
		}
	}
	types, terr := types_builder_build(&tb)
	if e, bad := terr.?; bad { return h, e }
	h.types = types

	// --glob and --iglob: gitignore lines rooted at the current directory, the verdicts
	// inverted (Override); --glob-case-insensitive for all, --iglob always
	if len(low.globs) > 0 || len(low.iglobs) > 0 {
		cwd, _ := os.get_working_directory(context.allocator)
		g := gitignore_new(cwd)
		g.case_insensitive = low.glob_case_insensitive
		for glob in low.globs {
			if e, bad := gitignore_add_line(g, glob).?; bad { return h, e }
		}
		g.case_insensitive = true
		for glob in low.iglobs {
			if e, bad := gitignore_add_line(g, glob).?; bad { return h, e }
		}
		h.overrides = g
	}
	return h, ""
}

matches_possible :: proc(h: ^Hi_Args) -> bool {
	if len(h.patterns) == 0 { return false }
	if n, ok := h.max_count.?; ok && n == 0 { return false }
	return true
}
