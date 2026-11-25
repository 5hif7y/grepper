// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:unicode/utf8"

// regex-automata's meta/prefix.rs and meta/reverse_suffix.rs (0.4.18, regex 1.13.1's fix of
// rust-lang/regex#1354): cheap, conservative proofs that the order in which a reverse
// strategy finds literal candidates is the order of the regex's matches. ripgrep 14.1.1
// (regex-automata 0.4.7) has no such check, and its reverse suffix search reports the first
// candidate confirmed even when a match starting earlier ends at a later one:
// `rg -o '[a-c][^\n]*xz|z'` on "a z xz" prints "z" twice, where the leftmost-first match is
// "a z xz". When no proof holds, the reverse strategy is not used.

// whether hir can match a string holding every byte of lit (low precision: when each byte
// can be consumed somewhere, the literal may occur)
prefix_hir_can_contain_literal :: proc(h: ^Hir, lit: []u8) -> bool {
	for b in lit {
		if !hir_can_consume_byte(h, b) { return false }
	}
	return true
}

// whether hir's minimum and maximum lengths are finite and equal
prefix_hir_has_fixed_length :: proc(h: ^Hir) -> bool {
	mn, ok1 := h.props.minimum_len.?
	mx, ok2 := h.props.maximum_len.?
	return ok1 && ok2 && mn == mx
}

// whether the first or last consuming child of prefix's top-level concatenation is a
// required class (or a repetition of one, at least once) disjoint from everything else in
// prefix and from every literal: a separator a reverse search cannot slide across either
// (for \w+\s+Holmes, the \s+ before Holmes)
prefix_has_disjoint_class_separator :: proc(prefix: ^Hir, literals: [][]u8) -> bool {
	top := uncapture(prefix)
	if top.kind != .Concat || len(top.subs) < 2 { return false }
	hirs := top.subs[:]
	first, last := -1, -1
	for h, i in hirs {
		if matches_empty_only(h) { continue }
		if first < 0 { first = i }
		last = i
	}
	if first < 0 { return false }
	return separator_at(hirs, last, literals) || (first != last && separator_at(hirs, first, literals))
}

// reverse_suffix::has_no_earlier_match: with suffix stripped from the end of the regex, the
// prefix left has a fixed length, or a class separator, or cannot contain the suffix
reverse_suffix_has_no_earlier_match :: proc(h: ^Hir, suffix: []u8) -> bool {
	if len(suffix) == 0 { return false }
	prefix, ok := strip_literal_suffix(drop_trailing_empty(h), suffix)
	if !ok { return false }
	if prefix_hir_has_fixed_length(prefix) { return true }
	lits := [1][]u8{suffix}
	if prefix_has_disjoint_class_separator(prefix, lits[:]) { return true }
	if !prefix_hir_can_contain_literal(prefix, suffix) { return true }
	if prefix_rest_cannot_start_literal(prefix, suffix) { return true }
	return false
}

// grepper's own proof, past regex 1.13.1's (P8). Say the first suffix occurrence the
// prefilter finds is [o, o + len) and the reverse scan from it reports a match M1 starting at
// s1 <= o. An earlier match M2 starts at s2 < s1 and ends at a later occurrence, so the
// occurrence at o begins inside M2's prefix part (if it reached into M2's own suffix, its
// first bytes would still be in the prefix part), at o - s2 >= 1 bytes from M2's start. When
// the prefix's first consuming child consumes exactly one byte, the bytes of the prefix part
// past the first are consumed by the children after it; if none of them can consume
// suffix[0], no such M2 exists. For [A-Z][a-z]+Error: [a-z]+ cannot consume 'E'.
prefix_rest_cannot_start_literal :: proc(prefix: ^Hir, suffix: []u8) -> bool {
	top := uncapture(prefix)
	if top.kind != .Concat { return false }
	hirs := top.subs[:]
	first := -1
	for h, i in hirs {
		if !matches_empty_only(h) { first = i; break }
	}
	if first < 0 { return false }
	mn, ok1 := hirs[first].props.minimum_len.?
	mx, ok2 := hirs[first].props.maximum_len.?
	if !ok1 || !ok2 || mn != 1 || mx != 1 { return false }
	for h in hirs[first + 1:] {
		if hir_can_consume_byte(h, suffix[0]) { return false }
	}
	return true
}

// hir without the zero-width children (look-around) at the end of its top-level
// concatenation: strip_literal_suffix stops at them, and the proofs are about the bytes a
// match consumes, which an assertion after the literal does not change (\s+Watson\b strips
// to \s+ as \s+Watson does). grepper's own, past regex 1.13.1 (P8)
@(private="file")
drop_trailing_empty :: proc(h: ^Hir) -> ^Hir {
	top := uncapture(h)
	if top.kind != .Concat { return h }
	n := len(top.subs)
	for n > 0 && matches_empty_only(top.subs[n - 1]) { n -= 1 }
	if n == len(top.subs) || n == 0 { return h }
	return hir_concat(top.subs[:n])
}

// hir with suffix removed from its end; not ok when the structure does not make that
// straightforward, even if the pattern might require the suffix
strip_literal_suffix :: proc(h: ^Hir, suffix: []u8) -> (prefix: ^Hir, ok: bool) {
	p, cursor := strip_at(h, suffix, len(suffix)) or_return
	if cursor != 0 { return nil, false }
	return p, true
}

// strip a terminal part of suffix[:cursor] from the end of hir; the cursor returned marks
// what remains to strip, and is above 0 only when the hir returned consumes nothing, so a
// concatenation can go on stripping from the child before
@(private="file")
strip_at :: proc(h: ^Hir, suffix: []u8, cursor: int) -> (p: ^Hir, after: int, ok: bool) {
	if cursor == 0 { return h, 0, true }
	#partial switch h.kind {
	case .Literal:
		b := h.lit
		n := 0
		for n < len(b) && n < cursor && b[len(b) - n - 1] == suffix[cursor - n - 1] { n += 1 }
		if n == 0 || (n < len(b) && n < cursor) { return }
		return hir_literal(b[:len(b) - n]), cursor - n, true
	case .Capture:
		return strip_at(h.sub, suffix, cursor)
	case .Concat:
		prefix := make([]^Hir, len(h.subs))
		copy(prefix, h.subs[:])
		cur := cursor
		#reverse for sub, i in h.subs {
			stripped, a := strip_at(sub, suffix, cur) or_return
			if a == cur { return }
			prefix[i] = stripped
			cur = a
			if cur == 0 { break }
		}
		return hir_concat(prefix), cur, true
	case .Repetition:
		return strip_repetition(h, suffix, cursor)
	}
	return
}

@(private="file")
strip_repetition :: proc(rep: ^Hir, suffix: []u8, cursor: int) -> (p: ^Hir, after: int, ok: bool) {
	mn := rep.min
	mx := rep.max
	cur := cursor
	tail: [dynamic]^Hir
	for cur > 0 {
		if mn == 0 { return }
		before := cur
		stripped, a := strip_at(rep.sub, suffix, cur) or_return
		if a == before { return }
		mn -= 1
		if m, has := mx.?; has { mx = m - 1 if m > 0 else 0 }
		if stripped.kind != .Empty { append(&tail, stripped) }
		cur = a
	}
	rest := hir_rep(mn, mx, rep.greedy, rep.sub)
	prefix: [dynamic]^Hir
	if rest.kind != .Empty { append(&prefix, rest) }
	#reverse for t in tail { append(&prefix, t) }
	return hir_concat(prefix[:]), 0, true
}

@(private="file")
separator_at :: proc(hirs: []^Hir, sep: int, literals: [][]u8) -> bool {
	cls, ok := required_class(hirs[sep])
	if !ok { return false }
	for lit in literals {
		if !class_is_disjoint_from_literal(cls, lit) { return false }
	}
	for h, i in hirs {
		if i != sep && !hir_is_disjoint_from_class(h, cls) { return false }
	}
	return true
}

@(private="file")
matches_empty_only :: proc(h: ^Hir) -> bool {
	mx, ok := h.props.maximum_len.?
	return ok && mx == 0
}

@(private="file")
required_class :: proc(h: ^Hir) -> (cls: ^Hir_Class, ok: bool) {
	h := uncapture(h)
	#partial switch h.kind {
	case .Class:
		return &h.class, true
	case .Repetition:
		if h.min > 0 {
			sub := uncapture(h.sub)
			if sub.kind == .Class { return &sub.class, true }
		}
	}
	return
}

@(private="file")
hir_is_disjoint_from_class :: proc(h: ^Hir, sep: ^Hir_Class) -> bool {
	switch h.kind {
	case .Empty, .Look: return true
	case .Literal: return class_is_disjoint_from_literal(sep, h.lit)
	case .Class: return classes_are_disjoint(&h.class, sep)
	case .Repetition, .Capture: return hir_is_disjoint_from_class(h.sub, sep)
	case .Concat, .Alternation:
		for s in h.subs {
			if !hir_is_disjoint_from_class(s, sep) { return false }
		}
		return true
	}
	return false
}

@(private="file")
uncapture :: proc(h: ^Hir) -> ^Hir {
	h := h
	for h.kind == .Capture { h = h.sub }
	return h
}

// a byte class and a Unicode class are never proven disjoint
@(private="file")
classes_are_disjoint :: proc(a, b: ^Hir_Class) -> bool {
	if a.unicode != b.unicode { return false }
	x := class_clone(a^)
	defer delete(x.ranges)
	class_intersect(&x, b^)
	return len(x.ranges) == 0
}

@(private="file")
class_contains :: proc(c: ^Hir_Class, v: u32) -> bool {
	for r in c.ranges {
		if r.lo <= v && v <= r.hi { return true }
	}
	return false
}

// a Unicode class is compared by scalar value, so lit must be valid UTF-8
@(private="file")
class_is_disjoint_from_literal :: proc(c: ^Hir_Class, lit: []u8) -> bool {
	if !c.unicode {
		for b in lit {
			if class_contains(c, u32(b)) { return false }
		}
		return true
	}
	if !utf8.valid_string(string(lit)) { return false }
	for r in string(lit) {
		if class_contains(c, u32(r)) { return false }
	}
	return true
}

// a Unicode class is taken to match any non-ASCII byte (bytes are not matched as scalar
// values; with \w that common, a fair approximation)
@(private="file")
hir_can_consume_byte :: proc(h: ^Hir, b: u8) -> bool {
	switch h.kind {
	case .Empty, .Look: return false
	case .Literal:
		for x in h.lit {
			if x == b { return true }
		}
		return false
	case .Class:
		if h.class.unicode && b > 0x7F { return true }
		return class_contains(&h.class, u32(b))
	case .Repetition, .Capture: return hir_can_consume_byte(h.sub, b)
	case .Concat, .Alternation:
		for s in h.subs {
			if hir_can_consume_byte(s, b) { return true }
		}
		return false
	}
	return false
}
