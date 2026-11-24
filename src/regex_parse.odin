// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// regex-syntax 0.8.4's parser (src/ast/parse.rs): a pattern to its AST, with the same
// spans and errors. Characters are decoded from the UTF-8 pattern at byte offsets, as Rust's
// chars() over a str.

Parse_Error :: Maybe(Ast_Error)

Group_State :: struct {
	is_alt:            bool,
	concat:            Concat_Acc,
	group:             ^Ast,             // a Group node being filled
	ignore_whitespace: bool,
	alt_span:          Span,
	alt_asts:          [dynamic]^Ast,
}

Concat_Acc :: struct {
	span: Span,
	asts: [dynamic]^Ast,
}

Class_State :: struct {
	is_op: bool,
	union_: Class_Set_Union,              // Open: the parent's union
	set:    ^Class_Bracketed,             // Open
	op:     Class_Set_Op_Kind,            // Op
	lhs:    Class_Set,                    // Op
}

Regex_Parser :: struct {
	pattern:                   string,
	pos:                       Position,
	capture_index:             u32,
	nest_limit:                u32,
	octal:                     bool,
	empty_min_range:           bool,
	ignore_whitespace:         bool,
	stack_group:               [dynamic]Group_State,
	stack_class:               [dynamic]Class_State,
	capture_names:             [dynamic]Capture_Name,    // sorted by name
}

@(private="file")
perr :: proc(p: ^Regex_Parser, span: Span, kind: Ast_Error_Kind) -> Ast_Error {
	return {kind = kind, pattern = p.pattern, span = span}
}

@(private="file") is_eof :: #force_inline proc(p: ^Regex_Parser) -> bool { return p.pos.offset == len(p.pattern) }

@(private="file")
char_at :: proc(p: ^Regex_Parser, i: int) -> rune {
	r, _ := utf8.decode_rune_in_string(p.pattern[i:])
	return r
}

@(private="file") ch :: #force_inline proc(p: ^Regex_Parser) -> rune { return char_at(p, p.pos.offset) }

@(private="file")
bump :: proc(p: ^Regex_Parser) -> bool {
	if is_eof(p) { return false }
	c := ch(p)
	if c == '\n' {
		p.pos.line += 1
		p.pos.column = 1
	} else {
		p.pos.column += 1
	}
	p.pos.offset += utf8.rune_size(c)
	return p.pos.offset < len(p.pattern)
}

@(private="file")
bump_if :: proc(p: ^Regex_Parser, prefix: string) -> bool {
	if !strings.has_prefix(p.pattern[p.pos.offset:], prefix) { return false }
	for _ in 0 ..< utf8.rune_count_in_string(prefix) { bump(p) }
	return true
}

@(private="file")
is_lookaround_prefix :: proc(p: ^Regex_Parser) -> bool {
	return bump_if(p, "?=") || bump_if(p, "?!") || bump_if(p, "?<=") || bump_if(p, "?<!")
}

@(private="file")
bump_and_bump_space :: proc(p: ^Regex_Parser) -> bool {
	if !bump(p) { return false }
	bump_space(p)
	return !is_eof(p)
}

// Rust's char::is_whitespace (the White_Space property)
rust_is_whitespace :: proc(c: rune) -> bool {
	switch c {
	case '\t' ..= '\r', ' ', 0x85, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
		return true
	}
	return false
}

@(private="file")
bump_space :: proc(p: ^Regex_Parser) {
	if !p.ignore_whitespace { return }
	for !is_eof(p) {
		if rust_is_whitespace(ch(p)) {
			bump(p)
		} else if ch(p) == '#' {
			bump(p)
			for !is_eof(p) {
				c := ch(p)
				bump(p)
				if c == '\n' { break }
			}
		} else {
			break
		}
	}
}

@(private="file")
peek :: proc(p: ^Regex_Parser) -> (c: rune, ok: bool) {
	if is_eof(p) { return }
	i := p.pos.offset + utf8.rune_size(ch(p))
	if i >= len(p.pattern) { return }
	return char_at(p, i), true
}

@(private="file")
peek_space :: proc(p: ^Regex_Parser) -> (c: rune, ok: bool) {
	if !p.ignore_whitespace { return peek(p) }
	if is_eof(p) { return }
	start := p.pos.offset + utf8.rune_size(ch(p))
	in_comment := false
	found := len(p.pattern)
	for r, i in p.pattern[start:] {
		if rust_is_whitespace(r) {
			continue
		} else if !in_comment && r == '#' {
			in_comment = true
		} else if in_comment && r == '\n' {
			in_comment = false
		} else {
			found = start + i
			break
		}
	}
	if found >= len(p.pattern) { return }
	return char_at(p, found), true
}

@(private="file") span_here :: #force_inline proc(p: ^Regex_Parser) -> Span { return span_splat(p.pos) }

@(private="file")
span_char :: proc(p: ^Regex_Parser) -> Span {
	c := ch(p)
	next := Position{p.pos.offset + utf8.rune_size(c), p.pos.line, p.pos.column + 1}
	if c == '\n' {
		next.line += 1
		next.column = 1
	}
	return {p.pos, next}
}

@(private="file")
next_capture_index :: proc(p: ^Regex_Parser, span: Span) -> (i: u32, err: Parse_Error) {
	if p.capture_index == max(u32) { return 0, perr(p, span, .Capture_Limit_Exceeded) }
	p.capture_index += 1
	return p.capture_index, nil
}

@(private="file")
add_capture_name :: proc(p: ^Regex_Parser, cap: Capture_Name) -> Parse_Error {
	lo, hi := 0, len(p.capture_names)
	for lo < hi {
		mid := (lo + hi) / 2
		if p.capture_names[mid].name < cap.name { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(p.capture_names) && p.capture_names[lo].name == cap.name {
		e := perr(p, cap.span, .Group_Name_Duplicate)
		e.aux_span = p.capture_names[lo].span
		return e
	}
	inject_at(&p.capture_names, lo, cap)
	return nil
}

regex_parse :: proc(pattern: string, nest_limit: u32 = 250, octal := false, ignore_whitespace := false) -> (ast: ^Ast, err: Parse_Error) {
	p := Regex_Parser{pattern = pattern, pos = {0, 1, 1}, nest_limit = nest_limit, octal = octal, ignore_whitespace = ignore_whitespace}
	concat := Concat_Acc{span = span_here(&p)}
	for {
		bump_space(&p)
		if is_eof(&p) { break }
		switch ch(&p) {
		case '(': concat = push_group(&p, concat) or_return
		case ')': concat = pop_group(&p, concat) or_return
		case '|': concat = push_alternate(&p, concat)
		case '[':
			class := parse_set_class(&p) or_return
			append(&concat.asts, new_ast({kind = .Class_Bracketed, span = class.span, bracketed = class}))
		case '?': concat = parse_uncounted_repetition(&p, concat, .Zero_Or_One) or_return
		case '*': concat = parse_uncounted_repetition(&p, concat, .Zero_Or_More) or_return
		case '+': concat = parse_uncounted_repetition(&p, concat, .One_Or_More) or_return
		case '{': concat = parse_counted_repetition(&p, concat) or_return
		case:
			prim := parse_primitive(&p) or_return
			append(&concat.asts, prim)
		}
	}
	ast = pop_group_end(&p, concat) or_return
	depth: u32 = 0
	nest_check(&p, ast, &depth) or_return
	return ast, nil
}

@(private="file")
push_alternate :: proc(p: ^Regex_Parser, concat: Concat_Acc) -> Concat_Acc {
	concat := concat
	concat.span.end = p.pos
	push_or_add_alternation(p, concat)
	bump(p)
	return {span = span_here(p)}
}

@(private="file")
push_or_add_alternation :: proc(p: ^Regex_Parser, concat: Concat_Acc) {
	if n := len(p.stack_group); n > 0 && p.stack_group[n - 1].is_alt {
		append(&p.stack_group[n - 1].alt_asts, asts_into_ast(.Concat, concat.span, concat.asts))
		return
	}
	gs := Group_State{is_alt = true, alt_span = {concat.span.start, p.pos}}
	append(&gs.alt_asts, asts_into_ast(.Concat, concat.span, concat.asts))
	append(&p.stack_group, gs)
}

@(private="file")
push_group :: proc(p: ^Regex_Parser, concat: Concat_Acc) -> (out: Concat_Acc, err: Parse_Error) {
	concat := concat
	set_flags, group := parse_group(p) or_return
	if set_flags != nil {
		if v, set := flags_state(&set_flags.flags, .Ignore_Whitespace); set { p.ignore_whitespace = v }
		append(&concat.asts, set_flags)
		return concat, nil
	}
	old := p.ignore_whitespace
	new_iw := old
	if group.group_kind == .Non_Capturing {
		if v, set := flags_state(&group.flags, .Ignore_Whitespace); set { new_iw = v }
	}
	append(&p.stack_group, Group_State{concat = concat, group = group, ignore_whitespace = old})
	p.ignore_whitespace = new_iw
	return {span = span_here(p)}, nil
}

@(private="file")
pop_group :: proc(p: ^Regex_Parser, group_concat: Concat_Acc) -> (out: Concat_Acc, err: Parse_Error) {
	group_concat := group_concat
	if len(p.stack_group) == 0 { return out, perr(p, span_char(p), .Group_Unopened) }
	top := pop(&p.stack_group)
	gs: Group_State
	alt: Maybe(Group_State)
	if !top.is_alt {
		gs = top
	} else {
		if len(p.stack_group) == 0 || p.stack_group[len(p.stack_group) - 1].is_alt {
			return out, perr(p, span_char(p), .Group_Unopened)
		}
		gs = pop(&p.stack_group)
		alt = top
	}
	p.ignore_whitespace = gs.ignore_whitespace
	group_concat.span.end = p.pos
	bump(p)
	group := gs.group
	group.span.end = p.pos
	if a, ok := alt.?; ok {
		a.alt_span.end = group_concat.span.end
		append(&a.alt_asts, asts_into_ast(.Concat, group_concat.span, group_concat.asts))
		group.sub = asts_into_ast(.Alternation, a.alt_span, a.alt_asts)
	} else {
		group.sub = asts_into_ast(.Concat, group_concat.span, group_concat.asts)
	}
	prior := gs.concat
	append(&prior.asts, group)
	return prior, nil
}

@(private="file")
pop_group_end :: proc(p: ^Regex_Parser, concat: Concat_Acc) -> (ast: ^Ast, err: Parse_Error) {
	concat := concat
	concat.span.end = p.pos
	if len(p.stack_group) == 0 {
		return asts_into_ast(.Concat, concat.span, concat.asts), nil
	}
	top := pop(&p.stack_group)
	if !top.is_alt { return nil, perr(p, top.group.span, .Group_Unclosed) }
	top.alt_span.end = p.pos
	append(&top.alt_asts, asts_into_ast(.Concat, concat.span, concat.asts))
	ast = new_ast({kind = .Alternation, span = top.alt_span, asts = top.alt_asts})
	if len(p.stack_group) > 0 {
		g := pop(&p.stack_group)
		return nil, perr(p, g.group.span, .Group_Unclosed)
	}
	return ast, nil
}

@(private="file")
parse_uncounted_repetition :: proc(p: ^Regex_Parser, concat: Concat_Acc, kind: Repetition_Kind) -> (out: Concat_Acc, err: Parse_Error) {
	concat := concat
	op_start := p.pos
	if len(concat.asts) == 0 { return out, perr(p, span_here(p), .Repetition_Missing) }
	ast := pop(&concat.asts)
	if ast.kind == .Empty || ast.kind == .Flags { return out, perr(p, span_here(p), .Repetition_Missing) }
	greedy := true
	if bump(p) && ch(p) == '?' {
		greedy = false
		bump(p)
	}
	append(&concat.asts, new_ast({
		kind = .Repetition,
		span = {ast.span.start, p.pos},
		op = {span = {op_start, p.pos}, kind = kind},
		greedy = greedy,
		sub = ast,
	}))
	return concat, nil
}

@(private="file")
specialize :: proc(e: Parse_Error, from, to: Ast_Error_Kind) -> Parse_Error {
	if x, bad := e.?; bad && x.kind == from {
		x.kind = to
		return x
	}
	return e
}

@(private="file")
parse_counted_repetition :: proc(p: ^Regex_Parser, concat: Concat_Acc) -> (out: Concat_Acc, err: Parse_Error) {
	concat := concat
	start := p.pos
	if len(concat.asts) == 0 { return out, perr(p, span_here(p), .Repetition_Missing) }
	ast := pop(&concat.asts)
	if ast.kind == .Empty || ast.kind == .Flags { return out, perr(p, span_here(p), .Repetition_Missing) }
	if !bump_and_bump_space(p) { return out, perr(p, {start, p.pos}, .Repetition_Count_Unclosed) }
	count_start, cs_err := parse_decimal(p)
	cs_err = specialize(cs_err, .Decimal_Empty, .Repetition_Count_Decimal_Empty)
	if is_eof(p) { return out, perr(p, {start, p.pos}, .Repetition_Count_Unclosed) }
	op := Repetition_Op{kind = .Range}
	if ch(p) == ',' {
		if !bump_and_bump_space(p) { return out, perr(p, {start, p.pos}, .Repetition_Count_Unclosed) }
		if ch(p) != '}' {
			if e, bad := cs_err.?; bad {
				if e.kind == .Repetition_Count_Decimal_Empty && p.empty_min_range {
					count_start = 0
				} else {
					return out, e
				}
			}
			count_end, ce_err := parse_decimal(p)
			ce_err = specialize(ce_err, .Decimal_Empty, .Repetition_Count_Decimal_Empty)
			if e, bad := ce_err.?; bad { return out, e }
			op.range_kind, op.min, op.max = .Bounded, count_start, count_end
		} else {
			if e, bad := cs_err.?; bad { return out, e }
			op.range_kind, op.min = .At_Least, count_start
		}
	} else {
		if e, bad := cs_err.?; bad { return out, e }
		op.range_kind, op.min, op.max = .Exactly, count_start, count_start
	}
	if is_eof(p) || ch(p) != '}' { return out, perr(p, {start, p.pos}, .Repetition_Count_Unclosed) }
	greedy := true
	if bump_and_bump_space(p) && ch(p) == '?' {
		greedy = false
		bump(p)
	}
	op.span = {start, p.pos}
	if op.range_kind == .Bounded && op.min > op.max {
		return out, perr(p, op.span, .Repetition_Count_Invalid)
	}
	append(&concat.asts, new_ast({kind = .Repetition, span = {ast.span.start, p.pos}, op = op, greedy = greedy, sub = ast}))
	return concat, nil
}

// either a flags directive (set_flags) or a new group (group)
@(private="file")
parse_group :: proc(p: ^Regex_Parser) -> (set_flags: ^Ast, group: ^Ast, err: Parse_Error) {
	open_span := span_char(p)
	bump(p)
	bump_space(p)
	if is_lookaround_prefix(p) {
		return nil, nil, perr(p, {open_span.start, p.pos}, .Unsupported_Look_Around)
	}
	inner_span := span_here(p)
	starts_with_p := true
	named := bump_if(p, "?P<")
	if !named {
		starts_with_p = false
		named = bump_if(p, "?<")
	}
	if named {
		idx := next_capture_index(p, open_span) or_return
		name := parse_capture_name(p, idx) or_return
		return nil, new_ast({kind = .Group, span = open_span, group_kind = .Capture_Name, capture_name = name, capture_index = idx, starts_with_p = starts_with_p, sub = new_ast({kind = .Empty, span = span_here(p)})}), nil
	}
	if bump_if(p, "?") {
		if is_eof(p) { return nil, nil, perr(p, open_span, .Group_Unclosed) }
		flags := parse_flags(p) or_return
		char_end := ch(p)
		bump(p)
		if char_end == ')' {
			if len(flags.items) == 0 { return nil, nil, perr(p, inner_span, .Repetition_Missing) }
			return new_ast({kind = .Flags, span = {open_span.start, p.pos}, flags = flags}), nil, nil
		}
		return nil, new_ast({kind = .Group, span = open_span, group_kind = .Non_Capturing, flags = flags, sub = new_ast({kind = .Empty, span = span_here(p)})}), nil
	}
	idx := next_capture_index(p, open_span) or_return
	return nil, new_ast({kind = .Group, span = open_span, group_kind = .Capture_Index, capture_index = idx, sub = new_ast({kind = .Empty, span = span_here(p)})}), nil
}

// Rust's char::is_alphabetic / is_alphanumeric, close enough for capture names
@(private="file")
is_capture_char :: proc(c: rune, first: bool) -> bool {
	if first { return c == '_' || unicode.is_letter(c) }
	return c == '_' || c == '.' || c == '[' || c == ']' || unicode.is_letter(c) || unicode.is_digit(c) || unicode.is_number(c)
}

@(private="file")
parse_capture_name :: proc(p: ^Regex_Parser, idx: u32) -> (cap: Capture_Name, err: Parse_Error) {
	if is_eof(p) { return cap, perr(p, span_here(p), .Group_Name_Unexpected_Eof) }
	start := p.pos
	for {
		if ch(p) == '>' { break }
		if !is_capture_char(ch(p), p.pos.offset == start.offset) {
			return cap, perr(p, span_char(p), .Group_Name_Invalid)
		}
		if !bump(p) { break }
	}
	end := p.pos
	if is_eof(p) { return cap, perr(p, span_here(p), .Group_Name_Unexpected_Eof) }
	bump(p)
	name := p.pattern[start.offset:end.offset]
	if len(name) == 0 { return cap, perr(p, {start, start}, .Group_Name_Empty) }
	cap = {span = {start, end}, name = name, index = idx}
	add_capture_name(p, cap) or_return
	return cap, nil
}

@(private="file")
parse_flags :: proc(p: ^Regex_Parser) -> (flags: Ast_Flags, err: Parse_Error) {
	flags.span = span_here(p)
	last_was_negation: Maybe(Span)
	for ch(p) != ':' && ch(p) != ')' {
		if ch(p) == '-' {
			last_was_negation = span_char(p)
			item := Flags_Item{span = span_char(p), negation = true}
			if i, dup := flags_add_item(&flags, item); dup {
				e := perr(p, span_char(p), .Flag_Repeated_Negation)
				e.aux_span = flags.items[i].span
				return flags, e
			}
		} else {
			last_was_negation = nil
			f := parse_flag(p) or_return
			item := Flags_Item{span = span_char(p), flag = f}
			if i, dup := flags_add_item(&flags, item); dup {
				e := perr(p, span_char(p), .Flag_Duplicate)
				e.aux_span = flags.items[i].span
				return flags, e
			}
		}
		if !bump(p) { return flags, perr(p, span_here(p), .Flag_Unexpected_Eof) }
	}
	if s, ok := last_was_negation.?; ok { return flags, perr(p, s, .Flag_Dangling_Negation) }
	flags.span.end = p.pos
	return flags, nil
}

@(private="file")
parse_flag :: proc(p: ^Regex_Parser) -> (f: Regex_Flag, err: Parse_Error) {
	switch ch(p) {
	case 'i': return .Case_Insensitive, nil
	case 'm': return .Multi_Line, nil
	case 's': return .Dot_Matches_New_Line, nil
	case 'U': return .Swap_Greed, nil
	case 'u': return .Unicode, nil
	case 'R': return .CRLF, nil
	case 'x': return .Ignore_Whitespace, nil
	}
	return f, perr(p, span_char(p), .Flag_Unrecognized)
}

// a "primitive": a literal, an assertion, a dot, or a Perl or Unicode class
Primitive :: struct {
	kind:      enum { Literal, Assertion, Dot, Perl, Unicode },
	span:      Span,
	lit:       Ast_Literal,
	assertion: Assertion_Kind,
	perl:      Class_Perl,
	unicode:   Class_Unicode,
}

@(private="file")
prim_into_ast :: proc(pr: Primitive) -> ^Ast {
	switch pr.kind {
	case .Literal: return new_ast({kind = .Literal, span = pr.span, lit = pr.lit})
	case .Assertion: return new_ast({kind = .Assertion, span = pr.span, assertion = pr.assertion})
	case .Dot: return new_ast({kind = .Dot, span = pr.span})
	case .Perl: return new_ast({kind = .Class_Perl, span = pr.span, cls_perl = pr.perl})
	case .Unicode: return new_ast({kind = .Class_Unicode, span = pr.span, cls_unicode = pr.unicode})
	}
	return nil
}

@(private="file")
parse_primitive :: proc(p: ^Regex_Parser) -> (ast: ^Ast, err: Parse_Error) {
	switch ch(p) {
	case '\\':
		pr := parse_escape(p) or_return
		return prim_into_ast(pr), nil
	case '.':
		a := new_ast({kind = .Dot, span = span_char(p)})
		bump(p)
		return a, nil
	case '^':
		a := new_ast({kind = .Assertion, span = span_char(p), assertion = .Start_Line})
		bump(p)
		return a, nil
	case '$':
		a := new_ast({kind = .Assertion, span = span_char(p), assertion = .End_Line})
		bump(p)
		return a, nil
	}
	a := new_ast({kind = .Literal, span = span_char(p), lit = {span = span_char(p), kind = .Verbatim, c = ch(p)}})
	bump(p)
	return a, nil
}

is_regex_meta_character :: proc(c: rune) -> bool {
	switch c {
	case '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '#', '&', '-', '~':
		return true
	}
	return false
}

is_escapeable_character :: proc(c: rune) -> bool {
	if is_regex_meta_character(c) { return true }
	if c >= 0x80 { return false }
	switch c {
	case '0' ..= '9', 'A' ..= 'Z', 'a' ..= 'z', '<', '>': return false
	}
	return true
}

@(private="file")
parse_escape :: proc(p: ^Regex_Parser) -> (pr: Primitive, err: Parse_Error) {
	start := p.pos
	if !bump(p) { return pr, perr(p, {start, p.pos}, .Escape_Unexpected_Eof) }
	c := ch(p)
	switch c {
	case '0' ..= '7':
		if !p.octal { return pr, perr(p, {start, span_char(p).end}, .Unsupported_Backreference) }
		lit := parse_octal(p)
		lit.span.start = start
		return {kind = .Literal, span = lit.span, lit = lit}, nil
	case '8', '9':
		if !p.octal { return pr, perr(p, {start, span_char(p).end}, .Unsupported_Backreference) }
	case 'x', 'u', 'U':
		lit := parse_hex(p) or_return
		lit.span.start = start
		return {kind = .Literal, span = lit.span, lit = lit}, nil
	case 'p', 'P':
		cls := parse_unicode_class(p) or_return
		cls.span.start = start
		return {kind = .Unicode, span = cls.span, unicode = cls}, nil
	case 'd', 's', 'w', 'D', 'S', 'W':
		cls := parse_perl_class(p)
		cls.span.start = start
		return {kind = .Perl, span = cls.span, perl = cls}, nil
	}
	bump(p)
	span := Span{start, p.pos}
	if is_regex_meta_character(c) {
		return {kind = .Literal, span = span, lit = {span = span, kind = .Meta, c = c}}, nil
	}
	if is_escapeable_character(c) {
		return {kind = .Literal, span = span, lit = {span = span, kind = .Superfluous, c = c}}, nil
	}
	special :: proc(span: Span, c: rune) -> Primitive {
		return {kind = .Literal, span = span, lit = {span = span, kind = .Special, c = c}}
	}
	switch c {
	case 'a': return special(span, 0x07), nil
	case 'f': return special(span, 0x0C), nil
	case 't': return special(span, '\t'), nil
	case 'n': return special(span, '\n'), nil
	case 'r': return special(span, '\r'), nil
	case 'v': return special(span, 0x0B), nil
	case 'A': return {kind = .Assertion, span = span, assertion = .Start_Text}, nil
	case 'z': return {kind = .Assertion, span = span, assertion = .End_Text}, nil
	case 'b':
		wb := Primitive{kind = .Assertion, span = span, assertion = .Word_Boundary}
		if !is_eof(p) && ch(p) == '{' {
			kind, found := maybe_parse_special_word_boundary(p, start) or_return
			if found {
				wb.assertion = kind
				wb.span.end = p.pos
			}
		}
		return wb, nil
	case 'B': return {kind = .Assertion, span = span, assertion = .Not_Word_Boundary}, nil
	case '<': return {kind = .Assertion, span = span, assertion = .Word_Boundary_Start_Angle}, nil
	case '>': return {kind = .Assertion, span = span, assertion = .Word_Boundary_End_Angle}, nil
	}
	return pr, perr(p, span, .Escape_Unrecognized)
}

@(private="file")
maybe_parse_special_word_boundary :: proc(p: ^Regex_Parser, wb_start: Position) -> (kind: Assertion_Kind, found: bool, err: Parse_Error) {
	is_valid :: proc(c: rune) -> bool { return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || c == '-' }
	start := p.pos
	if !bump_and_bump_space(p) {
		return kind, false, perr(p, {wb_start, p.pos}, .Special_Word_Or_Repetition_Unexpected_Eof)
	}
	start_contents := p.pos
	if !is_valid(ch(p)) {
		p.pos = start
		return kind, false, nil
	}
	scratch: strings.Builder
	scratch.buf.allocator = context.temp_allocator
	for !is_eof(p) && is_valid(ch(p)) {
		strings.write_rune(&scratch, ch(p))
		bump_and_bump_space(p)
	}
	if is_eof(p) || ch(p) != '}' {
		return kind, false, perr(p, {start, p.pos}, .Special_Word_Boundary_Unclosed)
	}
	end := p.pos
	bump(p)
	switch strings.to_string(scratch) {
	case "start": return .Word_Boundary_Start, true, nil
	case "end": return .Word_Boundary_End, true, nil
	case "start-half": return .Word_Boundary_Start_Half, true, nil
	case "end-half": return .Word_Boundary_End_Half, true, nil
	}
	return kind, false, perr(p, {start_contents, end}, .Special_Word_Boundary_Unrecognized)
}

@(private="file")
parse_octal :: proc(p: ^Regex_Parser) -> Ast_Literal {
	start := p.pos
	for bump(p) && '0' <= ch(p) && ch(p) <= '7' && p.pos.offset - start.offset <= 2 {}
	end := p.pos
	v, _ := strconv.parse_u64_of_base(p.pattern[start.offset:end.offset], 8)
	return {span = {start, end}, kind = .Octal, c = rune(v)}
}

@(private="file")
is_hex :: proc(c: rune) -> bool {
	return ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')
}

// char::from_u32
@(private="file")
valid_scalar :: proc(v: u64) -> bool {
	return v <= 0x10FFFF && !(v >= 0xD800 && v <= 0xDFFF)
}

@(private="file")
parse_hex :: proc(p: ^Regex_Parser) -> (lit: Ast_Literal, err: Parse_Error) {
	hk: Hex_Literal_Kind
	switch ch(p) {
	case 'x': hk = .X
	case 'u': hk = .Unicode_Short
	case: hk = .Unicode_Long
	}
	if !bump_and_bump_space(p) { return lit, perr(p, span_here(p), .Escape_Unexpected_Eof) }
	if ch(p) == '{' { return parse_hex_brace(p, hk) }
	return parse_hex_digits(p, hk)
}

@(private="file")
parse_hex_digits :: proc(p: ^Regex_Parser, hk: Hex_Literal_Kind) -> (lit: Ast_Literal, err: Parse_Error) {
	digits := 2 if hk == .X else (4 if hk == .Unicode_Short else 8)
	scratch: strings.Builder
	scratch.buf.allocator = context.temp_allocator
	start := p.pos
	for i in 0 ..< digits {
		if i > 0 && !bump_and_bump_space(p) { return lit, perr(p, span_here(p), .Escape_Unexpected_Eof) }
		if !is_hex(ch(p)) { return lit, perr(p, span_char(p), .Escape_Hex_Invalid_Digit) }
		strings.write_rune(&scratch, ch(p))
	}
	bump_and_bump_space(p)
	end := p.pos
	v, ok := strconv.parse_u64_of_base(strings.to_string(scratch), 16)
	if !ok || !valid_scalar(v) { return lit, perr(p, {start, end}, .Escape_Hex_Invalid) }
	return {span = {start, end}, kind = .Hex_Fixed, hex = hk, c = rune(v)}, nil
}

@(private="file")
parse_hex_brace :: proc(p: ^Regex_Parser, hk: Hex_Literal_Kind) -> (lit: Ast_Literal, err: Parse_Error) {
	scratch: strings.Builder
	scratch.buf.allocator = context.temp_allocator
	brace_pos := p.pos
	start := span_char(p).end
	for bump_and_bump_space(p) && ch(p) != '}' {
		if !is_hex(ch(p)) { return lit, perr(p, span_char(p), .Escape_Hex_Invalid_Digit) }
		strings.write_rune(&scratch, ch(p))
	}
	if is_eof(p) { return lit, perr(p, {brace_pos, p.pos}, .Escape_Unexpected_Eof) }
	end := p.pos
	hex := strings.to_string(scratch)
	bump_and_bump_space(p)
	if len(hex) == 0 { return lit, perr(p, {brace_pos, p.pos}, .Escape_Hex_Empty) }
	// u32::from_str_radix: leading zeros allowed, overflow past u32 is an error
	v: u64
	for d in transmute([]u8)hex {
		x := u64(d - '0') if d <= '9' else (u64(d | 0x20) - 'a' + 10)
		v = v * 16 + x
		if v > u64(max(u32)) { return lit, perr(p, {start, end}, .Escape_Hex_Invalid) }
	}
	if !valid_scalar(v) { return lit, perr(p, {start, end}, .Escape_Hex_Invalid) }
	return {span = {start, p.pos}, kind = .Hex_Brace, hex = hk, c = rune(v)}, nil
}

@(private="file")
parse_decimal :: proc(p: ^Regex_Parser) -> (n: u32, err: Parse_Error) {
	scratch: strings.Builder
	scratch.buf.allocator = context.temp_allocator
	for !is_eof(p) && rust_is_whitespace(ch(p)) { bump(p) }
	start := p.pos
	for !is_eof(p) && '0' <= ch(p) && ch(p) <= '9' {
		strings.write_rune(&scratch, ch(p))
		bump_and_bump_space(p)
	}
	span := Span{start, p.pos}
	for !is_eof(p) && rust_is_whitespace(ch(p)) { bump_and_bump_space(p) }
	digits := strings.to_string(scratch)
	if len(digits) == 0 { return 0, perr(p, span, .Decimal_Empty) }
	v, ok := strconv.parse_u64_of_base(digits, 10)
	if !ok || v > u64(max(u32)) { return 0, perr(p, span, .Decimal_Invalid) }
	return u32(v), nil
}

@(private="file")
unclosed_class_error :: proc(p: ^Regex_Parser) -> Ast_Error {
	#reverse for st in p.stack_class {
		if !st.is_op { return perr(p, st.set.span, .Class_Unclosed) }
	}
	panic("no open character class found")
}

@(private="file")
parse_set_class :: proc(p: ^Regex_Parser) -> (class: ^Class_Bracketed, err: Parse_Error) {
	u := Class_Set_Union{span = span_here(p)}
	for {
		bump_space(p)
		if is_eof(p) { return nil, unclosed_class_error(p) }
		c := ch(p)
		nx, has_nx := peek(p)
		switch {
		case c == '[':
			if len(p.stack_class) > 0 {
				if cls, ok := maybe_parse_ascii_class(p); ok {
					union_push(&u, {kind = .Ascii, span = cls.span, ascii = cls})
					continue
				}
			}
			u = push_class_open(p, u) or_return
		case c == ']':
			nested, done := pop_class(p, u)
			if done != nil { return done, nil }
			u = nested
		case c == '&' && has_nx && nx == '&':
			bump_if(p, "&&")
			u = push_class_op(p, .Intersection, u)
		case c == '-' && has_nx && nx == '-':
			bump_if(p, "--")
			u = push_class_op(p, .Difference, u)
		case c == '~' && has_nx && nx == '~':
			bump_if(p, "~~")
			u = push_class_op(p, .Symmetric_Difference, u)
		case:
			item := parse_set_class_range(p) or_return
			union_push(&u, item)
		}
	}
}

@(private="file")
prim_into_class_set_item :: proc(p: ^Regex_Parser, pr: Primitive) -> (item: Class_Set_Item, err: Parse_Error) {
	#partial switch pr.kind {
	case .Literal: return {kind = .Literal, span = pr.span, lit = pr.lit}, nil
	case .Perl: return {kind = .Perl, span = pr.span, perl = pr.perl}, nil
	case .Unicode: return {kind = .Unicode, span = pr.span, unicode = pr.unicode}, nil
	}
	return item, perr(p, pr.span, .Class_Escape_Invalid)
}

@(private="file")
parse_set_class_range :: proc(p: ^Regex_Parser) -> (item: Class_Set_Item, err: Parse_Error) {
	prim1 := parse_set_class_item(p) or_return
	bump_space(p)
	if is_eof(p) { return item, unclosed_class_error(p) }
	ps, has_ps := peek_space(p)
	if ch(p) != '-' || (has_ps && (ps == ']' || ps == '-')) {
		return prim_into_class_set_item(p, prim1)
	}
	if !bump_and_bump_space(p) { return item, unclosed_class_error(p) }
	prim2 := parse_set_class_item(p) or_return
	span := Span{prim1.span.start, prim2.span.end}
	if prim1.kind != .Literal { return item, perr(p, prim1.span, .Class_Range_Literal) }
	if prim2.kind != .Literal { return item, perr(p, prim2.span, .Class_Range_Literal) }
	if prim1.lit.c > prim2.lit.c { return item, perr(p, span, .Class_Range_Invalid) }
	return {kind = .Range, span = span, lit = prim1.lit, lit_end = prim2.lit}, nil
}

@(private="file")
parse_set_class_item :: proc(p: ^Regex_Parser) -> (pr: Primitive, err: Parse_Error) {
	if ch(p) == '\\' { return parse_escape(p) }
	span := span_char(p)
	pr = {kind = .Literal, span = span, lit = {span = span, kind = .Verbatim, c = ch(p)}}
	bump(p)
	return pr, nil
}

@(private="file")
parse_set_class_open :: proc(p: ^Regex_Parser) -> (set: ^Class_Bracketed, u: Class_Set_Union, err: Parse_Error) {
	start := p.pos
	if !bump_and_bump_space(p) { return nil, u, perr(p, {start, p.pos}, .Class_Unclosed) }
	negated := false
	if ch(p) == '^' {
		if !bump_and_bump_space(p) { return nil, u, perr(p, {start, p.pos}, .Class_Unclosed) }
		negated = true
	}
	u.span = span_here(p)
	for ch(p) == '-' {
		union_push(&u, {kind = .Literal, span = span_char(p), lit = {span = span_char(p), kind = .Verbatim, c = '-'}})
		if !bump_and_bump_space(p) { return nil, u, perr(p, {start, start}, .Class_Unclosed) }
	}
	if len(u.items) == 0 && ch(p) == ']' {
		union_push(&u, {kind = .Literal, span = span_char(p), lit = {span = span_char(p), kind = .Verbatim, c = ']'}})
		if !bump_and_bump_space(p) { return nil, u, perr(p, {start, p.pos}, .Class_Unclosed) }
	}
	set = new(Class_Bracketed)
	set^ = {span = {start, p.pos}, negated = negated, kind = {item = {kind = .Union, span = {u.span.start, u.span.start}}}}
	return set, u, nil
}

@(private="file")
push_class_open :: proc(p: ^Regex_Parser, parent: Class_Set_Union) -> (nested: Class_Set_Union, err: Parse_Error) {
	set, u := parse_set_class_open(p) or_return
	append(&p.stack_class, Class_State{union_ = parent, set = set})
	return u, nil
}

// the closing ']': the finished class when it was the outermost
@(private="file")
pop_class :: proc(p: ^Regex_Parser, nested: Class_Set_Union) -> (u: Class_Set_Union, done: ^Class_Bracketed) {
	item := Class_Set{item = union_into_item(nested)}
	prevset := pop_class_op(p, item)
	st := pop(&p.stack_class)
	bump(p)
	st.set.span.end = p.pos
	st.set.kind = prevset
	if len(p.stack_class) == 0 { return {}, st.set }
	u = st.union_
	union_push(&u, {kind = .Bracketed, span = st.set.span, bracketed = st.set})
	return u, nil
}

@(private="file")
push_class_op :: proc(p: ^Regex_Parser, kind: Class_Set_Op_Kind, next: Class_Set_Union) -> Class_Set_Union {
	item := Class_Set{item = union_into_item(next)}
	lhs := pop_class_op(p, item)
	append(&p.stack_class, Class_State{is_op = true, op = kind, lhs = lhs})
	return {span = span_here(p)}
}

@(private="file")
pop_class_op :: proc(p: ^Regex_Parser, rhs: Class_Set) -> Class_Set {
	n := len(p.stack_class)
	if n == 0 || !p.stack_class[n - 1].is_op { return rhs }
	st := pop(&p.stack_class)
	lhs := new(Class_Set)
	lhs^ = st.lhs
	r := new(Class_Set)
	r^ = rhs
	return {is_op = true, op_span = {class_set_span(lhs).start, class_set_span(r).end}, op = st.op, lhs = lhs, rhs = r}
}

@(private="file")
maybe_parse_ascii_class :: proc(p: ^Regex_Parser) -> (cls: Class_Ascii, ok: bool) {
	start := p.pos
	negated := false
	if !bump(p) || ch(p) != ':' { p.pos = start; return }
	if !bump(p) { p.pos = start; return }
	if ch(p) == '^' {
		negated = true
		if !bump(p) { p.pos = start; return }
	}
	name_start := p.pos.offset
	for ch(p) != ':' && bump(p) {}
	if is_eof(p) { p.pos = start; return }
	name := p.pattern[name_start:p.pos.offset]
	if !bump_if(p, ":]") { p.pos = start; return }
	kind, found := class_ascii_from_name(name)
	if !found { p.pos = start; return }
	return {span = {start, p.pos}, kind = kind, negated = negated}, true
}

@(private="file")
parse_unicode_class :: proc(p: ^Regex_Parser) -> (cls: Class_Unicode, err: Parse_Error) {
	negated := ch(p) == 'P'
	if !bump_and_bump_space(p) { return cls, perr(p, span_here(p), .Escape_Unexpected_Eof) }
	start: Position
	if ch(p) == '{' {
		start = span_char(p).end
		scratch: strings.Builder
		for bump_and_bump_space(p) && ch(p) != '}' { strings.write_rune(&scratch, ch(p)) }
		if is_eof(p) { return cls, perr(p, span_here(p), .Escape_Unexpected_Eof) }
		bump(p)
		name := strings.to_string(scratch)
		if i := strings.index(name, "!="); i >= 0 {
			cls = {kind = .Named_Value, op = .Not_Equal, name = name[:i], value = name[i + 2:]}
		} else if i := strings.index_byte(name, ':'); i >= 0 {
			cls = {kind = .Named_Value, op = .Colon, name = name[:i], value = name[i + 1:]}
		} else if i := strings.index_byte(name, '='); i >= 0 {
			cls = {kind = .Named_Value, op = .Equal, name = name[:i], value = name[i + 1:]}
		} else {
			cls = {kind = .Named, name = name}
		}
	} else {
		start = p.pos
		c := ch(p)
		if c == '\\' { return cls, perr(p, span_char(p), .Unicode_Class_Invalid) }
		bump_and_bump_space(p)
		cls = {kind = .One_Letter, letter = c}
	}
	cls.span = {start, p.pos}
	cls.negated = negated
	return cls, nil
}

@(private="file")
parse_perl_class :: proc(p: ^Regex_Parser) -> Class_Perl {
	c := ch(p)
	span := span_char(p)
	bump(p)
	switch c {
	case 'd': return {span, .Digit, false}
	case 'D': return {span, .Digit, true}
	case 's': return {span, .Space, false}
	case 'S': return {span, .Space, true}
	case 'w': return {span, .Word, false}
	}
	return {span, .Word, true}
}

// NestLimiter: the depth of groups, repetitions, classes and their operations
@(private="file")
nest_inc :: proc(p: ^Regex_Parser, span: Span, depth: ^u32) -> Parse_Error {
	if depth^ + 1 > p.nest_limit {
		e := perr(p, span, .Nest_Limit_Exceeded)
		e.limit = p.nest_limit
		return e
	}
	depth^ += 1
	return nil
}

@(private="file")
nest_check :: proc(p: ^Regex_Parser, a: ^Ast, depth: ^u32) -> Parse_Error {
	#partial switch a.kind {
	case .Empty, .Flags, .Literal, .Dot, .Assertion, .Class_Unicode, .Class_Perl:
		return nil
	}
	nest_inc(p, a.span, depth) or_return
	#partial switch a.kind {
	case .Class_Bracketed: nest_check_set(p, &a.bracketed.kind, depth) or_return
	case .Repetition, .Group: nest_check(p, a.sub, depth) or_return
	case .Alternation, .Concat:
		for s in a.asts { nest_check(p, s, depth) or_return }
	}
	depth^ -= 1
	return nil
}

@(private="file")
nest_check_set :: proc(p: ^Regex_Parser, s: ^Class_Set, depth: ^u32) -> Parse_Error {
	if s.is_op {
		nest_inc(p, s.op_span, depth) or_return
		nest_check_set(p, s.lhs, depth) or_return
		nest_check_set(p, s.rhs, depth) or_return
		depth^ -= 1
		return nil
	}
	return nest_check_item(p, &s.item, depth)
}

@(private="file")
nest_check_item :: proc(p: ^Regex_Parser, it: ^Class_Set_Item, depth: ^u32) -> Parse_Error {
	#partial switch it.kind {
	case .Bracketed:
		nest_inc(p, it.span, depth) or_return
		nest_check_set(p, &it.bracketed.kind, depth) or_return
		depth^ -= 1
	case .Union:
		nest_inc(p, it.span, depth) or_return
		for &x in it.items { nest_check_item(p, &x, depth) or_return }
		depth^ -= 1
	}
	return nil
}
