// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// grep-regex's inner literals (crates/regex/src/literal.rs, ripgrep 14.1.1): literals that
// every match contains somewhere, not only at its start. When the regex has no fast
// prefilter of its own, the line searcher looks for these first and runs the regex only on
// the lines that hold one ("fast line regex"). Its Extractor differs from regex-syntax's
// (hir_literal.odin): a concatenation may drop what comes before an inexact part and keep
// the best of the pieces ("choose"), and its limits are smaller.

@(private="file")
TSeq :: struct {
	seq:    Seq,
	prefix: bool,     // whether seq is a prefix of what follows it (false after a gap)
}

@(private="file")
LIMIT_CLASS :: 10
@(private="file")
LIMIT_REPEAT :: 10
@(private="file")
LIMIT_LITERAL_LEN :: 100
@(private="file")
LIMIT_TOTAL :: 64

@(private="file")
tseq :: proc(s: Seq) -> TSeq { return {seq = s, prefix = true} }

@(private="file")
tseq_empty_literal :: proc() -> TSeq { return tseq(seq_singleton(lit_exact(nil))) }

// InnerLiterals::new: the literals, or none (an infinite Seq) when the regex is already
// accelerated (unless it has a Unicode word boundary, which keeps the lazy DFA from it), or
// is an alternation of literals the regex engine handles itself
inner_literals :: proc(h: ^Hir, accelerated: bool) -> Seq {
	if accelerated && !look_set_contains_word_unicode(h.props.look_set) { return seq_infinite() }
	if h.props.alternation_literal { return seq_infinite() }
	return inner_extract_untagged(h)
}

// Extractor::extract_untagged: the literals, optimized, or none when they look slow
inner_extract_untagged :: proc(h: ^Hir) -> Seq {
	s := inner_extract(h)
	seq_optimize_for_prefix_by_preference(&s.seq)
	if !tseq_is_good(s) { seq_make_infinite(&s.seq) }
	return s.seq
}

@(private="file")
inner_extract :: proc(h: ^Hir) -> TSeq {
	switch h.kind {
	case .Empty, .Look:
		return tseq_empty_literal()
	case .Literal:
		s := tseq(seq_singleton(lit_exact(h.lit)))
		seq_keep_first_bytes(&s.seq, LIMIT_LITERAL_LEN)
		return s
	case .Class:
		return inner_class(h.class)
	case .Repetition:
		return inner_repetition(h)
	case .Capture:
		return inner_extract(h.sub)
	case .Concat:
		return inner_concat(h.subs[:])
	case .Alternation:
		return inner_alternation(h.subs[:])
	}
	unreachable()
}

@(private="file")
inner_concat :: proc(subs: []^Hir) -> TSeq {
	s := tseq_empty_literal()
	prev: Maybe(TSeq)
	for sub in subs {
		if seq_is_inexact(s.seq) {
			// nothing more can be appended: keep the best piece so far and start over
			if seq_is_empty(s.seq) { return s }
			if tseq_is_really_good(s) { return s }
			if p, ok := prev.?; ok { prev = tseq_choose(p, s) } else { prev = s }
			s = tseq_empty_literal()
			s.prefix = false
		}
		next := inner_extract(sub)
		s = inner_cross(s, &next)
	}
	if p, ok := prev.?; ok { return tseq_choose(p, s) }
	return s
}

@(private="file")
inner_alternation :: proc(subs: []^Hir) -> TSeq {
	s := tseq(seq_empty())
	for sub in subs {
		if !s.seq.finite { break }
		next := inner_extract(sub)
		s = inner_union(s, &next)
	}
	return s
}

@(private="file")
inner_repetition :: proc(h: ^Hir) -> TSeq {
	sub := inner_extract(h.sub)
	max_v, has_max := h.max.?
	switch {
	case h.min == 0:
		if !has_max || max_v != 1 { seq_make_inexact(&sub.seq) }
		empty := tseq_empty_literal()
		if !h.greedy { sub, empty = empty, sub }
		return inner_union(sub, &empty)
	case has_max && h.min == max_v, has_max && h.min < max_v:
		s := tseq_empty_literal()
		for _ in 0 ..< min(int(h.min), LIMIT_REPEAT) {
			if seq_is_inexact(s.seq) { break }
			c := TSeq{seq = seq_clone(sub.seq), prefix = sub.prefix}
			s = inner_cross(s, &c)
		}
		if h.min < max_v || int(h.min) > LIMIT_REPEAT { seq_make_inexact(&s.seq) }
		return s
	}
	seq_make_inexact(&sub.seq)
	return sub
}

@(private="file")
inner_class :: proc(c: Hir_Class) -> TSeq {
	count := 0
	for r in c.ranges {
		if count > LIMIT_CLASS { return tseq(seq_infinite()) }
		count += int(r.hi - r.lo) + 1
	}
	if count > LIMIT_CLASS { return tseq(seq_infinite()) }
	s := tseq(seq_empty())
	for r in c.ranges {
		for x := r.lo; x <= r.hi; x += 1 {
			if c.unicode {
				seq_push(&s.seq, lit_from_rune(rune(x)))
			} else {
				seq_push(&s.seq, lit_from_byte(u8(x)))
			}
		}
	}
	seq_keep_first_bytes(&s.seq, LIMIT_LITERAL_LEN)
	return s
}

@(private="file")
inner_cross :: proc(s1: TSeq, s2: ^TSeq) -> TSeq {
	seq1 := s1
	if !s2.prefix { return tseq_choose(seq1, s2^) }
	if n, ok := seq_max_cross_len(seq1.seq, s2.seq); ok && n > LIMIT_TOTAL {
		seq_make_infinite(&s2.seq)
	}
	seq_cross_forward(&seq1.seq, &s2.seq)
	seq_keep_first_bytes(&seq1.seq, LIMIT_LITERAL_LEN)
	return seq1
}

@(private="file")
inner_union :: proc(s1: TSeq, s2: ^TSeq) -> TSeq {
	seq1 := s1
	if n, ok := seq_max_union_len(seq1.seq, s2.seq); ok && n > LIMIT_TOTAL {
		seq_keep_first_bytes(&seq1.seq, 4)
		seq_keep_first_bytes(&s2.seq, 4)
		seq_dedup(&seq1.seq)
		seq_dedup(&s2.seq)
		if n2, ok2 := seq_max_union_len(seq1.seq, s2.seq); ok2 && n2 > LIMIT_TOTAL {
			seq_make_infinite(&s2.seq)
		}
	}
	prefix2 := s2.prefix
	seq_union(&seq1.seq, &s2.seq)
	seq1.prefix = seq1.prefix && prefix2
	return seq1
}

@(private="file")
tseq_has_poisonous :: proc(s: TSeq) -> bool {
	lits, ok := seq_literals(s.seq)
	if !ok { return false }
	for l in lits { if lit_is_poisonous(l) { return true } }
	return false
}

@(private="file")
tseq_is_good :: proc(s: TSeq) -> bool {
	if tseq_has_poisonous(s) { return false }
	mn, ok1 := seq_min_literal_len(s.seq)
	if !ok1 { return false }
	n, ok2 := seq_len(s.seq)
	if !ok2 { return false }
	if mn <= 1 { return n <= 3 }
	return mn >= 2 && n <= 64
}

@(private="file")
tseq_is_really_good :: proc(s: TSeq) -> bool {
	if tseq_has_poisonous(s) { return false }
	mn, ok1 := seq_min_literal_len(s.seq)
	if !ok1 { return false }
	n, ok2 := seq_len(s.seq)
	if !ok2 { return false }
	return mn >= 3 && n <= 8
}

// TSeq::choose: of two inexact pieces, the one more likely to be selective
@(private="file")
tseq_choose :: proc(a, b: TSeq) -> TSeq {
	seq1, seq2 := a, b
	seq_make_inexact(&seq1.seq)
	seq_make_inexact(&seq2.seq)
	if !seq1.seq.finite { return seq2 }
	if !seq2.seq.finite { return seq1 }
	if tseq_has_poisonous(seq1) { return seq2 }
	if tseq_has_poisonous(seq2) { return seq1 }
	min1, ok1 := seq_min_literal_len(seq1.seq)
	if !ok1 { return seq2 }
	min2, ok2 := seq_min_literal_len(seq2.seq)
	if !ok2 { return seq1 }
	if min1 < min2 { return seq2 }
	if min2 < min1 { return seq1 }
	len1, _ := seq_len(seq1.seq)
	len2, _ := seq_len(seq2.seq)
	if len1 < len2 { return seq2 }
	if len2 < len1 { return seq1 }
	return seq1
}
