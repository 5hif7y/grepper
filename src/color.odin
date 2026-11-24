// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strconv"
import "core:strings"

// Colours as ripgrep's printer (crates/printer/src/color.rs) and termcolor's ANSI writer:
// `--colors` specs merged over the defaults, written as termcolor writes them.

Color_Kind :: enum { None, Black, Blue, Green, Red, Cyan, Magenta, Yellow, White, Ansi256, Rgb }

Color :: struct {
	kind:    Color_Kind,
	n:       u8,          // Ansi256
	r, g, b: u8,          // Rgb
}

// termcolor's ColorSpec; `reset` is always true for ripgrep's specs
Color_Spec :: struct {
	fg, bg:    Color,
	bold:      bool,
	intense:   bool,
	underline: bool,
}

color_spec_is_none :: proc(s: Color_Spec) -> bool {
	return s.fg.kind == .None && s.bg.kind == .None && !s.bold && !s.underline
}

Out_Type :: enum { Path, Line, Column, Match }
Spec_Value_Kind :: enum { None, Fg, Bg, Style }
Style :: enum { Bold, No_Bold, Intense, No_Intense, Underline, No_Underline }

User_Color_Spec :: struct {
	ty:    Out_Type,
	kind:  Spec_Value_Kind,
	color: Color,
	style: Style,
}

Color_Specs :: struct {
	path, line, column, matched: Color_Spec,
}

// the defaults: path magenta on Unix and cyan on Windows (COLOR_PATH_DEFAULT), line green,
// match bold red
DEFAULT_COLOR_SPECS := [?]User_Color_Spec{
	{ty = .Path, kind = .Fg, color = {kind = COLOR_PATH_DEFAULT}},
	{ty = .Line, kind = .Fg, color = {kind = .Green}},
	{ty = .Match, kind = .Fg, color = {kind = .Red}},
	{ty = .Match, kind = .Style, style = .Bold},
}

default_color_specs :: proc() -> []User_Color_Spec {
	return DEFAULT_COLOR_SPECS[:]
}

merge_spec :: proc(u: User_Color_Spec, c: ^Color_Spec) {
	switch u.kind {
	case .None: c^ = {}
	case .Fg: c.fg = u.color
	case .Bg: c.bg = u.color
	case .Style:
		switch u.style {
		case .Bold: c.bold = true
		case .No_Bold: c.bold = false
		case .Intense: c.intense = true
		case .No_Intense: c.intense = false
		case .Underline: c.underline = true
		case .No_Underline: c.underline = false
		}
	}
}

color_specs_new :: proc(specs: []User_Color_Spec) -> (m: Color_Specs) {
	for s in specs {
		switch s.ty {
		case .Path: merge_spec(s, &m.path)
		case .Line: merge_spec(s, &m.line)
		case .Column: merge_spec(s, &m.column)
		case .Match: merge_spec(s, &m.matched)
		}
	}
	return
}

// termcolor's Color::from_str
parse_color :: proc(s: string) -> (c: Color, err: Err) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "black": return {kind = .Black}, nil
	case "blue": return {kind = .Blue}, nil
	case "green": return {kind = .Green}, nil
	case "red": return {kind = .Red}, nil
	case "cyan": return {kind = .Cyan}, nil
	case "magenta": return {kind = .Magenta}, nil
	case "yellow": return {kind = .Yellow}, nil
	case "white": return {kind = .White}, nil
	}
	parse_u8 :: proc(s: string) -> (u8, bool) {
		if strings.has_prefix(s, "0x") {
			n, ok := strconv.parse_u64_of_base(s[2:], 16)
			return u8(n), ok && n <= 255 && len(s) > 2
		}
		n, ok := strconv.parse_u64_of_base(s, 10)
		return u8(n), ok && n <= 255 && len(s) > 0
	}
	codes := strings.split(s, ",", context.temp_allocator)
	if len(codes) == 1 {
		if n, ok := parse_u8(codes[0]); ok {
			return {kind = .Ansi256, n = n}, nil
		}
		if strings.index_byte(s, ',') < 0 && !(len(s) > 0 && (s[0] >= '0' && s[0] <= '9')) {
			return {}, strings.concatenate({"unrecognized color name '", s, "'. Choose from: black, blue, green, red, cyan, magenta, yellow, white"})
		}
		return {}, strings.concatenate({"unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is '", s, "'"})
	}
	if len(codes) == 3 {
		r, ok1 := parse_u8(codes[0])
		g, ok2 := parse_u8(codes[1])
		b, ok3 := parse_u8(codes[2])
		if ok1 && ok2 && ok3 {
			return {kind = .Rgb, r = r, g = g, b = b}, nil
		}
	}
	return {}, strings.concatenate({"unrecognized RGB color triple, should be '[0-255],[0-255],[0-255]' (or a hex triple), but is '", s, "'"})
}

parse_user_color_spec :: proc(s: string) -> (u: User_Color_Spec, err: Err) {
	pieces := strings.split(s, ":", context.temp_allocator)
	invalid := strings.concatenate({"invalid color spec format: '", s, "'. Valid format is '(path|line|column|match):(fg|bg|style):(value)'."})
	if len(pieces) <= 1 || len(pieces) > 3 { return u, invalid }
	switch strings.to_lower(pieces[0], context.temp_allocator) {
	case "path": u.ty = .Path
	case "line": u.ty = .Line
	case "column": u.ty = .Column
	case "match": u.ty = .Match
	case: return u, strings.concatenate({"unrecognized output type '", pieces[0], "'. Choose from: path, line, column, match."})
	}
	switch strings.to_lower(pieces[1], context.temp_allocator) {
	case "none":
		u.kind = .None
		return u, nil
	case "style":
		if len(pieces) < 3 { return u, invalid }
		u.kind = .Style
		switch strings.to_lower(pieces[2], context.temp_allocator) {
		case "bold": u.style = .Bold
		case "nobold": u.style = .No_Bold
		case "intense": u.style = .Intense
		case "nointense": u.style = .No_Intense
		case "underline": u.style = .Underline
		case "nounderline": u.style = .No_Underline
		case: return u, strings.concatenate({"unrecognized style attribute '", pieces[2], "'. Choose from: nobold, bold, nointense, intense, nounderline, underline."})
		}
		return u, nil
	case "fg", "bg":
		if len(pieces) < 3 { return u, invalid }
		u.kind = .Fg if strings.to_lower(pieces[1], context.temp_allocator) == "fg" else .Bg
		u.color = parse_color(pieces[2]) or_return
		return u, nil
	case:
		return u, strings.concatenate({"unrecognized spec type '", pieces[1], "'. Choose from: fg, bg, style, none."})
	}
}

// termcolor's Ansi::set_color (the reset first, as ripgrep's specs always reset)
write_set_color :: proc(out: ^[dynamic]u8, s: Color_Spec) {
	append(out, "\x1b[0m")
	if s.bold { append(out, "\x1b[1m") }
	if s.underline { append(out, "\x1b[4m") }
	if s.fg.kind != .None { write_color(out, true, s.fg, s.intense) }
	if s.bg.kind != .None { write_color(out, false, s.bg, s.intense) }
}

write_reset :: proc(out: ^[dynamic]u8) {
	append(out, "\x1b[0m")
}

write_color :: proc(out: ^[dynamic]u8, fg: bool, c: Color, intense: bool) {
	tmp: [8]u8
	num :: proc(out: ^[dynamic]u8, n: u8) {
		t: [8]u8
		append(out, strconv.write_uint(t[:], u64(n), 10))
	}
	var_code :: proc(out: ^[dynamic]u8, fg: bool, n: u8) {
		append(out, "\x1b[38;5;" if fg else "\x1b[48;5;")
		num(out, n)
		append(out, "m")
	}
	#partial switch c.kind {
	case .Ansi256:
		var_code(out, fg, c.n)
		return
	case .Rgb:
		append(out, "\x1b[38;2;" if fg else "\x1b[48;2;")
		num(out, c.r); append(out, ";")
		num(out, c.g); append(out, ";")
		num(out, c.b); append(out, "m")
		return
	}
	normal, bright: u8
	#partial switch c.kind {
	case .Black: normal, bright = 0, 8
	case .Blue: normal, bright = 4, 12
	case .Green: normal, bright = 2, 10
	case .Red: normal, bright = 1, 9
	case .Cyan: normal, bright = 6, 14
	case .Magenta: normal, bright = 5, 13
	case .Yellow: normal, bright = 3, 11
	case .White: normal, bright = 7, 15
	}
	_ = tmp
	if intense {
		var_code(out, fg, bright)
	} else {
		append(out, "\x1b[3" if fg else "\x1b[4")
		num(out, normal)
		append(out, "m")
	}
}
