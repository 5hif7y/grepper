// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strings"
import "core:unicode/utf8"

// regex-syntax 0.8.4's translator (src/hir/translate.rs) and Unicode class lookup
// (src/unicode.rs): the AST to the HIR under the flags in force at each node. The flags a
// `(?flags)` sets last until its group closes, across the alternation branches that follow,
// as the translator's visitor has them.
//
// Kept as regex-syntax 0.8.4 has it: `\p{name!=value}` is translated as `\p{name=value}`
// (the translator reads the class's `negated` field, not is_negated()).

Hir_Error_Kind :: enum {
	Unicode_Not_Allowed, Invalid_Utf8, Invalid_Line_Terminator, Unicode_Property_Not_Found,
	Unicode_Property_Value_Not_Found, Unicode_Perl_Class_Not_Found, Unicode_Case_Unavailable,
}

Hir_Error :: struct {
	kind:    Hir_Error_Kind,
	pattern: string,
	span:    Span,
}

hir_error_string :: proc(e: Hir_Error) -> string {
	msg: string
	switch e.kind {
	case .Unicode_Not_Allowed: msg = "Unicode not allowed here"
	case .Invalid_Utf8: msg = "pattern can match invalid UTF-8"
	case .Invalid_Line_Terminator: msg = "invalid line terminator, must be ASCII"
	case .Unicode_Property_Not_Found: msg = "Unicode property not found"
	case .Unicode_Property_Value_Not_Found: msg = "Unicode property value not found"
	case .Unicode_Perl_Class_Not_Found: msg = "Unicode-aware Perl class not found (make sure the unicode-perl feature is enabled)"
	case .Unicode_Case_Unavailable: msg = "Unicode-aware case insensitivity matching is not available (make sure the unicode-case feature is enabled)"
	}
	return format_syntax_error(e.pattern, e.span, nil, msg)
}

Trans_Error :: Maybe(Hir_Error)

// Flags: each unset (nil) until a builder option or a (?flags) sets it
Trans_Flags :: struct {
	case_insensitive, multi_line, dot_matches_new_line, swap_greed, unicode, crlf: Maybe(bool),
}

Translator :: struct {
	pattern:         string,
	flags:           Trans_Flags,
	utf8:            bool,
	line_terminator: u8,
}

@(private="file") ci :: proc(t: ^Translator) -> bool { return t.flags.case_insensitive.? or_else false }
@(private="file") uni :: proc(t: ^Translator) -> bool { return t.flags.unicode.? or_else true }

@(private="file")
terr :: proc(t: ^Translator, span: Span, kind: Hir_Error_Kind) -> Hir_Error {
	return {kind = kind, pattern = t.pattern, span = span}
}

// Flags::from_ast merged over the current flags; returns the old ones
@(private="file")
set_flags :: proc(t: ^Translator, f: ^Ast_Flags) -> Trans_Flags {
	old := t.flags
	n: Trans_Flags
	enable := true
	for item in f.items {
		if item.negation { enable = false; continue }
		switch item.flag {
		case .Case_Insensitive: n.case_insensitive = enable
		case .Multi_Line: n.multi_line = enable
		case .Dot_Matches_New_Line: n.dot_matches_new_line = enable
		case .Swap_Greed: n.swap_greed = enable
		case .Unicode: n.unicode = enable
		case .CRLF: n.crlf = enable
		case .Ignore_Whitespace:
		}
	}
	if n.case_insensitive == nil { n.case_insensitive = old.case_insensitive }
	if n.multi_line == nil { n.multi_line = old.multi_line }
	if n.dot_matches_new_line == nil { n.dot_matches_new_line = old.dot_matches_new_line }
	if n.swap_greed == nil { n.swap_greed = old.swap_greed }
	if n.unicode == nil { n.unicode = old.unicode }
	if n.crlf == nil { n.crlf = old.crlf }
	t.flags = n
	return old
}

translate :: proc(t: ^Translator, ast: ^Ast) -> (h: ^Hir, err: Trans_Error) {
	switch ast.kind {
	case .Empty:
		return hir_empty(), nil
	case .Flags:
		set_flags(t, &ast.flags)
		return hir_empty(), nil
	case .Literal:
		c, byte_, is_byte := literal_to_scalar(t, ast.lit) or_return
		if is_byte { return hir_literal(clone_bytes({byte_})), nil }
		if folded, ok := case_fold_char(t, ast.span, c) or_return; ok { return folded, nil }
		buf, n := utf8.encode_rune(c)
		return hir_literal(clone_bytes(buf[:n])), nil
	case .Dot:
		return translate_dot(t, ast.span)
	case .Assertion:
		return translate_assertion(t, ast.assertion), nil
	case .Class_Perl:
		if uni(t) {
			c := perl_unicode_class(ast.cls_perl)
			return hir_class(c), nil
		}
		c := perl_byte_class(t, ast.cls_perl) or_return
		return hir_class(c), nil
	case .Class_Unicode:
		c := unicode_class(t, ast.cls_unicode) or_return
		return hir_class(c), nil
	case .Class_Bracketed:
		c := Hir_Class{unicode = uni(t)}
		class_set(t, &ast.bracketed.kind, &c) or_return
		fold_and_negate(t, ast.bracketed.span, ast.bracketed.negated, &c) or_return
		return hir_class(c), nil
	case .Repetition:
		sub := translate(t, ast.sub) or_return
		mn: u32
		mx: Maybe(u32)
		switch ast.op.kind {
		case .Zero_Or_One: mn, mx = 0, 1
		case .Zero_Or_More: mn = 0
		case .One_Or_More: mn = 1
		case .Range:
			switch ast.op.range_kind {
			case .Exactly: mn, mx = ast.op.min, ast.op.min
			case .At_Least: mn = ast.op.min
			case .Bounded: mn, mx = ast.op.min, ast.op.max
			}
		}
		greedy := !ast.greedy if (t.flags.swap_greed.? or_else false) else ast.greedy
		return hir_rep(mn, mx, greedy, sub), nil
	case .Group:
		old := t.flags
		if ast.group_kind == .Non_Capturing { set_flags(t, &ast.flags) }
		sub := translate(t, ast.sub) or_return
		t.flags = old
		switch ast.group_kind {
		case .Capture_Index: return hir_capture(ast.capture_index, nil, sub), nil
		case .Capture_Name: return hir_capture(ast.capture_name.index, ast.capture_name.name, sub), nil
		case .Non_Capturing: return sub, nil
		}
	case .Concat:
		parts: [dynamic]^Hir
		for s in ast.asts {
			x := translate(t, s) or_return
			if x.kind != .Empty { append(&parts, x) }
		}
		return hir_concat(parts[:]), nil
	case .Alternation:
		parts: [dynamic]^Hir
		for s in ast.asts {
			x := translate(t, s) or_return
			append(&parts, x)
		}
		return hir_alternation(parts[:]), nil
	}
	return hir_empty(), nil
}

clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

@(private="file")
literal_to_scalar :: proc(t: ^Translator, lit: Ast_Literal) -> (c: rune, b: u8, is_byte: bool, err: Trans_Error) {
	if uni(t) { return lit.c, 0, false, nil }
	byte_, ok := ast_literal_byte(lit)
	if !ok { return lit.c, 0, false, nil }
	if byte_ <= 0x7F { return rune(byte_), 0, false, nil }
	if t.utf8 { return 0, 0, false, terr(t, lit.span, .Invalid_Utf8) }
	return 0, byte_, true, nil
}

@(private="file")
case_fold_char :: proc(t: ^Translator, span: Span, c: rune) -> (h: ^Hir, ok: bool, err: Trans_Error) {
	if !ci(t) { return }
	if uni(t) {
		if !case_fold_overlaps(c, c) { return }
		cls := class_new(true, {{u32(c), u32(c)}})
		class_case_fold_simple(&cls)
		return hir_class(cls), true, nil
	}
	if !(('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z')) { return }
	cls := class_new(false, {{u32(c), u32(c)}})
	class_case_fold_simple(&cls)
	return hir_class(cls), true, nil
}

@(private="file")
translate_dot :: proc(t: ^Translator, span: Span) -> (h: ^Hir, err: Trans_Error) {
	lt := t.line_terminator
	if t.utf8 && (!uni(t) || lt > 0x7F) { return nil, terr(t, span, .Invalid_Utf8) }
	crlf := t.flags.crlf.? or_else false
	if t.flags.dot_matches_new_line.? or_else false {
		return hir_dot(.Any_Char if uni(t) else .Any_Byte), nil
	}
	if uni(t) {
		if crlf { return hir_dot(.Any_Char_Except_CRLF), nil }
		if lt > 0x7F { return nil, terr(t, span, .Invalid_Line_Terminator) }
		return hir_dot(.Any_Char_Except, u32(lt)), nil
	}
	if crlf { return hir_dot(.Any_Byte_Except_CRLF), nil }
	return hir_dot(.Any_Byte_Except, u32(lt)), nil
}

@(private="file")
translate_assertion :: proc(t: ^Translator, k: Assertion_Kind) -> ^Hir {
	u := uni(t)
	ml := t.flags.multi_line.? or_else false
	crlf := t.flags.crlf.? or_else false
	switch k {
	case .Start_Line: return hir_look((.Start_CRLF if crlf else .Start_LF) if ml else .Start)
	case .End_Line: return hir_look((.End_CRLF if crlf else .End_LF) if ml else .End)
	case .Start_Text: return hir_look(.Start)
	case .End_Text: return hir_look(.End)
	case .Word_Boundary: return hir_look(.Word_Unicode if u else .Word_Ascii)
	case .Not_Word_Boundary: return hir_look(.Word_Unicode_Negate if u else .Word_Ascii_Negate)
	case .Word_Boundary_Start, .Word_Boundary_Start_Angle: return hir_look(.Word_Start_Unicode if u else .Word_Start_Ascii)
	case .Word_Boundary_End, .Word_Boundary_End_Angle: return hir_look(.Word_End_Unicode if u else .Word_End_Ascii)
	case .Word_Boundary_Start_Half: return hir_look(.Word_Start_Half_Unicode if u else .Word_Start_Half_Ascii)
	case .Word_Boundary_End_Half: return hir_look(.Word_End_Half_Unicode if u else .Word_End_Half_Ascii)
	}
	return nil
}

@(private="file")
fold_and_negate :: proc(t: ^Translator, span: Span, negated: bool, c: ^Hir_Class) -> Trans_Error {
	if ci(t) { class_case_fold_simple(c) }
	if negated { class_negate(c) }
	if !c.unicode && t.utf8 && !class_is_ascii(c^) { return terr(t, span, .Invalid_Utf8) }
	return nil
}

ASCII_CLASS_RANGES := [Class_Ascii_Kind][]Class_Range{
	.Alnum = {{'0', '9'}, {'A', 'Z'}, {'a', 'z'}},
	.Alpha = {{'A', 'Z'}, {'a', 'z'}},
	.Ascii = {{0, 0x7F}},
	.Blank = {{'\t', '\t'}, {' ', ' '}},
	.Cntrl = {{0, 0x1F}, {0x7F, 0x7F}},
	.Digit = {{'0', '9'}},
	.Graph = {{'!', '~'}},
	.Lower = {{'a', 'z'}},
	.Print = {{' ', '~'}},
	.Punct = {{'!', '/'}, {':', '@'}, {'[', '`'}, {'{', '~'}},
	.Space = {{'\t', '\t'}, {'\n', '\n'}, {0x0B, 0x0B}, {0x0C, 0x0C}, {'\r', '\r'}, {' ', ' '}},
	.Upper = {{'A', 'Z'}},
	.Word = {{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}},
	.Xdigit = {{'0', '9'}, {'A', 'F'}, {'a', 'f'}},
}

ascii_class_ranges :: proc(k: Class_Ascii_Kind) -> []Class_Range { return ASCII_CLASS_RANGES[k] }

@(private="file")
perl_unicode_class :: proc(p: Class_Perl) -> Hir_Class {
	c: Hir_Class
	switch p.kind {
	case .Digit: c = unicode_table_class(UT_PERL_DECIMAL_RANGES[:], UT_PERL_DECIMAL[:], "Decimal_Number")
	case .Space: c = unicode_table_class(UT_PERL_SPACE_RANGES[:], UT_PERL_SPACE[:], "White_Space")
	case .Word: c = unicode_table_class(UT_PERL_WORD_RANGES[:], UT_PERL_WORD[:], "PERL_WORD")
	}
	if p.negated { class_negate(&c) }
	return c
}

@(private="file")
perl_byte_class :: proc(t: ^Translator, p: Class_Perl) -> (c: Hir_Class, err: Trans_Error) {
	k: Class_Ascii_Kind
	switch p.kind {
	case .Digit: k = .Digit
	case .Space: k = .Space
	case .Word: k = .Word
	}
	c = class_new(false, ascii_class_ranges(k))
	if p.negated { class_negate(&c) }
	if t.utf8 && !class_is_ascii(c) { return c, terr(t, p.span, .Invalid_Utf8) }
	return c, nil
}

// one bracketed class's set: items unioned, binary operations applied
@(private="file")
class_set :: proc(t: ^Translator, s: ^Class_Set, into: ^Hir_Class) -> Trans_Error {
	if !s.is_op { return class_item(t, &s.item, into) }
	lhs := Hir_Class{unicode = into.unicode}
	rhs := Hir_Class{unicode = into.unicode}
	class_set(t, s.lhs, &lhs) or_return
	class_set(t, s.rhs, &rhs) or_return
	if ci(t) {
		class_case_fold_simple(&rhs)
		class_case_fold_simple(&lhs)
	}
	switch s.op {
	case .Intersection: class_intersect(&lhs, rhs)
	case .Difference: class_difference(&lhs, rhs)
	case .Symmetric_Difference: class_symmetric_difference(&lhs, rhs)
	}
	class_union(into, lhs)
	return nil
}

@(private="file")
class_literal_byte :: proc(t: ^Translator, lit: Ast_Literal) -> (b: u8, err: Trans_Error) {
	c, byte_, is_byte := literal_to_scalar(t, lit) or_return
	if is_byte { return byte_, nil }
	if c <= 0x7F { return u8(c), nil }
	return 0, terr(t, lit.span, .Unicode_Not_Allowed)
}

@(private="file")
class_item :: proc(t: ^Translator, it: ^Class_Set_Item, into: ^Hir_Class) -> Trans_Error {
	switch it.kind {
	case .Empty:
	case .Literal:
		if into.unicode {
			class_push(into, {u32(it.lit.c), u32(it.lit.c)})
		} else {
			b := class_literal_byte(t, it.lit) or_return
			class_push(into, {u32(b), u32(b)})
		}
	case .Range:
		if into.unicode {
			class_push(into, {u32(it.lit.c), u32(it.lit_end.c)})
		} else {
			lo := class_literal_byte(t, it.lit) or_return
			hi := class_literal_byte(t, it.lit_end) or_return
			class_push(into, {u32(lo), u32(hi)})
		}
	case .Ascii:
		x := class_new(into.unicode, ascii_class_ranges(it.ascii.kind))
		fold_and_negate(t, it.ascii.span, it.ascii.negated, &x) or_return
		class_union(into, x)
	case .Unicode:
		x := unicode_class(t, it.unicode) or_return
		class_union(into, x)
	case .Perl:
		if into.unicode {
			class_union(into, perl_unicode_class(it.perl))
		} else {
			x := perl_byte_class(t, it.perl) or_return
			class_union(into, x)
		}
	case .Bracketed:
		x := Hir_Class{unicode = into.unicode}
		class_set(t, &it.bracketed.kind, &x) or_return
		fold_and_negate(t, it.bracketed.span, it.bracketed.negated, &x) or_return
		class_union(into, x)
	case .Union:
		for &sub in it.items { class_item(t, &sub, into) or_return }
	}
	return nil
}

// ---------------------------------------------------------------------------------------------
// Unicode classes (unicode.rs)

unicode_table_class :: proc(ranges: [][2]rune, index: []Unicode_Named, name: string) -> Hir_Class {
	for e in index {
		if e.name == name {
			c := Hir_Class{unicode = true}
			for r in ranges[e.start:e.start + e.count] { append(&c.ranges, Class_Range{u32(r[0]), u32(r[1])}) }
			class_canonicalize(&c)
			return c
		}
	}
	return {unicode = true}
}

@(private="file")
table_has :: proc(index: []Unicode_Named, name: string) -> bool {
	for e in index { if e.name == name { return true } }
	return false
}

// symbolic_name_normalize: a leading "is" dropped, spaces, '_' and '-' removed, ASCII
// lowercased, non-ASCII bytes dropped ("isc" kept for "c")
symbolic_name_normalize :: proc(x: string) -> string {
	b := transmute([]u8)x
	start := 0
	starts_with_is := len(b) >= 2 && (b[0] == 'i' || b[0] == 'I') && (b[1] == 's' || b[1] == 'S')
	if starts_with_is { start = 2 }
	out: [dynamic]u8
	for c in b[start:] {
		switch {
		case c == ' ' || c == '_' || c == '-':
		case 'A' <= c && c <= 'Z': append(&out, c + 32)
		case c <= 0x7F: append(&out, c)
		}
	}
	if starts_with_is && len(out) == 1 && out[0] == 'c' {
		clear(&out)
		append(&out, "isc")
	}
	return string(out[:])
}

@(private="file")
canonical_prop :: proc(norm: string) -> (string, bool) {
	lo, hi := 0, len(UT_PROPERTY_NAMES)
	for lo < hi {
		mid := (lo + hi) / 2
		if UT_PROPERTY_NAMES[mid][0] < norm { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(UT_PROPERTY_NAMES) && UT_PROPERTY_NAMES[lo][0] == norm { return UT_PROPERTY_NAMES[lo][1], true }
	return "", false
}

@(private="file")
property_values :: proc(canon: string) -> (vals: [][2]string, ok: bool) {
	for p in UT_PROPERTY_VALUES {
		if p.property == canon { return UT_PROPERTY_VALUE_PAIRS[p.start:p.start + p.count], true }
	}
	return
}

@(private="file")
canonical_value :: proc(vals: [][2]string, norm: string) -> (string, bool) {
	lo, hi := 0, len(vals)
	for lo < hi {
		mid := (lo + hi) / 2
		if vals[mid][0] < norm { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(vals) && vals[lo][0] == norm { return vals[lo][1], true }
	return "", false
}

@(private="file")
canonical_gencat :: proc(norm: string) -> (string, bool) {
	switch norm {
	case "any": return "Any", true
	case "assigned": return "Assigned", true
	case "ascii": return "ASCII", true
	}
	vals, _ := property_values("General_Category")
	return canonical_value(vals, norm)
}

@(private="file")
canonical_script :: proc(norm: string) -> (string, bool) {
	vals, _ := property_values("Script")
	return canonical_value(vals, norm)
}

@(private="file")
gencat_class :: proc(name: string) -> (c: Hir_Class, ok: bool) {
	switch name {
	case "Decimal_Number": return unicode_table_class(UT_PERL_DECIMAL_RANGES[:], UT_PERL_DECIMAL[:], "Decimal_Number"), true
	case "ASCII": return class_new(true, {{0, 0x7F}}), true
	case "Any": return class_new(true, {{0, 0x10FFFF}}), true
	case "Assigned":
		c = unicode_table_class(UT_GENERAL_CATEGORY_RANGES[:], UT_GENERAL_CATEGORY[:], "Unassigned")
		class_negate(&c)
		return c, true
	}
	if !table_has(UT_GENERAL_CATEGORY[:], name) { return }
	return unicode_table_class(UT_GENERAL_CATEGORY_RANGES[:], UT_GENERAL_CATEGORY[:], name), true
}

Unicode_Lookup_Error :: enum { None, Property_Not_Found, Property_Value_Not_Found }

AGES :: [?]string{"V1_1", "V2_0", "V2_1", "V3_0", "V3_1", "V3_2", "V4_0", "V4_1", "V5_0", "V5_1", "V5_2", "V6_0", "V6_1", "V6_2", "V6_3", "V7_0", "V8_0", "V9_0", "V10_0", "V11_0", "V12_0", "V12_1", "V13_0", "V14_0", "V15_0"}

// unicode::class over a ClassQuery
unicode_lookup :: proc(cls: Class_Unicode) -> (c: Hir_Class, e: Unicode_Lookup_Error) {
	binary :: proc(name: string) -> (c: Hir_Class, e: Unicode_Lookup_Error) {
		norm := symbolic_name_normalize(name)
		if norm != "cf" && norm != "sc" && norm != "lc" {
			if canon, ok := canonical_prop(norm); ok {
				switch canon {
				case "Decimal_Number": return unicode_table_class(UT_PERL_DECIMAL_RANGES[:], UT_PERL_DECIMAL[:], "Decimal_Number"), .None
				case "White_Space": return unicode_table_class(UT_PERL_SPACE_RANGES[:], UT_PERL_SPACE[:], "White_Space"), .None
				}
				if !table_has(UT_PROPERTY_BOOL[:], canon) { return c, .Property_Not_Found }
				return unicode_table_class(UT_PROPERTY_BOOL_RANGES[:], UT_PROPERTY_BOOL[:], canon), .None
			}
		}
		if canon, ok := canonical_gencat(norm); ok {
			if g, gok := gencat_class(canon); gok { return g, .None }
			return c, .Property_Value_Not_Found
		}
		if canon, ok := canonical_script(norm); ok {
			if !table_has(UT_SCRIPT[:], canon) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_SCRIPT_RANGES[:], UT_SCRIPT[:], canon), .None
		}
		return c, .Property_Not_Found
	}
	switch cls.kind {
	case .One_Letter:
		buf, n := utf8.encode_rune(cls.letter)
		return binary(string(buf[:n]))
	case .Named:
		return binary(cls.name)
	case .Named_Value:
		pname := symbolic_name_normalize(cls.name)
		pvalue := symbolic_name_normalize(cls.value)
		canon_name, ok := canonical_prop(pname)
		if !ok { return c, .Property_Not_Found }
		switch canon_name {
		case "General_Category":
			canon, gok := canonical_gencat(pvalue)
			if !gok { return c, .Property_Value_Not_Found }
			g, found := gencat_class(canon)
			if !found { return c, .Property_Value_Not_Found }
			return g, .None
		case "Script":
			canon, sok := canonical_script(pvalue)
			if !sok { return c, .Property_Value_Not_Found }
			if !table_has(UT_SCRIPT[:], canon) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_SCRIPT_RANGES[:], UT_SCRIPT[:], canon), .None
		}
		vals, vok := property_values(canon_name)
		if !vok { return c, .Property_Value_Not_Found }
		canon_val, cok := canonical_value(vals, pvalue)
		if !cok { return c, .Property_Value_Not_Found }
		switch canon_name {
		case "Age":
			c = Hir_Class{unicode = true}
			ages := AGES
			for a in ages {
				x := unicode_table_class(UT_AGE_RANGES[:], UT_AGE[:], a)
				class_union(&c, x)
				if a == canon_val { return c, .None }
			}
			return c, .Property_Value_Not_Found
		case "Script_Extensions":
			if !table_has(UT_SCRIPT_EXTENSION[:], canon_val) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_SCRIPT_EXTENSION_RANGES[:], UT_SCRIPT_EXTENSION[:], canon_val), .None
		case "Grapheme_Cluster_Break":
			if !table_has(UT_GRAPHEME_CLUSTER_BREAK[:], canon_val) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_GRAPHEME_CLUSTER_BREAK_RANGES[:], UT_GRAPHEME_CLUSTER_BREAK[:], canon_val), .None
		case "Sentence_Break":
			if !table_has(UT_SENTENCE_BREAK[:], canon_val) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_SENTENCE_BREAK_RANGES[:], UT_SENTENCE_BREAK[:], canon_val), .None
		case "Word_Break":
			if !table_has(UT_WORD_BREAK[:], canon_val) { return c, .Property_Value_Not_Found }
			return unicode_table_class(UT_WORD_BREAK_RANGES[:], UT_WORD_BREAK[:], canon_val), .None
		}
		return c, .Property_Not_Found
	}
	return c, .Property_Not_Found
}

@(private="file")
unicode_class :: proc(t: ^Translator, cls: Class_Unicode) -> (c: Hir_Class, err: Trans_Error) {
	if !uni(t) { return c, terr(t, cls.span, .Unicode_Not_Allowed) }
	e: Unicode_Lookup_Error
	c, e = unicode_lookup(cls)
	switch e {
	case .Property_Not_Found: return c, terr(t, cls.span, .Unicode_Property_Not_Found)
	case .Property_Value_Not_Found: return c, terr(t, cls.span, .Unicode_Property_Value_Not_Found)
	case .None:
	}
	fold_and_negate(t, cls.span, cls.negated, &c) or_return
	return c, nil
}

_ :: strings
