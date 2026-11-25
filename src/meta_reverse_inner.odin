// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// regex-automata's meta/reverse_inner.rs (0.4.18): the inner literals of a regex and the
// part of it before them. The regex must be a top-level concatenation (captures are looked
// through and dropped); the first child after the first with a fast prefilter of its prefix
// literals splits it. The literals, a prefilter over them, and the concatenation before
// them, which the reverse inner search compiles in reverse.

Inner_Prefilter :: struct {
	prefix:   ^Hir,
	pre:      ^Prefilter,
	literals: [][]u8,
}

// InnerPrefilter::new
inner_prefilter :: proc(h: ^Hir) -> (ip: Inner_Prefilter, ok: bool) {
	concat := top_concat(h) or_return
	// the first child is skipped: a prefix prefilter would have been found already
	for i in 1 ..< len(concat) {
		pre, lits := prefilter_with_literals(concat[i]) or_continue
		if !prefilter_is_fast(pre) { continue }
		suffix := hir_concat(concat[i:])
		prefix := hir_concat(concat[:i])
		// the whole suffix may give better literals than its first child
		if pre2, lits2, ok2 := prefilter_with_literals(suffix); ok2 && prefilter_is_fast(pre2) {
			pre, lits = pre2, lits2
		}
		return {prefix = prefix, pre = pre, literals = lits}, true
	}
	return
}

// reverse_inner::has_no_earlier_match (regex 1.13.1's fix of rust-lang/regex#1354): the
// first candidate the reverse inner search confirms is the leftmost-first match. One literal
// the prefix cannot contain; or a prefix of fixed length; or a class separator
reverse_inner_has_no_earlier_match :: proc(prefix: ^Hir, literals: [][]u8) -> bool {
	if len(literals) == 0 { return false }
	for l in literals {
		if len(l) == 0 { return false }
	}
	// with one literal, an occurrence crossing into the prefix must overlap another of the
	// same literal, which needs the prefix to consume each of its bytes
	if len(literals) == 1 && !prefix_hir_can_contain_literal(prefix, literals[0]) { return true }
	if prefix_hir_has_fixed_length(prefix) { return true }
	if prefix_has_disjoint_class_separator(prefix, literals) { return true }
	return false
}

// the prefix literals of hir, made inexact (inner literals never are exact; exact ones
// would weigh the optimization towards, e.g., \s as single bytes) and optimized for
// leftmost-first, with a prefilter over them
@(private="file")
prefilter_with_literals :: proc(h: ^Hir) -> (pre: ^Prefilter, lits: [][]u8, ok: bool) {
	e := extractor_new(.Prefix)
	prefixes := extractor_extract(&e, h)
	seq_make_inexact(&prefixes)
	seq_optimize_for_prefix_by_preference(&prefixes)
	ls := seq_literals(prefixes) or_return
	needles := make([][]u8, len(ls))
	for l, i in ls { needles[i] = l.bytes[:] }
	pre = prefilter_new(needles) or_return
	return pre, needles, true
}

// a top-level concatenation, looked for through captures, as a copy without captures
@(private="file")
top_concat :: proc(h: ^Hir) -> (subs: []^Hir, ok: bool) {
	h := h
	for {
		#partial switch h.kind {
		case .Capture:
			h = h.sub
		case .Concat:
			flat := make([]^Hir, len(h.subs))
			for s, i in h.subs { flat[i] = flatten(s) }
			c := hir_concat(flat)
			// the smart constructor may simplify the concatenation away
			if c.kind != .Concat { return }
			return c.subs[:], true
		case:
			return
		}
	}
}

// a copy of hir without capture groups
@(private="file")
flatten :: proc(h: ^Hir) -> ^Hir {
	switch h.kind {
	case .Empty: return hir_empty()
	case .Literal: return hir_literal(h.lit)
	case .Class: return hir_class(class_clone(h.class))
	case .Look: return hir_look(h.look)
	case .Repetition: return hir_rep(h.min, h.max, h.greedy, flatten(h.sub))
	case .Capture: return flatten(h.sub)
	case .Alternation, .Concat:
		subs := make([]^Hir, len(h.subs))
		for s, i in h.subs { subs[i] = flatten(s) }
		return hir_alternation(subs) if h.kind == .Alternation else hir_concat(subs)
	}
	unreachable()
}
