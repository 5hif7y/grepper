// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

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
