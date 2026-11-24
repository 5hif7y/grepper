// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strconv"
import "core:strings"

// regex-syntax 0.8.4's abstract syntax (src/ast/mod.rs) and its error messages and
// formatter (src/error.rs): ripgrep prints a pattern's parse error through them, caret
// diagram included.

Position :: struct {
	offset, line, column: int,
}

Span :: struct {
	start, end: Position,
}

span_splat :: #force_inline proc(p: Position) -> Span { return {p, p} }

span_less :: proc(a, b: Span) -> bool {
	if a.start.offset != b.start.offset { return a.start.offset < b.start.offset }
	return a.end.offset < b.end.offset
}

Ast_Error_Kind :: enum {
	Capture_Limit_Exceeded,
	Class_Escape_Invalid,
	Class_Range_Invalid,
	Class_Range_Literal,
	Class_Unclosed,
	Decimal_Empty,
	Decimal_Invalid,
	Escape_Hex_Empty,
	Escape_Hex_Invalid,
	Escape_Hex_Invalid_Digit,
	Escape_Unexpected_Eof,
	Escape_Unrecognized,
	Flag_Dangling_Negation,
	Flag_Duplicate,
	Flag_Repeated_Negation,
	Flag_Unexpected_Eof,
	Flag_Unrecognized,
	Group_Name_Duplicate,
	Group_Name_Empty,
	Group_Name_Invalid,
	Group_Name_Unexpected_Eof,
	Group_Unclosed,
	Group_Unopened,
	Nest_Limit_Exceeded,
	Repetition_Count_Invalid,
	Repetition_Count_Decimal_Empty,
	Repetition_Count_Unclosed,
	Repetition_Missing,
	Special_Word_Boundary_Unclosed,
	Special_Word_Boundary_Unrecognized,
	Special_Word_Or_Repetition_Unexpected_Eof,
	Unicode_Class_Invalid,
	Unsupported_Backreference,
	Unsupported_Look_Around,
}

Ast_Error :: struct {
	kind:     Ast_Error_Kind,
	pattern:  string,
	span:     Span,
	aux_span: Maybe(Span),     // FlagDuplicate, FlagRepeatedNegation, GroupNameDuplicate
	limit:    u32,             // NestLimitExceeded
}

ast_error_kind_string :: proc(e: Ast_Error) -> string {
	switch e.kind {
	case .Capture_Limit_Exceeded: return "exceeded the maximum number of capturing groups (4294967295)"
	case .Class_Escape_Invalid: return "invalid escape sequence found in character class"
	case .Class_Range_Invalid: return "invalid character class range, the start must be <= the end"
	case .Class_Range_Literal: return "invalid range boundary, must be a literal"
	case .Class_Unclosed: return "unclosed character class"
	case .Decimal_Empty: return "decimal literal empty"
	case .Decimal_Invalid: return "decimal literal invalid"
	case .Escape_Hex_Empty: return "hexadecimal literal empty"
	case .Escape_Hex_Invalid: return "hexadecimal literal is not a Unicode scalar value"
	case .Escape_Hex_Invalid_Digit: return "invalid hexadecimal digit"
	case .Escape_Unexpected_Eof: return "incomplete escape sequence, reached end of pattern prematurely"
	case .Escape_Unrecognized: return "unrecognized escape sequence"
	case .Flag_Dangling_Negation: return "dangling flag negation operator"
	case .Flag_Duplicate: return "duplicate flag"
	case .Flag_Repeated_Negation: return "flag negation operator repeated"
	case .Flag_Unexpected_Eof: return "expected flag but got end of regex"
	case .Flag_Unrecognized: return "unrecognized flag"
	case .Group_Name_Duplicate: return "duplicate capture group name"
	case .Group_Name_Empty: return "empty capture group name"
	case .Group_Name_Invalid: return "invalid capture group character"
	case .Group_Name_Unexpected_Eof: return "unclosed capture group name"
	case .Group_Unclosed: return "unclosed group"
	case .Group_Unopened: return "unopened group"
	case .Nest_Limit_Exceeded:
		buf: [16]u8
		return strings.concatenate({"exceed the maximum number of nested parentheses/brackets (", strconv.write_uint(buf[:], u64(e.limit), 10), ")"})
	case .Repetition_Count_Invalid: return "invalid repetition count range, the start must be <= the end"
	case .Repetition_Count_Decimal_Empty: return "repetition quantifier expects a valid decimal"
	case .Repetition_Count_Unclosed: return "unclosed counted repetition"
	case .Repetition_Missing: return "repetition operator missing expression"
	case .Special_Word_Boundary_Unclosed: return "special word boundary assertion is either unclosed or contains an invalid character"
	case .Special_Word_Boundary_Unrecognized: return "unrecognized special word boundary assertion, valid choices are: start, end, start-half or end-half"
	case .Special_Word_Or_Repetition_Unexpected_Eof: return "found either the beginning of a special word boundary or a bounded repetition on a \\b with an opening brace, but no closing brace"
	case .Unicode_Class_Invalid: return "invalid Unicode character class"
	case .Unsupported_Backreference: return "backreferences are not supported"
	case .Unsupported_Look_Around: return "look-around, including look-ahead and look-behind, is not supported"
	}
	return ""
}

// Rust's str::lines: split on \n, a trailing \r dropped, no last empty line
rust_lines :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := s
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		if strings.has_suffix(line, "\r") { line = line[:len(line) - 1] }
		append(&out, line)
	}
	return out[:]
}

// regex-syntax's error Formatter: the pattern with carets under the spans, then the message
format_syntax_error :: proc(pattern: string, span: Span, aux: Maybe(Span), message: string) -> string {
	lines := rust_lines(pattern)
	line_count := len(lines)
	if strings.has_suffix(pattern, "\n") { line_count += 1 }
	width := 0
	if line_count > 1 {
		buf: [24]u8
		width = len(strconv.write_uint(buf[:], u64(line_count), 10))
	}
	by_line := make([][dynamic]Span, max(line_count, 1), context.temp_allocator)
	multi: [dynamic]Span
	multi.allocator = context.temp_allocator
	add :: proc(by_line: [][dynamic]Span, multi: ^[dynamic]Span, s: Span) {
		if s.start.line == s.end.line {
			i := s.start.line - 1
			append(&by_line[i], s)
			for k := len(by_line[i]) - 1; k > 0 && span_less(by_line[i][k], by_line[i][k - 1]); k -= 1 {
				by_line[i][k], by_line[i][k - 1] = by_line[i][k - 1], by_line[i][k]
			}
		} else {
			append(multi, s)
		}
	}
	add(by_line, &multi, span)
	if a, ok := aux.?; ok { add(by_line, &multi, a) }
	b: strings.Builder
	notate :: proc(b: ^strings.Builder, lines: []string, by_line: [][dynamic]Span, width: int) {
		pad := 4 if width == 0 else 2 + width
		for line, i in lines {
			if width > 0 {
				buf: [24]u8
				n := strconv.write_uint(buf[:], u64(i + 1), 10)
				for _ in 0 ..< width - len(n) { strings.write_byte(b, ' ') }
				strings.write_string(b, n)
				strings.write_string(b, ": ")
			} else {
				strings.write_string(b, "    ")
			}
			strings.write_string(b, line)
			strings.write_byte(b, '\n')
			if i < len(by_line) && len(by_line[i]) > 0 {
				for _ in 0 ..< pad { strings.write_byte(b, ' ') }
				pos := 0
				for s in by_line[i] {
					for ; pos < s.start.column - 1; pos += 1 { strings.write_byte(b, ' ') }
					n := max(1, s.end.column - s.start.column)
					for _ in 0 ..< n { strings.write_byte(b, '^'); pos += 1 }
				}
				strings.write_byte(b, '\n')
			}
		}
	}
	strings.write_string(&b, "regex parse error:\n")
	if strings.index_byte(pattern, '\n') >= 0 {
		divider := strings.repeat("~", 79, context.temp_allocator)
		strings.write_string(&b, divider)
		strings.write_byte(&b, '\n')
		notate(&b, lines, by_line, width)
		strings.write_string(&b, divider)
		strings.write_byte(&b, '\n')
		for s, k in multi {
			buf: [4][24]u8
			if k > 0 { strings.write_byte(&b, '\n') }
			strings.write_string(&b, "on line ")
			strings.write_string(&b, strconv.write_uint(buf[0][:], u64(s.start.line), 10))
			strings.write_string(&b, " (column ")
			strings.write_string(&b, strconv.write_uint(buf[1][:], u64(s.start.column), 10))
			strings.write_string(&b, ") through line ")
			strings.write_string(&b, strconv.write_uint(buf[2][:], u64(s.end.line), 10))
			strings.write_string(&b, " (column ")
			strings.write_string(&b, strconv.write_uint(buf[3][:], u64(s.end.column - 1), 10))
			strings.write_string(&b, ")")
		}
		if len(multi) > 0 { strings.write_byte(&b, '\n') }
	} else {
		notate(&b, lines, by_line, width)
	}
	strings.write_string(&b, "error: ")
	strings.write_string(&b, message)
	return strings.to_string(b)
}

ast_error_string :: proc(e: Ast_Error) -> string {
	return format_syntax_error(e.pattern, e.span, e.aux_span, ast_error_kind_string(e))
}

// ---------------------------------------------------------------------------------------------
// The tree

Literal_Kind :: enum { Verbatim, Meta, Superfluous, Octal, Hex_Fixed, Hex_Brace, Special }
Hex_Literal_Kind :: enum { X, Unicode_Short, Unicode_Long }

Ast_Literal :: struct {
	span: Span,
	kind: Literal_Kind,
	hex:  Hex_Literal_Kind,
	c:    rune,
}

// Literal::byte: a \xNN literal as a byte
ast_literal_byte :: proc(l: Ast_Literal) -> (b: u8, ok: bool) {
	if l.kind == .Hex_Fixed && l.hex == .X && l.c <= 0xFF { return u8(l.c), true }
	return
}

Class_Perl_Kind :: enum { Digit, Space, Word }

Class_Perl :: struct {
	span:    Span,
	kind:    Class_Perl_Kind,
	negated: bool,
}

Class_Ascii_Kind :: enum { Alnum, Alpha, Ascii, Blank, Cntrl, Digit, Graph, Lower, Print, Punct, Space, Upper, Word, Xdigit }

Class_Ascii :: struct {
	span:    Span,
	kind:    Class_Ascii_Kind,
	negated: bool,
}

class_ascii_from_name :: proc(name: string) -> (k: Class_Ascii_Kind, ok: bool) {
	switch name {
	case "alnum": return .Alnum, true
	case "alpha": return .Alpha, true
	case "ascii": return .Ascii, true
	case "blank": return .Blank, true
	case "cntrl": return .Cntrl, true
	case "digit": return .Digit, true
	case "graph": return .Graph, true
	case "lower": return .Lower, true
	case "print": return .Print, true
	case "punct": return .Punct, true
	case "space": return .Space, true
	case "upper": return .Upper, true
	case "word": return .Word, true
	case "xdigit": return .Xdigit, true
	}
	return
}

Class_Unicode_Kind :: enum { One_Letter, Named, Named_Value }
Class_Unicode_Op :: enum { Equal, Colon, Not_Equal }

Class_Unicode :: struct {
	span:    Span,
	negated: bool,
	kind:    Class_Unicode_Kind,
	letter:  rune,
	name:    string,
	value:   string,
	op:      Class_Unicode_Op,
}

// ClassUnicode::is_negated: `\p{x!=y}` flips the negation
class_unicode_is_negated :: proc(c: Class_Unicode) -> bool {
	if c.kind == .Named_Value && c.op == .Not_Equal { return !c.negated }
	return c.negated
}

Class_Set_Item_Kind :: enum { Empty, Literal, Range, Ascii, Unicode, Perl, Bracketed, Union }

Class_Set_Item :: struct {
	kind:      Class_Set_Item_Kind,
	span:      Span,
	lit:       Ast_Literal,           // Literal; Range start
	lit_end:   Ast_Literal,           // Range end
	ascii:     Class_Ascii,
	unicode:   Class_Unicode,
	perl:      Class_Perl,
	bracketed: ^Class_Bracketed,
	items:     [dynamic]Class_Set_Item,   // Union
}

Class_Set_Op_Kind :: enum { Intersection, Difference, Symmetric_Difference }

// ClassSet: an item or a binary operation
Class_Set :: struct {
	is_op:   bool,
	item:    Class_Set_Item,
	op_span: Span,
	op:      Class_Set_Op_Kind,
	lhs:     ^Class_Set,
	rhs:     ^Class_Set,
}

class_set_span :: proc(s: ^Class_Set) -> Span {
	return s.op_span if s.is_op else s.item.span
}

Class_Bracketed :: struct {
	span:    Span,
	negated: bool,
	kind:    Class_Set,
}

// ClassSetUnion helpers
Class_Set_Union :: struct {
	span:  Span,
	items: [dynamic]Class_Set_Item,
}

union_push :: proc(u: ^Class_Set_Union, item: Class_Set_Item) {
	if len(u.items) == 0 { u.span.start = item.span.start }
	u.span.end = item.span.end
	append(&u.items, item)
}

union_into_item :: proc(u: Class_Set_Union) -> Class_Set_Item {
	switch len(u.items) {
	case 0: return {kind = .Empty, span = u.span}
	case 1: return u.items[0]
	}
	return {kind = .Union, span = u.span, items = u.items}
}

Assertion_Kind :: enum {
	Start_Line, End_Line, Start_Text, End_Text, Word_Boundary, Not_Word_Boundary,
	Word_Boundary_Start, Word_Boundary_End, Word_Boundary_Start_Angle, Word_Boundary_End_Angle,
	Word_Boundary_Start_Half, Word_Boundary_End_Half,
}

Repetition_Kind :: enum { Zero_Or_One, Zero_Or_More, One_Or_More, Range }
Repetition_Range_Kind :: enum { Exactly, At_Least, Bounded }

Repetition_Op :: struct {
	span:       Span,
	kind:       Repetition_Kind,
	range_kind: Repetition_Range_Kind,
	min, max:   u32,
}

Regex_Flag :: enum { Case_Insensitive, Multi_Line, Dot_Matches_New_Line, Swap_Greed, Unicode, CRLF, Ignore_Whitespace }

Flags_Item :: struct {
	span:     Span,
	negation: bool,      // the '-' item
	flag:     Regex_Flag,
}

Ast_Flags :: struct {
	span:  Span,
	items: [dynamic]Flags_Item,
}

// Flags::add_item: the index of an item of the same kind already there
flags_add_item :: proc(f: ^Ast_Flags, item: Flags_Item) -> (dup: int, found: bool) {
	for x, i in f.items {
		if x.negation == item.negation && (item.negation || x.flag == item.flag) { return i, true }
	}
	append(&f.items, item)
	return
}

flags_state :: proc(f: ^Ast_Flags, flag: Regex_Flag) -> (on: bool, set: bool) {
	negated := false
	for x in f.items {
		if x.negation {
			negated = true
		} else if x.flag == flag {
			return !negated, true
		}
	}
	return
}

Group_Kind :: enum { Capture_Index, Capture_Name, Non_Capturing }

Capture_Name :: struct {
	span:  Span,
	name:  string,
	index: u32,
}

Ast_Kind :: enum { Empty, Flags, Literal, Dot, Assertion, Class_Unicode, Class_Perl, Class_Bracketed, Repetition, Group, Alternation, Concat }

Ast :: struct {
	kind:          Ast_Kind,
	span:          Span,
	flags:         Ast_Flags,          // Flags; Group (Non_Capturing)
	lit:           Ast_Literal,
	assertion:     Assertion_Kind,
	cls_unicode:   Class_Unicode,
	cls_perl:      Class_Perl,
	bracketed:     ^Class_Bracketed,
	op:            Repetition_Op,
	greedy:        bool,
	sub:           ^Ast,               // Repetition, Group
	group_kind:    Group_Kind,
	capture_index: u32,
	capture_name:  Capture_Name,
	starts_with_p: bool,
	asts:          [dynamic]^Ast,      // Alternation, Concat
}

new_ast :: proc(a: Ast) -> ^Ast {
	p := new(Ast)
	p^ = a
	return p
}

// Concat::into_ast / Alternation::into_ast
asts_into_ast :: proc(kind: Ast_Kind, span: Span, asts: [dynamic]^Ast) -> ^Ast {
	switch len(asts) {
	case 0: return new_ast({kind = .Empty, span = span})
	case 1: return asts[0]
	}
	return new_ast({kind = kind, span = span, asts = asts})
}
