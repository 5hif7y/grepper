// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strconv"
import "core:strings"

// The command line, as ripgrep 14.1.1 parses it (crates/core/flags: lowargs.rs, defs.rs,
// parse.rs): every flag, its negation and its aliases, each updating Low_Args the way
// ripgrep's `Flag::update` does. Low_Args is then turned into Hi_Args (hiargs.odin).

Special_Mode :: enum { None, Help_Short, Help_Long, Version_Short, Version_Long, Version_PCRE2 }
Search_Mode :: enum { Standard, Files_With_Matches, Files_Without_Match, Count, Count_Matches, JSON }
Mode_Kind :: enum { Search, Files, Types, Generate }
Generate_Mode :: enum { Man, Complete_Bash, Complete_Zsh, Complete_Fish, Complete_PowerShell }

Mode :: struct {
	kind:     Mode_Kind,
	search:   Search_Mode,
	generate: Generate_Mode,
}

Binary_Mode :: enum { Auto, Search_And_Suppress, As_Text }
Boundary_Mode :: enum { None, Line, Word }
Buffer_Mode :: enum { Auto, Line, Block }
Case_Mode :: enum { Sensitive, Insensitive, Smart }
Color_Choice :: enum { Auto, Never, Always, Ansi }
Encoding_Mode :: enum { Auto, Some, Disabled }
Engine_Choice :: enum { Default, Auto, PCRE2 }
Logging_Mode :: enum { None, Debug, Trace }
Mmap_Mode :: enum { Auto, Always_Try, Never }
Sort_Kind :: enum { Path, Last_Modified, Last_Accessed, Created }

Sort_Mode :: struct {
	reverse: bool,
	kind:    Sort_Kind,
}

// -A, -B and -C, or --passthru (ContextMode); the last of -A/-B wins over -C
Context_Mode :: struct {
	passthru: bool,
	before:   Maybe(int),
	after:    Maybe(int),
	both:     Maybe(int),
}

context_get :: proc(c: Context_Mode) -> (before, after: int) {
	if n, ok := c.both.?; ok { before, after = n, n }
	if n, ok := c.before.?; ok { before = n }
	if n, ok := c.after.?; ok { after = n }
	return
}

context_set :: proc(c: ^Context_Mode, which: u8, lines: int) {
	if c.passthru { c^ = {} }
	switch which {
	case 'A': c.after = lines
	case 'B': c.before = lines
	case: c.both = lines
	}
}

Pattern_Source :: struct {
	is_file: bool,
	value:   string,
}

Type_Change_Kind :: enum { Clear, Add, Select, Negate }
Type_Change :: struct {
	kind:  Type_Change_Kind,
	value: string,
}

Low_Args :: struct {
	special:              Special_Mode,
	mode:                 Mode,
	positional:           [dynamic]string,
	patterns:             [dynamic]Pattern_Source,
	binary:               Binary_Mode,
	boundary:             Boundary_Mode,
	buffer:               Buffer_Mode,
	byte_offset:          bool,
	case_mode:            Case_Mode,
	color:                Color_Choice,
	colors:               [dynamic]User_Color_Spec,
	column:               Maybe(bool),
	ctx:                  Context_Mode,
	context_separator:    Maybe(string),   // nil: disabled
	crlf:                 bool,
	dfa_size_limit:       Maybe(u64),
	encoding:             Encoding_Mode,
	encoding_label:       string,
	engine:               Engine_Choice,
	field_context_separator: string,
	field_match_separator: string,
	fixed_strings:        bool,
	follow:               bool,
	glob_case_insensitive: bool,
	globs:                [dynamic]string,
	heading:              Maybe(bool),
	hidden:               bool,
	hostname_bin:         string,
	hyperlink_format:     string,
	iglobs:               [dynamic]string,
	ignore_file:          [dynamic]string,
	ignore_file_case_insensitive: bool,
	include_zero:         bool,
	invert_match:         bool,
	line_number:          Maybe(bool),
	logging:              Logging_Mode,
	max_columns:          Maybe(u64),
	max_columns_preview:  bool,
	max_count:            Maybe(u64),
	max_depth:            Maybe(int),
	max_filesize:         Maybe(u64),
	mmap:                 Mmap_Mode,
	multiline:            bool,
	multiline_dotall:     bool,
	no_config:            bool,
	no_ignore_dot:        bool,
	no_ignore_exclude:    bool,
	no_ignore_files:      bool,
	no_ignore_global:     bool,
	no_ignore_messages:   bool,
	no_ignore_parent:     bool,
	no_ignore_vcs:        bool,
	no_messages:          bool,
	no_require_git:       bool,
	no_unicode:           bool,
	null:                 bool,
	null_data:            bool,
	one_file_system:      bool,
	only_matching:        bool,
	path_separator:       Maybe(u8),
	pre:                  string,
	pre_glob:             [dynamic]string,
	quiet:                bool,
	regex_size_limit:     Maybe(u64),
	replace:              Maybe(string),
	search_zip:           bool,
	sort:                 Maybe(Sort_Mode),
	stats:                bool,
	stop_on_nonmatch:     bool,
	threads:              Maybe(int),
	trim:                 bool,
	type_changes:         [dynamic]Type_Change,
	unrestricted:         int,
	vimgrep:              bool,
	with_filename:        Maybe(bool),
}

low_args_default :: proc() -> (a: Low_Args) {
	a.context_separator = "--"
	a.field_context_separator = "-"
	a.field_match_separator = ":"
	return
}

// ripgrep's Mode::update: in 14.1.1 every mode replaces the previous one (its intent, that a
// search mode not override --files, is not what the code does: `--files -c` counts)
mode_update :: proc(m: ^Mode, new: Mode) {
	m^ = new
}

Flag_Value :: struct {
	is_switch: bool,
	on:        bool,      // a switch: true, or false for its negation
	value:     string,
}

Err :: Maybe(string)

Update_Proc :: #type proc(v: Flag_Value, a: ^Low_Args) -> Err

Flag :: struct {
	long:      string,
	short:     u8,
	negated:   string,
	aliases:   []string,
	is_switch: bool,
	update:    Update_Proc,
}

// ripgrep's convert::usize / u64: Rust's integer parsing, its messages
convert_u64 :: proc(s: string) -> (n: u64, err: Err) {
	if len(s) == 0 { return 0, "value is not a valid number: cannot parse integer from empty string" }
	t := s
	if t[0] == '+' { t = t[1:] }
	if len(t) == 0 { return 0, "value is not a valid number: invalid digit found in string" }
	for c in transmute([]u8)t {
		if c < '0' || c > '9' { return 0, "value is not a valid number: invalid digit found in string" }
		d := u64(c - '0')
		if n > (max(u64) - d) / 10 { return 0, "value is not a valid number: number too large to fit in target type" }
		n = n * 10 + d
	}
	return n, nil
}

convert_usize :: proc(s: string) -> (n: int, err: Err) {
	v, e := convert_u64(s)
	if e != nil { return 0, e }
	if v > u64(max(int)) { return 0, "value is not a valid number: number too large to fit in target type" }
	return int(v), nil
}

// grep-cli's parse_human_readable_size: digits with an optional K, M or G suffix
convert_human :: proc(s: string) -> (n: u64, err: Err) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { i += 1 }
	if i == 0 || len(s) - i > 1 {
		return 0, strings.concatenate({"invalid format for size '", s, "', which should be a non-empty sequence of digits followed by an optional 'K', 'M' or 'G' suffix"})
	}
	v, e := convert_u64(s[:i])
	if e != nil {
		return 0, strings.concatenate({"failed to parse '", s, "' as a number"})
	}
	mult: u64 = 1
	if i < len(s) {
		switch s[i] {
		case 'K': mult = 1 << 10
		case 'M': mult = 1 << 20
		case 'G': mult = 1 << 30
		case: return 0, strings.concatenate({"invalid size suffix '", s[i:], "'"})
		}
	}
	if mult > 1 && v > max(u64) / mult {
		return 0, strings.concatenate({"size too big in '", s, "'"})
	}
	return v * mult, nil
}

// bstr's unescape_bytes: \n \r \t \\ \0 \xNN; any other escape is kept as written
unescape_bytes :: proc(s: string) -> string {
	b: strings.Builder
	hex :: proc(c: u8) -> (int, bool) {
		switch c {
		case '0' ..= '9': return int(c - '0'), true
		case 'a' ..= 'f': return int(c - 'a' + 10), true
		case 'A' ..= 'F': return int(c - 'A' + 10), true
		}
		return 0, false
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c != '\\' || i + 1 >= len(s) {
			strings.write_byte(&b, c)
			continue
		}
		n := s[i + 1]
		switch n {
		case 'n': strings.write_byte(&b, '\n'); i += 1
		case 'r': strings.write_byte(&b, '\r'); i += 1
		case 't': strings.write_byte(&b, '\t'); i += 1
		case '\\': strings.write_byte(&b, '\\'); i += 1
		case '0': strings.write_byte(&b, 0); i += 1
		case 'x':
			if i + 3 < len(s) {
				hi, ok1 := hex(s[i + 2])
				lo, ok2 := hex(s[i + 3])
				if ok1 && ok2 {
					strings.write_byte(&b, u8(hi * 16 + lo))
					i += 3
					continue
				}
			}
			strings.write_byte(&b, '\\')
		case:
			strings.write_byte(&b, '\\')
		}
	}
	return strings.to_string(b)
}

sw :: proc(v: Flag_Value) -> bool { return v.on }

FLAGS := [?]Flag{
	{long = "after-context", short = 'A', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_usize(v.value) or_return
		context_set(&a.ctx, 'A', n); return nil
	}},
	{long = "auto-hybrid-regex", negated = "no-auto-hybrid-regex", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.engine = .Auto if sw(v) else .Default; return nil
	}},
	{long = "before-context", short = 'B', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_usize(v.value) or_return
		context_set(&a.ctx, 'B', n); return nil
	}},
	{long = "binary", negated = "no-binary", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.binary = .Search_And_Suppress if sw(v) else .Auto; return nil
	}},
	{long = "block-buffered", negated = "no-block-buffered", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.buffer = .Block if sw(v) else .Auto; return nil
	}},
	{long = "byte-offset", short = 'b', negated = "no-byte-offset", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.byte_offset = sw(v); return nil
	}},
	{long = "case-sensitive", short = 's', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.case_mode = .Sensitive; return nil
	}},
	{long = "color", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		switch v.value {
		case "never": a.color = .Never
		case "auto": a.color = .Auto
		case "always": a.color = .Always
		case "ansi": a.color = .Ansi
		case: return strings.concatenate({"choice '", v.value, "' is unrecognized"})
		}
		return nil
	}},
	{long = "colors", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		spec := parse_user_color_spec(v.value) or_return
		append(&a.colors, spec); return nil
	}},
	{long = "column", negated = "no-column", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.column = sw(v); return nil
	}},
	{long = "context", short = 'C', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_usize(v.value) or_return
		context_set(&a.ctx, 'C', n); return nil
	}},
	{long = "context-separator", negated = "no-context-separator", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if v.is_switch { a.context_separator = nil } else { a.context_separator = unescape_bytes(v.value) }
		return nil
	}},
	{long = "count", short = 'c', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Search, search = .Count}); return nil
	}},
	{long = "count-matches", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Search, search = .Count_Matches}); return nil
	}},
	{long = "crlf", negated = "no-crlf", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.crlf = sw(v)
		if a.crlf { a.null_data = false }
		return nil
	}},
	{long = "debug", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.logging = .Debug; return nil
	}},
	{long = "dfa-size-limit", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_human(v.value) or_return
		a.dfa_size_limit = n; return nil
	}},
	{long = "encoding", short = 'E', negated = "no-encoding", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if v.is_switch { a.encoding = .Auto; return nil }
		switch v.value {
		case "auto": a.encoding = .Auto
		case "none": a.encoding = .Disabled
		case:
			// the label is checked when -E is ported (hi_from_low refuses it until then)
			a.encoding = .Some
			a.encoding_label = v.value
		}
		return nil
	}},
	{long = "engine", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		switch v.value {
		case "default": a.engine = .Default
		case "pcre2": a.engine = .PCRE2
		case "auto": a.engine = .Auto
		case: return strings.concatenate({"unrecognized regex engine '", v.value, "'"})
		}
		return nil
	}},
	{long = "field-context-separator", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.field_context_separator = unescape_bytes(v.value); return nil
	}},
	{long = "field-match-separator", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.field_match_separator = unescape_bytes(v.value); return nil
	}},
	{long = "file", short = 'f', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.patterns, Pattern_Source{true, v.value}); return nil
	}},
	{long = "files", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Files}); return nil
	}},
	{long = "files-with-matches", short = 'l', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Search, search = .Files_With_Matches}); return nil
	}},
	{long = "files-without-match", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Search, search = .Files_Without_Match}); return nil
	}},
	{long = "fixed-strings", short = 'F', negated = "no-fixed-strings", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.fixed_strings = sw(v); return nil
	}},
	{long = "follow", short = 'L', negated = "no-follow", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.follow = sw(v); return nil
	}},
	{long = "generate", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		g: Generate_Mode
		switch v.value {
		case "man": g = .Man
		case "complete-bash": g = .Complete_Bash
		case "complete-zsh": g = .Complete_Zsh
		case "complete-fish": g = .Complete_Fish
		case "complete-powershell": g = .Complete_PowerShell
		case: return strings.concatenate({"choice '", v.value, "' is unrecognized"})
		}
		mode_update(&a.mode, {kind = .Generate, generate = g}); return nil
	}},
	{long = "glob", short = 'g', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.globs, v.value); return nil
	}},
	{long = "glob-case-insensitive", negated = "no-glob-case-insensitive", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.glob_case_insensitive = sw(v); return nil
	}},
	{long = "heading", negated = "no-heading", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.heading = sw(v); return nil
	}},
	{long = "help", short = 'h', is_switch = true, update = nil},
	{long = "hidden", short = '.', negated = "no-hidden", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.hidden = sw(v); return nil
	}},
	{long = "hostname-bin", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.hostname_bin = v.value; return nil
	}},
	{long = "hyperlink-format", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.hyperlink_format = v.value; return nil
	}},
	{long = "iglob", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.iglobs, v.value); return nil
	}},
	{long = "ignore-case", short = 'i', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.case_mode = .Insensitive; return nil
	}},
	{long = "ignore-file", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.ignore_file, v.value); return nil
	}},
	{long = "ignore-file-case-insensitive", negated = "no-ignore-file-case-insensitive", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.ignore_file_case_insensitive = sw(v); return nil
	}},
	{long = "include-zero", negated = "no-include-zero", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.include_zero = sw(v); return nil
	}},
	{long = "invert-match", short = 'v', negated = "no-invert-match", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.invert_match = sw(v); return nil
	}},
	{long = "json", negated = "no-json", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if sw(v) {
			mode_update(&a.mode, {kind = .Search, search = .JSON})
		} else if a.mode.kind == .Search && a.mode.search == .JSON {
			mode_update(&a.mode, {kind = .Search, search = .Standard})
		}
		return nil
	}},
	{long = "line-buffered", negated = "no-line-buffered", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.buffer = .Line if sw(v) else .Auto; return nil
	}},
	{long = "line-number", short = 'n', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.line_number = true; return nil
	}},
	{long = "no-line-number", short = 'N', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.line_number = false; return nil
	}},
	{long = "line-regexp", short = 'x', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.boundary = .Line; return nil
	}},
	{long = "max-columns", short = 'M', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_u64(v.value) or_return
		if n == 0 { a.max_columns = nil } else { a.max_columns = n }
		return nil
	}},
	{long = "max-columns-preview", negated = "no-max-columns-preview", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.max_columns_preview = sw(v); return nil
	}},
	{long = "max-count", short = 'm', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_u64(v.value) or_return
		a.max_count = n; return nil
	}},
	{long = "max-depth", short = 'd', aliases = {"maxdepth"}, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_usize(v.value) or_return
		a.max_depth = n; return nil
	}},
	{long = "max-filesize", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_human(v.value) or_return
		a.max_filesize = n; return nil
	}},
	{long = "mmap", negated = "no-mmap", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.mmap = .Always_Try if sw(v) else .Never; return nil
	}},
	{long = "multiline", short = 'U', negated = "no-multiline", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.multiline = sw(v)
		if a.multiline { a.stop_on_nonmatch = false }
		return nil
	}},
	{long = "multiline-dotall", negated = "no-multiline-dotall", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.multiline_dotall = sw(v); return nil
	}},
	{long = "no-config", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_config = true; return nil
	}},
	{long = "no-ignore", negated = "ignore", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		yes := sw(v)
		a.no_ignore_dot, a.no_ignore_exclude, a.no_ignore_global, a.no_ignore_parent, a.no_ignore_vcs = yes, yes, yes, yes, yes
		return nil
	}},
	{long = "no-ignore-dot", negated = "ignore-dot", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_dot = sw(v); return nil
	}},
	{long = "no-ignore-exclude", negated = "ignore-exclude", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_exclude = sw(v); return nil
	}},
	{long = "no-ignore-files", negated = "ignore-files", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_files = sw(v); return nil
	}},
	{long = "no-ignore-global", negated = "ignore-global", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_global = sw(v); return nil
	}},
	{long = "no-ignore-messages", negated = "ignore-messages", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_messages = sw(v); return nil
	}},
	{long = "no-ignore-parent", negated = "ignore-parent", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_parent = sw(v); return nil
	}},
	{long = "no-ignore-vcs", negated = "ignore-vcs", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_ignore_vcs = sw(v); return nil
	}},
	{long = "no-messages", negated = "messages", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_messages = sw(v); return nil
	}},
	{long = "no-pcre2-unicode", negated = "pcre2-unicode", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_unicode = sw(v); return nil
	}},
	{long = "no-require-git", negated = "require-git", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_require_git = sw(v); return nil
	}},
	{long = "no-unicode", negated = "unicode", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.no_unicode = sw(v); return nil
	}},
	{long = "null", short = '0', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.null = true; return nil
	}},
	{long = "null-data", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.crlf = false
		a.null_data = true; return nil
	}},
	{long = "one-file-system", negated = "no-one-file-system", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.one_file_system = sw(v); return nil
	}},
	{long = "only-matching", short = 'o', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.only_matching = true; return nil
	}},
	{long = "path-separator", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		raw := unescape_bytes(v.value)
		switch len(raw) {
		case 0: a.path_separator = nil
		case 1: a.path_separator = raw[0]
		case:
			n: [32]u8
			return strings.concatenate({"A path separator must be exactly one byte, but the given separator is ",
				strconv.write_int(n[:], i64(len(raw)), 10), " bytes: ", v.value,
				"\nIn some shells on Windows '/' is automatically expanded. Use '//' instead."})
		}
		return nil
	}},
	{long = "passthru", aliases = {"passthrough"}, is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.ctx = {passthru = true}; return nil
	}},
	{long = "pcre2", short = 'P', negated = "no-pcre2", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.engine = .PCRE2 if sw(v) else .Default; return nil
	}},
	{long = "pcre2-version", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.special = .Version_PCRE2; return nil
	}},
	{long = "pre", negated = "no-pre", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if v.is_switch { a.pre = ""; return nil }
		a.pre = v.value
		if a.pre != "" { a.search_zip = false }
		return nil
	}},
	{long = "pre-glob", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.pre_glob, v.value); return nil
	}},
	{long = "pretty", short = 'p', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.color = .Always
		a.heading = true
		a.line_number = true; return nil
	}},
	{long = "quiet", short = 'q', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.quiet = true; return nil
	}},
	{long = "regex-size-limit", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_human(v.value) or_return
		a.regex_size_limit = n; return nil
	}},
	{long = "regexp", short = 'e', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.patterns, Pattern_Source{false, v.value}); return nil
	}},
	{long = "replace", short = 'r', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.replace = v.value; return nil
	}},
	{long = "search-zip", short = 'z', negated = "no-search-zip", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if sw(v) { a.pre = ""; a.search_zip = true } else { a.search_zip = false }
		return nil
	}},
	{long = "smart-case", short = 'S', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.case_mode = .Smart; return nil
	}},
	{long = "sort-files", negated = "no-sort-files", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		if sw(v) { a.sort = Sort_Mode{false, .Path} } else { a.sort = nil }
		return nil
	}},
	{long = "sort", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		return update_sort(v.value, false, a)
	}},
	{long = "sortr", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		return update_sort(v.value, true, a)
	}},
	{long = "stats", negated = "no-stats", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.stats = sw(v); return nil
	}},
	{long = "stop-on-nonmatch", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.stop_on_nonmatch = true
		a.multiline = false; return nil
	}},
	{long = "text", short = 'a', negated = "no-text", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.binary = .As_Text if sw(v) else .Auto; return nil
	}},
	{long = "threads", short = 'j', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		n := convert_usize(v.value) or_return
		if n == 0 { a.threads = nil } else { a.threads = n }
		return nil
	}},
	{long = "trace", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.logging = .Trace; return nil
	}},
	{long = "trim", negated = "no-trim", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.trim = sw(v); return nil
	}},
	{long = "type", short = 't', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.type_changes, Type_Change{.Select, v.value}); return nil
	}},
	{long = "type-add", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.type_changes, Type_Change{.Add, v.value}); return nil
	}},
	{long = "type-clear", update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.type_changes, Type_Change{.Clear, v.value}); return nil
	}},
	{long = "type-not", short = 'T', update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		append(&a.type_changes, Type_Change{.Negate, v.value}); return nil
	}},
	{long = "type-list", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		mode_update(&a.mode, {kind = .Types}); return nil
	}},
	{long = "unrestricted", short = 'u', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.unrestricted += 1
		if a.unrestricted > 3 { return "flag can only be repeated up to 3 times" }
		on := Flag_Value{is_switch = true, on = true}
		switch a.unrestricted {
		case 1: return flag_by_long("no-ignore").update(on, a)
		case 2: a.hidden = true
		case 3: a.binary = .Search_And_Suppress
		}
		return nil
	}},
	{long = "version", short = 'V', is_switch = true, update = nil},
	{long = "vimgrep", is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.vimgrep = true; return nil
	}},
	{long = "with-filename", short = 'H', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.with_filename = true; return nil
	}},
	{long = "no-filename", short = 'I', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.with_filename = false; return nil
	}},
	{long = "word-regexp", short = 'w', is_switch = true, update = proc(v: Flag_Value, a: ^Low_Args) -> Err {
		a.boundary = .Word; return nil
	}},
}

update_sort :: proc(value: string, reverse: bool, a: ^Low_Args) -> Err {
	kind: Sort_Kind
	switch value {
	case "none": a.sort = nil; return nil
	case "path": kind = .Path
	case "modified": kind = .Last_Modified
	case "accessed": kind = .Last_Accessed
	case "created": kind = .Created
	case: return strings.concatenate({"choice '", value, "' is unrecognized"})
	}
	a.sort = Sort_Mode{reverse, kind}
	return nil
}

flag_by_long :: proc(name: string) -> ^Flag {
	for &f in FLAGS {
		if f.long == name { return &f }
	}
	return nil
}

Flag_Match :: struct {
	flag:    ^Flag,
	negated: bool,
	display: string,     // "--name" or "-c", as ripgrep's messages print it
}

find_long :: proc(name: string) -> (m: Flag_Match, ok: bool) {
	for &f in FLAGS {
		if f.long == name {
			return {&f, false, strings.concatenate({"--", name})}, true
		}
		if f.negated != "" && f.negated == name {
			return {&f, true, strings.concatenate({"--", name})}, true
		}
		for al in f.aliases {
			if al == name { return {&f, false, strings.concatenate({"--", name})}, true }
		}
	}
	return
}

find_short :: proc(c: u8) -> (m: Flag_Match, ok: bool) {
	for &f in FLAGS {
		if f.short == c && c != 0 {
			return {&f, false, strings.concatenate({"-", string([]u8{c})})}, true
		}
	}
	return
}

// ripgrep's parse loop over lexopt: `--` ends the flags; `--name=value`; `-abc` is a cluster
// of short flags, the first one taking a value taking the rest of the cluster (`-j1`, an `=`
// after the flag is skipped); a flag's value may be the next argument whatever it starts with;
// a lone `-` is a positional argument.
parse_low :: proc(raw: []string, a: ^Low_Args) -> (err: string) {
	i := 0
	no_more := false
	for i < len(raw) {
		arg := raw[i]
		i += 1
		if no_more || len(arg) < 2 || arg[0] != '-' {
			append(&a.positional, arg)
			continue
		}
		if arg == "--" {
			no_more = true
			continue
		}
		if arg[1] == '-' {
			name := arg[2:]
			attached: Maybe(string)
			if eq := strings.index_byte(name, '='); eq >= 0 {
				attached = name[eq + 1:]
				name = name[:eq]
			}
			if name == "help" { a.special = .Help_Long; continue }
			if name == "version" { a.special = .Version_Long; continue }
			m, ok := find_long(name)
			if !ok {
				msg := strings.concatenate({"unrecognized flag --", name})
				if s := suggest(name); s != "" {
					msg = strings.concatenate({msg, "\n\n", s})
				}
				return msg
			}
			v := Flag_Value{}
			if m.negated || m.flag.is_switch {
				if val, has := attached.?; has {
					return strings.concatenate({"invalid CLI arguments: unexpected argument for option '--", name, "': \"", val, "\""})
				}
				v = {is_switch = true, on = !m.negated}
			} else if val, has := attached.?; has {
				v = {value = val}
			} else {
				if i >= len(raw) {
					return strings.concatenate({"missing value for flag ", m.display, ": missing argument for option '--", name, "'"})
				}
				v = {value = raw[i]}
				i += 1
			}
			if e, bad := m.flag.update(v, a).?; bad {
				return strings.concatenate({"error parsing flag ", m.display, ": ", e})
			}
			continue
		}
		// a cluster of short flags
		for k := 1; k < len(arg); k += 1 {
			c := arg[k]
			if c == 'h' { a.special = .Help_Short; continue }
			if c == 'V' { a.special = .Version_Short; continue }
			m, ok := find_short(c)
			if !ok {
				// lexopt yields the whole UTF-8 character
				n := 1
				if c >= 0x80 {
					for k + n < len(arg) && arg[k + n] & 0xC0 == 0x80 { n += 1 }
				}
				return strings.concatenate({"unrecognized flag -", arg[k:k + n]})
			}
			if m.flag.is_switch {
				if e, bad := m.flag.update({is_switch = true, on = true}, a).?; bad {
					return strings.concatenate({"error parsing flag ", m.display, ": ", e})
				}
				continue
			}
			val: string
			if k + 1 < len(arg) {
				val = arg[k + 1:]
				if val[0] == '=' { val = val[1:] }
			} else {
				if i >= len(raw) {
					return strings.concatenate({"missing value for flag ", m.display, ": missing argument for option '", m.display, "'"})
				}
				val = raw[i]
				i += 1
			}
			if e, bad := m.flag.update({value = val}, a).?; bad {
				return strings.concatenate({"error parsing flag ", m.display, ": ", e})
			}
			break
		}
	}
	return ""
}

// "similar flags that are available": names whose 3-gram sets have a Jaccard index of at
// least 0.4 with the unknown one (parse.rs's suggest)
suggest :: proc(unknown: string) -> string {
	ngrams :: proc(s: string) -> map[string]bool {
		set := make(map[string]bool, 16, context.temp_allocator)
		switch len(s) {
		case 0: set["!!!"] = true
		case 1: set[strings.concatenate({s, "!!"}, context.temp_allocator)] = true
		case 2: set[strings.concatenate({s, "!"}, context.temp_allocator)] = true
		case:
			for i in 0 ..= len(s) - 3 { set[s[i:i + 3]] = true }
		}
		return set
	}
	jaccard :: proc(a, b: map[string]bool) -> f64 {
		inter := 0
		for k in a { if k in b { inter += 1 } }
		union_n := len(a) + len(b) - inter
		return f64(inter) / f64(union_n)
	}
	given := ngrams(unknown)
	names: [dynamic]string
	names.allocator = context.temp_allocator
	for f in FLAGS {
		if jaccard(given, ngrams(f.long)) >= 0.4 { append(&names, f.long) }
		if f.negated != "" && jaccard(given, ngrams(f.negated)) >= 0.4 { append(&names, f.negated) }
		for al in f.aliases {
			if jaccard(given, ngrams(al)) >= 0.4 { append(&names, al) }
		}
	}
	if len(names) == 0 { return "" }
	b: strings.Builder
	strings.write_string(&b, "similar flags that are available: ")
	for n, i in names {
		if i > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, "--")
		strings.write_string(&b, n)
	}
	return strings.to_string(b)
}
