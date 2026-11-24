// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"
import "core:unicode/utf8"

// regex-syntax 0.8.4's literal extraction (src/hir/literal.rs): an Extractor pulls a Seq of
// prefix or suffix literals out of an HIR; the Seq methods combine sequences (cross product,
// union) and shrink them in a preference-order preserving way for the prefilters.
//
// Memory: every Literal owns its bytes and every Seq its literals, all in context.allocator.
// A proc that takes `other: ^Seq` drains it the way the Rust code does (other is left empty, or
// infinite when it was); lit_destroy / seq_destroy free what is left. Callers that extract
// once and throw everything away are better served by an arena.

// ---------------------------------------------------------------------------------------------
// Literal

Literal :: struct {
	bytes: [dynamic]u8,
	exact: bool,
}

lit_exact :: proc(bytes: []u8) -> Literal {
	l := Literal{exact = true}
	append(&l.bytes, ..bytes)
	return l
}

lit_inexact :: proc(bytes: []u8) -> Literal {
	l := lit_exact(bytes)
	l.exact = false
	return l
}

// Literal::from(u8)
lit_from_byte :: proc(b: u8) -> Literal { return lit_exact({b}) }

// Literal::from(char): the code point's UTF-8 encoding
lit_from_rune :: proc(r: rune) -> Literal {
	buf, n := utf8.encode_rune(r)
	return lit_exact(buf[:n])
}

lit_clone :: proc(l: Literal) -> Literal {
	c := lit_exact(l.bytes[:])
	c.exact = l.exact
	return c
}

lit_destroy :: proc(l: ^Literal) {
	delete(l.bytes)
	l.bytes = nil
}

lit_as_bytes :: #force_inline proc(l: Literal) -> []u8 { return l.bytes[:] }
lit_len :: #force_inline proc(l: Literal) -> int { return len(l.bytes) }
lit_is_empty :: #force_inline proc(l: Literal) -> bool { return len(l.bytes) == 0 }
lit_is_exact :: #force_inline proc(l: Literal) -> bool { return l.exact }
lit_make_inexact :: #force_inline proc(l: ^Literal) { l.exact = false }

lit_equal :: proc(a, b: Literal) -> bool {
	return a.exact == b.exact && slice.equal(a.bytes[:], b.bytes[:])
}

// the derived Ord: bytes lexicographically, then inexact before exact
lit_less :: proc(a, b: Literal) -> bool {
	n := min(len(a.bytes), len(b.bytes))
	for i in 0 ..< n {
		if a.bytes[i] != b.bytes[i] { return a.bytes[i] < b.bytes[i] }
	}
	if len(a.bytes) != len(b.bytes) { return len(a.bytes) < len(b.bytes) }
	return !a.exact && b.exact
}

lit_reverse :: proc(l: ^Literal) { slice.reverse(l.bytes[:]) }

// appends lit's bytes; an inexact literal cannot be extended
lit_extend :: proc(l: ^Literal, lit: Literal) {
	if !l.exact { return }
	append(&l.bytes, ..lit.bytes[:])
}

lit_keep_first_bytes :: proc(l: ^Literal, n: int) {
	if n >= len(l.bytes) { return }
	l.exact = false
	resize(&l.bytes, n)
}

lit_keep_last_bytes :: proc(l: ^Literal, n: int) {
	if n >= len(l.bytes) { return }
	l.exact = false
	remove_range(&l.bytes, 0, len(l.bytes) - n)
}

// empty, or a single byte too common to be worth searching for
@(private="file")
lit_is_poisonous :: proc(l: Literal) -> bool {
	return len(l.bytes) == 0 || (len(l.bytes) == 1 && lit_rank(l.bytes[0]) >= 250)
}

// ---------------------------------------------------------------------------------------------
// Seq: a finite list of literals, or the infinite sequence (every possible literal)

Seq :: struct {
	lits:   [dynamic]Literal,
	finite: bool,
}

seq_empty :: proc() -> Seq { return Seq{finite = true} }

seq_infinite :: proc() -> Seq { return Seq{} }

seq_singleton :: proc(l: Literal) -> Seq {
	s := Seq{finite = true}
	append(&s.lits, l)
	return s
}

// Seq::new: exact literals, adjacent duplicates dropped (FromIterator goes through push)
seq_new :: proc(byte_strings: [][]u8) -> Seq {
	s := seq_empty()
	for b in byte_strings { seq_push(&s, lit_exact(b)) }
	return s
}

seq_clone :: proc(s: Seq) -> Seq {
	c := Seq{finite = s.finite}
	if s.finite {
		reserve(&c.lits, len(s.lits))
		for l in s.lits { append(&c.lits, lit_clone(l)) }
	}
	return c
}

@(private="file")
seq_clear_lits :: proc(s: ^Seq) {
	for &l in s.lits { lit_destroy(&l) }
	clear(&s.lits)
}

seq_destroy :: proc(s: ^Seq) {
	seq_clear_lits(s)
	delete(s.lits)
	s.lits = nil
	s.finite = false
}

seq_literals :: proc(s: Seq) -> (lits: []Literal, ok: bool) {
	if !s.finite { return nil, false }
	return s.lits[:], true
}

// takes ownership of l; a literal equal to the last one is dropped
seq_push :: proc(s: ^Seq, l: Literal) {
	l := l
	if !s.finite || (len(s.lits) > 0 && lit_equal(s.lits[len(s.lits) - 1], l)) {
		lit_destroy(&l)
		return
	}
	append(&s.lits, l)
}

seq_make_inexact :: proc(s: ^Seq) {
	if !s.finite { return }
	for &l in s.lits { l.exact = false }
}

seq_make_infinite :: proc(s: ^Seq) {
	seq_clear_lits(s)
	s.finite = false
}

// Every exact literal of s followed by every literal of other, in order; inexact literals of s
// are kept as they are. Drains other.
seq_cross_forward :: proc(s: ^Seq, other: ^Seq) {
	if !seq_cross_preamble(s, other) { return }
	old := s.lits
	s.lits = make([dynamic]Literal, 0, sat_mul(len(old), len(other.lits)))
	for &selflit in old {
		if !selflit.exact {
			append(&s.lits, selflit)
			continue
		}
		for otherlit in other.lits {
			newlit := Literal{exact = true}
			reserve(&newlit.bytes, len(selflit.bytes) + len(otherlit.bytes))
			lit_extend(&newlit, selflit)
			lit_extend(&newlit, otherlit)
			if !otherlit.exact { newlit.exact = false }
			append(&s.lits, newlit)
		}
		lit_destroy(&selflit)
	}
	delete(old)
	seq_clear_lits(other)
	seq_dedup(s)
}

// Every literal of other followed by every exact literal of s, other's literals in the outer
// loop; inexact literals of s are kept once, in the first pass. Drains other.
seq_cross_reverse :: proc(s: ^Seq, other: ^Seq) {
	if !seq_cross_preamble(s, other) { return }
	selflits := s.lits
	s.lits = make([dynamic]Literal, 0, sat_mul(len(selflits), len(other.lits)))
	for otherlit, i in other.lits {
		for selflit in selflits {
			if !selflit.exact {
				if i == 0 { append(&s.lits, lit_clone(selflit)) }
				continue
			}
			newlit := Literal{exact = true}
			reserve(&newlit.bytes, len(otherlit.bytes) + len(selflit.bytes))
			lit_extend(&newlit, otherlit)
			lit_extend(&newlit, selflit)
			if !otherlit.exact { newlit.exact = false }
			append(&s.lits, newlit)
		}
	}
	for &l in selflits { lit_destroy(&l) }
	delete(selflits)
	seq_clear_lits(other)
	seq_dedup(s)
}

// false when the cross product is already settled: other infinite (s becomes infinite when it
// can match the empty string, inexact otherwise), or s infinite (other drained)
@(private="file")
seq_cross_preamble :: proc(s: ^Seq, other: ^Seq) -> bool {
	if !other.finite {
		if n, ok := seq_min_literal_len(s^); ok && n == 0 {
			seq_make_infinite(s)
		} else {
			seq_make_inexact(s)
		}
		return false
	}
	if !s.finite {
		seq_clear_lits(other)
		return false
	}
	return true
}

// other's literals appended to s's, then deduplicated. Drains other; an infinite other makes s
// infinite.
seq_union :: proc(s: ^Seq, other: ^Seq) {
	if !other.finite {
		seq_make_infinite(s)
		return
	}
	if !s.finite {
		seq_clear_lits(other)
		return
	}
	append(&s.lits, ..other.lits[:])
	clear(&other.lits)
	seq_dedup(s)
}

// other's literals put where s's first empty literal was, every empty literal of s removed;
// nothing happens when s has no empty literal. Drains other.
seq_union_into_empty :: proc(s: ^Seq, other: ^Seq) {
	defer if other.finite { seq_clear_lits(other) }
	if !s.finite { return }
	first_empty := -1
	for l, i in s.lits {
		if len(l.bytes) == 0 { first_empty = i; break }
	}
	if first_empty < 0 { return }
	if !other.finite {
		seq_make_infinite(s)
		return
	}
	out := make([dynamic]Literal, 0, len(s.lits) + len(other.lits))
	for &l, i in s.lits {
		if i == first_empty { append(&out, ..other.lits[:]) }
		if len(l.bytes) == 0 { lit_destroy(&l) } else { append(&out, l) }
	}
	clear(&other.lits)
	delete(s.lits)
	s.lits = out
	seq_dedup(s)
}

// adjacent literals with the same bytes merged into one, inexact if either was
seq_dedup :: proc(s: ^Seq) {
	if !s.finite || len(s.lits) == 0 { return }
	w := 0
	for r in 1 ..< len(s.lits) {
		if slice.equal(s.lits[r].bytes[:], s.lits[w].bytes[:]) {
			if s.lits[r].exact != s.lits[w].exact { s.lits[w].exact = false }
			lit_destroy(&s.lits[r])
			continue
		}
		w += 1
		s.lits[w] = s.lits[r]
	}
	resize(&s.lits, w + 1)
}

seq_sort :: proc(s: ^Seq) {
	if !s.finite { return }
	slice.stable_sort_by(s.lits[:], lit_less)
}

seq_reverse_literals :: proc(s: ^Seq) {
	if !s.finite { return }
	for &l in s.lits { lit_reverse(&l) }
}

// drops every literal that has an earlier literal as a prefix (the earlier one made inexact),
// since a leftmost-first searcher would never report it
seq_minimize_by_preference :: proc(s: ^Seq) {
	if !s.finite { return }
	pref_trie_minimize(&s.lits, false)
}

seq_keep_first_bytes :: proc(s: ^Seq, n: int) {
	if !s.finite { return }
	for &l in s.lits { lit_keep_first_bytes(&l, n) }
}

seq_keep_last_bytes :: proc(s: ^Seq, n: int) {
	if !s.finite { return }
	for &l in s.lits { lit_keep_last_bytes(&l, n) }
}

seq_is_finite :: #force_inline proc(s: Seq) -> bool { return s.finite }

seq_is_empty :: proc(s: Seq) -> bool { return s.finite && len(s.lits) == 0 }

seq_len :: proc(s: Seq) -> (n: int, ok: bool) {
	if !s.finite { return 0, false }
	return len(s.lits), true
}

// finite and every literal exact (true for the empty sequence)
seq_is_exact :: proc(s: Seq) -> bool {
	if !s.finite { return false }
	for l in s.lits { if !l.exact { return false } }
	return true
}

// infinite, or no literal exact (true for the empty sequence too)
seq_is_inexact :: proc(s: Seq) -> bool {
	if !s.finite { return true }
	for l in s.lits { if l.exact { return false } }
	return true
}

seq_max_union_len :: proc(s, other: Seq) -> (n: int, ok: bool) {
	if !s.finite || !other.finite { return 0, false }
	a, b := len(s.lits), len(other.lits)
	return (max(int) if a > max(int) - b else a + b), true
}

seq_max_cross_len :: proc(s, other: Seq) -> (n: int, ok: bool) {
	if !s.finite || !other.finite { return 0, false }
	return sat_mul(len(s.lits), len(other.lits)), true
}

// none when infinite or empty
seq_min_literal_len :: proc(s: Seq) -> (n: int, ok: bool) {
	if !s.finite || len(s.lits) == 0 { return 0, false }
	n = max(int)
	for l in s.lits { n = min(n, len(l.bytes)) }
	return n, true
}

seq_max_literal_len :: proc(s: Seq) -> (n: int, ok: bool) {
	if !s.finite || len(s.lits) == 0 { return 0, false }
	for l in s.lits { n = max(n, len(l.bytes)) }
	return n, true
}

// none when infinite or empty; the slice points into the first literal
seq_longest_common_prefix :: proc(s: Seq) -> (fix: []u8, ok: bool) {
	if !s.finite || len(s.lits) == 0 { return nil, false }
	base := s.lits[0].bytes[:]
	n := len(base)
	for m in s.lits[1:] {
		k := 0
		for k < n && k < len(m.bytes) && m.bytes[k] == base[k] { k += 1 }
		n = k
		if n == 0 { return base[:0], true }
	}
	return base[:n], true
}

seq_longest_common_suffix :: proc(s: Seq) -> (fix: []u8, ok: bool) {
	if !s.finite || len(s.lits) == 0 { return nil, false }
	base := s.lits[0].bytes[:]
	n := len(base)
	for m in s.lits[1:] {
		k := 0
		for k < n && k < len(m.bytes) && m.bytes[len(m.bytes) - 1 - k] == base[len(base) - 1 - k] { k += 1 }
		n = k
		if n == 0 { return base[len(base):], true }
	}
	return base[len(base) - n:], true
}

seq_optimize_for_prefix_by_preference :: proc(s: ^Seq) { seq_optimize_by_preference(s, true) }

seq_optimize_for_suffix_by_preference :: proc(s: ^Seq) { seq_optimize_by_preference(s, false) }

// Shrinks the sequence for a prefilter (Teddy handles at most 64 literals well, and short or
// common-byte literals produce too many false candidates), preserving preference order. The
// result may be infinite, meaning: don't use a prefilter.
@(private="file")
seq_optimize_by_preference :: proc(s: ^Seq, prefix: bool) {
	origlen, finite := seq_len(s^)
	if !finite { return }
	// an empty literal matches everywhere
	if n, ok := seq_min_literal_len(s^); ok && n == 0 {
		seq_make_infinite(s)
		return
	}
	// a literal preceded by one of its prefixes can never match first (suffixes get no such
	// treatment: a reverse search is not leftmost-first)
	if prefix { pref_trie_minimize(&s.lits, true) }

	fix: []u8
	has_fix: bool
	if prefix { fix, has_fix = seq_longest_common_prefix(s^) } else { fix, has_fix = seq_longest_common_suffix(s^) }
	if has_fix {
		fix_len := len(fix)
		// a short common prefix of uncommon bytes: a memchr on its first byte beats Teddy
		if prefix && origlen > 1 && fix_len >= 1 && fix_len <= 3 && lit_rank(fix[0]) < 200 {
			seq_keep_first_bytes(s, 1)
			seq_dedup(s)
			return
		}
		n, _ := seq_len(s^)
		isfast := seq_is_exact(s^) && n <= 16
		usefix := fix_len > 4 || (fix_len > 1 && !isfast)
		if usefix {
			if prefix { seq_keep_first_bytes(s, fix_len) } else { seq_keep_last_bytes(s, fix_len) }
			seq_dedup(s)
			n2, _ := seq_len(s^)
			assert(n2 == 1)
		}
	}

	exact: Seq
	has_exact := seq_is_exact(s^)
	if has_exact { exact = seq_clone(s^) }
	ATTEMPTS :: [5][2]int{{5, 10}, {4, 10}, {3, 64}, {2, 64}, {1, 10}}
	for a in ATTEMPTS {
		keep, limit := a[0], a[1]
		n, ok := seq_len(s^)
		if !ok || n <= limit { break }
		if prefix { seq_keep_first_bytes(s, keep) } else { seq_keep_last_bytes(s, keep) }
		if prefix { pref_trie_minimize(&s.lits, true) }
	}
	if s.finite {
		for l in s.lits {
			if lit_is_poisonous(l) {
				seq_make_infinite(s)
				break
			}
		}
	}
	// an exact sequence that ended up unusable is better kept whole
	if has_exact {
		restore := !s.finite
		if !restore {
			mn, ok := seq_min_literal_len(s^)
			restore = !ok || mn <= 2
		}
		if !restore {
			n, _ := seq_len(s^)
			restore = n > 64
		}
		if restore {
			seq_destroy(s)
			s^ = exact
			return
		}
		seq_destroy(&exact)
	}
}

// ---------------------------------------------------------------------------------------------
// PreferenceTrie: a trie of the literals inserted so far, in order, refusing any literal that
// has an earlier one as a prefix

@(private="file")
Pref_Trie :: struct {
	states:             [dynamic][dynamic]Pref_Trans, // sorted by byte
	matches:            [dynamic]int,                 // literal index + 1, or 0
	next_literal_index: int,
}

@(private="file")
Pref_Trans :: struct {
	b:    u8,
	next: int,
}

// keeps the literals no earlier literal is a prefix of; unless keep_exact, the literal that
// caused a removal is made inexact
@(private="file")
pref_trie_minimize :: proc(literals: ^[dynamic]Literal, keep_exact: bool) {
	trie := Pref_Trie{next_literal_index = 1}
	defer {
		for &t in trie.states { delete(t) }
		delete(trie.states)
		delete(trie.matches)
	}
	make_inexact: [dynamic]int
	defer delete(make_inexact)
	w := 0
	for r in 0 ..< len(literals) {
		if idx, ok := pref_trie_insert(&trie, literals[r].bytes[:]); !ok {
			if !keep_exact { append(&make_inexact, idx - 1) }
			lit_destroy(&literals[r])
			continue
		}
		literals[w] = literals[r]
		w += 1
	}
	resize(literals, w)
	for i in make_inexact { literals[i].exact = false }
}

// Ok(index of the new literal), or Err(index of the earlier literal that is a prefix of bytes)
@(private="file")
pref_trie_insert :: proc(t: ^Pref_Trie, bytes: []u8) -> (idx: int, ok: bool) {
	prev := pref_trie_root(t)
	if m := t.matches[prev]; m != 0 { return m, false }
	for b in bytes {
		trans := t.states[prev][:]
		lo, hi := 0, len(trans)
		for lo < hi {
			mid := (lo + hi) / 2
			if trans[mid].b < b { lo = mid + 1 } else { hi = mid }
		}
		if lo < len(trans) && trans[lo].b == b {
			prev = trans[lo].next
			if m := t.matches[prev]; m != 0 { return m, false }
		} else {
			next := pref_trie_create_state(t)
			inject_at(&t.states[prev], lo, Pref_Trans{b, next})
			prev = next
		}
	}
	idx = t.next_literal_index
	t.next_literal_index += 1
	t.matches[prev] = idx
	return idx, true
}

@(private="file")
pref_trie_root :: proc(t: ^Pref_Trie) -> int {
	if len(t.states) > 0 { return 0 }
	return pref_trie_create_state(t)
}

@(private="file")
pref_trie_create_state :: proc(t: ^Pref_Trie) -> int {
	id := len(t.states)
	append(&t.states, [dynamic]Pref_Trans{})
	append(&t.matches, 0)
	return id
}

// ---------------------------------------------------------------------------------------------
// Extractor

Extract_Kind :: enum { Prefix, Suffix }

Extractor :: struct {
	kind:              Extract_Kind,
	limit_class:       int,
	limit_repeat:      int,
	limit_literal_len: int,
	limit_total:       int,
}

extractor_new :: proc(kind: Extract_Kind = .Prefix) -> Extractor {
	return {kind = kind, limit_class = 10, limit_repeat = 10, limit_literal_len = 100, limit_total = 250}
}

// The prefix (or suffix) literals of every match of h. A finite result covers every match
// (inexact literals being only a prefix of what matched); an infinite one says nothing.
extractor_extract :: proc(e: ^Extractor, h: ^Hir) -> Seq {
	switch h.kind {
	case .Empty, .Look:
		return seq_singleton(lit_exact(nil))
	case .Literal:
		seq := seq_singleton(lit_exact(h.lit))
		extract_enforce_literal_len(e, &seq)
		return seq
	case .Class:
		return extract_class(e, h.class)
	case .Repetition:
		return extract_repetition(e, h)
	case .Capture:
		return extractor_extract(e, h.sub)
	case .Concat:
		return extract_concat(e, h.subs[:])
	case .Alternation:
		return extract_alternation(e, h.subs[:])
	}
	unreachable()
}

// stops at the first inexact sequence: nothing after it can be appended
@(private="file")
extract_concat :: proc(e: ^Extractor, subs: []^Hir) -> Seq {
	seq := seq_singleton(lit_exact(nil))
	for i in 0 ..< len(subs) {
		if seq_is_inexact(seq) { break }
		sub := subs[i] if e.kind == .Prefix else subs[len(subs) - 1 - i]
		next := extractor_extract(e, sub)
		seq = extract_cross(e, seq, &next)
		seq_destroy(&next)
	}
	return seq
}

@(private="file")
extract_alternation :: proc(e: ^Extractor, subs: []^Hir) -> Seq {
	seq := seq_empty()
	for sub in subs {
		if !seq.finite { break }
		next := extractor_extract(e, sub)
		seq = extract_union(e, seq, &next)
		seq_destroy(&next)
	}
	return seq
}

@(private="file")
extract_repetition :: proc(e: ^Extractor, h: ^Hir) -> Seq {
	subseq := extractor_extract(e, h.sub)
	if h.min == 0 {
		if mx, ok := h.max.?; !ok || mx != 1 { seq_make_inexact(&subseq) }
		empty := seq_singleton(lit_exact(nil))
		// a lazy repetition prefers the empty match
		if !h.greedy { subseq, empty = empty, subseq }
		seq := extract_union(e, subseq, &empty)
		seq_destroy(&empty)
		return seq
	}
	defer seq_destroy(&subseq)
	limit := u32(e.limit_repeat) if e.limit_repeat <= int(max(u32)) else max(u32)
	seq := seq_singleton(lit_exact(nil))
	for _ in 0 ..< min(h.min, limit) {
		if seq_is_inexact(seq) { break }
		next := seq_clone(subseq)
		seq = extract_cross(e, seq, &next)
		seq_destroy(&next)
	}
	if mx, ok := h.max.?; ok && mx == h.min {
		// {n}: exact unless n was cut at the limit
		if h.min > limit { seq_make_inexact(&seq) }
	} else {
		seq_make_inexact(&seq)
	}
	return seq
}

// every code point (as UTF-8) or byte of the class, or infinite when it has too many
@(private="file")
extract_class :: proc(e: ^Extractor, c: Hir_Class) -> Seq {
	if extract_class_over_limit(e, c) { return seq_infinite() }
	seq := seq_empty()
	for r in c.ranges {
		for cp := r.lo; cp <= r.hi; cp += 1 {
			if c.unicode {
				if cp >= 0xD800 && cp <= 0xDFFF { continue }
				seq_push(&seq, lit_from_rune(rune(cp)))
			} else {
				seq_push(&seq, lit_from_byte(u8(cp)))
			}
		}
	}
	extract_enforce_literal_len(e, &seq)
	return seq
}

// a range's len counts the surrogates it spans, as ClassUnicodeRange::len does
@(private="file")
extract_class_over_limit :: proc(e: ^Extractor, c: Hir_Class) -> bool {
	count := 0
	for r in c.ranges {
		if count > e.limit_class { return true }
		count += int(r.hi - r.lo) + 1
	}
	return count > e.limit_class
}

// consumes seq1, drains seq2 (which goes infinite when the product would exceed limit_total)
@(private="file")
extract_cross :: proc(e: ^Extractor, seq1: Seq, seq2: ^Seq) -> Seq {
	seq1 := seq1
	if n, ok := seq_max_cross_len(seq1, seq2^); ok && n > e.limit_total { seq_make_infinite(seq2) }
	if e.kind == .Suffix { seq_cross_reverse(&seq1, seq2) } else { seq_cross_forward(&seq1, seq2) }
	if n, ok := seq_len(seq1); ok { assert(n <= e.limit_total) }
	extract_enforce_literal_len(e, &seq1)
	return seq1
}

// consumes seq1, drains seq2; over limit_total both are cut to 4 bytes first, and seq2 goes
// infinite if that is not enough
@(private="file")
extract_union :: proc(e: ^Extractor, seq1: Seq, seq2: ^Seq) -> Seq {
	seq1 := seq1
	if n, ok := seq_max_union_len(seq1, seq2^); ok && n > e.limit_total {
		if e.kind == .Prefix {
			seq_keep_first_bytes(&seq1, 4)
			seq_keep_first_bytes(seq2, 4)
		} else {
			seq_keep_last_bytes(&seq1, 4)
			seq_keep_last_bytes(seq2, 4)
		}
		seq_dedup(&seq1)
		seq_dedup(seq2)
		if n2, ok2 := seq_max_union_len(seq1, seq2^); ok2 && n2 > e.limit_total { seq_make_infinite(seq2) }
	}
	seq_union(&seq1, seq2)
	if n, ok := seq_len(seq1); ok { assert(n <= e.limit_total) }
	return seq1
}

@(private="file")
extract_enforce_literal_len :: proc(e: ^Extractor, seq: ^Seq) {
	if e.kind == .Prefix { seq_keep_first_bytes(seq, e.limit_literal_len) } else { seq_keep_last_bytes(seq, e.limit_literal_len) }
}

// ---------------------------------------------------------------------------------------------
// regex-syntax's rank::BYTE_FREQUENCIES: a heuristic background frequency rank of each byte
// (higher is more common)

lit_rank :: #force_inline proc(b: u8) -> u8 { return LIT_BYTE_FREQUENCIES[b] }

LIT_BYTE_FREQUENCIES := [256]u8{
	55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43, // 0x00
	42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32, 31, 30, 29, 28, // 0x10
	255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224, // 0x20
	208, 220, 204, 187, 183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126, // 0x30
	120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142, 137, 171, 176, 185, 167, // 0x40
	186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223, // 0x50
	151, 249, 216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244, // 0x60
	231, 139, 245, 243, 251, 235, 201, 196, 240, 214, 152, 182, 205, 181, 127, 27, // 0x70
	212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81, // 0x80
	207, 145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108, // 0x90
	118, 141, 113, 129, 119, 125, 165, 117, 92, 106, 83, 72, 99, 93, 65, 79, // 0xA0
	166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239, // 0xB0
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xC0
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xD0
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xE0
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, // 0xF0
}
