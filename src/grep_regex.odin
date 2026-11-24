// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strings"

// ripgrep's grep-regex crate (crates/regex): how a search's patterns become one regex.

// AstAnalysis (ast.rs): smart case looks for a literal and for an uppercase one
Ast_Analysis :: struct {
	any_uppercase: bool,
	any_literal:   bool,
}

ast_analysis :: proc(a: ^Ast) -> (r: Ast_Analysis) {
	analyse(&r, a)
	return
}

@(private="file") done :: proc(r: ^Ast_Analysis) -> bool { return r.any_uppercase && r.any_literal }

@(private="file")
analyse :: proc(r: ^Ast_Analysis, a: ^Ast) {
	if done(r) { return }
	#partial switch a.kind {
	case .Literal: analyse_literal(r, a.lit)
	case .Class_Bracketed: analyse_set(r, &a.bracketed.kind)
	case .Repetition, .Group: analyse(r, a.sub)
	case .Alternation, .Concat:
		for s in a.asts { analyse(r, s) }
	}
}

@(private="file")
analyse_set :: proc(r: ^Ast_Analysis, s: ^Class_Set) {
	if done(r) { return }
	if s.is_op {
		analyse_set(r, s.lhs)
		analyse_set(r, s.rhs)
		return
	}
	analyse_item(r, &s.item)
}

@(private="file")
analyse_item :: proc(r: ^Ast_Analysis, it: ^Class_Set_Item) {
	if done(r) { return }
	#partial switch it.kind {
	case .Literal: analyse_literal(r, it.lit)
	case .Range:
		analyse_literal(r, it.lit)
		analyse_literal(r, it.lit_end)
	case .Bracketed: analyse_set(r, &it.bracketed.kind)
	case .Union:
		for &x in it.items { analyse_item(r, &x) }
	}
}

@(private="file")
analyse_literal :: proc(r: ^Ast_Analysis, l: Ast_Literal) {
	r.any_literal = true
	r.any_uppercase = r.any_uppercase || is_uppercase(l.c)
}

// char::is_uppercase: the Uppercase property
is_uppercase :: proc(c: rune) -> bool {
	if c < 0x80 { return 'A' <= c && c <= 'Z' }
	for e in UT_PROPERTY_BOOL {
		if e.name != "Uppercase" { continue }
		rs := UT_PROPERTY_BOOL_RANGES[e.start:e.start + e.count]
		lo, hi := 0, len(rs)
		for lo < hi {
			mid := (lo + hi) / 2
			if rs[mid][1] < c { lo = mid + 1 } else { hi = mid }
		}
		return lo < len(rs) && rs[lo][0] <= c
	}
	return false
}

// Config::is_case_insensitive
rg_is_case_insensitive :: proc(h: ^Hi_Args, ast: ^Ast) -> bool {
	switch h.case_mode {
	case .Insensitive: return true
	case .Sensitive: return false
	case .Smart:
		a := ast_analysis(ast)
		return a.any_literal && !a.any_uppercase
	}
	return false
}

// strip.rs: the line terminator removed from what the regex can match; a literal holding it,
// or a class holding only it, is an error
strip_from_match :: proc(h: ^Hir, b: u8) -> (out: ^Hir, err: Maybe(string)) {
	switch h.kind {
	case .Empty: return hir_empty(), nil
	case .Literal:
		for x in h.lit { if x == b { return nil, not_allowed(b) } }
		return hir_literal(h.lit), nil
	case .Class:
		c := class_clone(h.class)
		if len(c.ranges) == 0 { return hir_class(c), nil }
		class_difference(&c, class_new(c.unicode, {{u32(b), u32(b)}}))
		if len(c.ranges) == 0 { return nil, not_allowed(b) }
		return hir_class(c), nil
	case .Look: return hir_look(h.look), nil
	case .Repetition:
		sub := strip_from_match(h.sub, b) or_return
		return hir_rep(h.min, h.max, h.greedy, sub), nil
	case .Capture:
		sub := strip_from_match(h.sub, b) or_return
		return hir_capture(h.index, h.name, sub), nil
	case .Concat, .Alternation:
		xs: [dynamic]^Hir
		for s in h.subs {
			x := strip_from_match(s, b) or_return
			append(&xs, x)
		}
		return hir_concat(xs[:]) if h.kind == .Concat else hir_alternation(xs[:]), nil
	}
	return h, nil
}

// "the literal {:?} is not allowed in a regex", with Rust's Debug of a one-character String
@(private="file")
not_allowed :: proc(b: u8) -> string {
	o: Out
	out_str(&o, "the literal \"")
	write_debug_byte(&o, b)
	out_str(&o, "\" is not allowed in a regex")
	return string(o.buf[:])
}

// ban.rs: with binary detection, a pattern that can only match a NUL is an error
ban_check :: proc(h: ^Hir, b: u8) -> Maybe(string) {
	#partial switch h.kind {
	case .Literal:
		for x in h.lit {
			if x == b {
				o: Out
				out_str(&o, "pattern contains \"")
				write_debug_byte(&o, b)
				out_str(&o, "\" but it is impossible to match")
				return string(o.buf[:])
			}
		}
	case .Class:
		total: u32 = 0
		for r in h.class.ranges { total += r.hi - r.lo + 1 }
		if total == 1 && h.class.ranges[0].lo == u32(b) {
			o: Out
			out_str(&o, "pattern contains \"")
			write_debug_byte(&o, b)
			out_str(&o, "\" but it is impossible to match")
			return string(o.buf[:])
		}
	case .Repetition, .Capture: return ban_check(h.sub, b)
	case .Concat, .Alternation:
		for s in h.subs { if e := ban_check(s, b); e != nil { return e } }
	}
	return nil
}

// ConfiguredHIR::into_whole_line / into_word
into_whole_line :: proc(h: ^Hir, crlf: bool) -> ^Hir {
	return hir_concat({hir_look(.Start_CRLF if crlf else .Start_LF), h, hir_look(.End_CRLF if crlf else .End_LF)})
}

into_word :: proc(h: ^Hir, unicode: bool) -> ^Hir {
	return hir_concat({hir_look(.Word_Start_Half_Unicode if unicode else .Word_Start_Half_Ascii), h, hir_look(.Word_End_Half_Unicode if unicode else .Word_End_Half_Ascii)})
}

// hiargs.rs's suggest_multiline and suggest_text
suggest_multiline :: proc(msg: string) -> string {
	if !(strings.contains(msg, "the literal") && strings.contains(msg, "not allowed")) { return msg }
	return strings.concatenate({msg, "\n\nConsider enabling multiline mode with the --multiline flag (or -U for short).\nWhen multiline mode is enabled, new line characters can be matched."})
}

suggest_text :: proc(msg: string) -> string {
	if !strings.contains(msg, "pattern contains \"\\0\"") { return msg }
	return strings.concatenate({msg, "\n\nConsider enabling text mode with the --text flag (or -a for short). Otherwise,\nbinary detection is enabled and matching a NUL byte is impossible."})
}
