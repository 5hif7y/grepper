// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import nvol "nvol:odin"

// What a search looks for. Plain literals go to NVOL's kernels: one needle to memmem
// (memchr's Finder in ripgrep), several to Teddy (aho-corasick's packed searcher), with a
// memmem per needle when Teddy cannot take them (the cases aho-corasick also refuses).
// Anything else is a regex: the HIR compiled to a Thompson NFA, run by the PikeVM.
Matcher_Kind :: enum { Empty, Literal, Literals, Pike }

Matcher :: struct {
	kind:     Matcher_Kind,
	// grep-regex's line_terminator(): whether the searcher may run the regex over many lines
	// at once (the fast line path). Not when it holds a haystack anchor, `\A` or `\z`,
	// which would then match at the buffer's ends instead of each line's.
	line_term: bool,
	needles:  []string,
	finders:  []nvol.Memmem_Finder,
	teddy:    nvol.Teddy,
	teddy_ok: bool,
	nfa:      ^Rx_NFA,
	cache:    Pike_Cache,
	slots:    []int,
	dfa:      Lazy_Dfa,
	lit_slots: [2]int,     // group 0 of the last matcher_captures_at, for the literal kinds
	non_matching: [256]bool,   // grep-regex's non_matching_bytes: bytes no match contains
	// grep-regex's fast line regex: inner literals every match contains, searched first to
	// find a candidate line, which the regex then confirms (nil: none)
	fast_line: ^Prefilter,
}

// a worker's own copy: the memmem finders and the PikeVM's scratch change while searching
matcher_clone :: proc(m: Matcher) -> (c: Matcher) {
	c = m
	c.fast_line = prefilter_clone(m.fast_line)
	if m.finders != nil {
		c.finders = make([]nvol.Memmem_Finder, len(m.finders))
		copy(c.finders, m.finders)
	}
	if m.nfa != nil {
		c.cache = pike_cache_new(m.nfa)
		c.slots = make([]int, m.nfa.slots)
		c.dfa = dfa_new(m.nfa)
	}
	return
}

matcher_literals :: proc(needles: []string) -> (m: Matcher) {
	m.line_term = true
	for &b in m.non_matching { b = true }
	for n in needles {
		for c in transmute([]u8)n { m.non_matching[c] = false }
	}
	for n in needles {
		if len(n) == 0 {        // an empty pattern matches every line
			m.kind = .Empty
			return
		}
	}
	m.needles = needles
	m.finders = make([]nvol.Memmem_Finder, len(needles))
	for n, i in needles {
		m.finders[i] = nvol.memmem_finder(transmute([]u8)n)
	}
	if len(needles) == 1 {
		m.kind = .Literal
		return
	}
	m.kind = .Literals
	m.teddy, m.teddy_ok = nvol.teddy_build(needles)
	return
}

// regex-automata's meta strategy for one regex, as far as grepper has its engines: the
// regex's prefix literals (strategy.rs's `prefixes`, optimized for leftmost-first), unless
// the regex is anchored at the start. When they are exact and the regex has no captures and
// no look-around, the regex is those literals (Pre::from_prefixes) and a literal matcher
// runs it alone; otherwise they become the prefilter of the lazy DFA and the PikeVM.
matcher_from_hir :: proc(h: ^Hir) -> (m: Matcher) {
	if look_set_contains(h.props.look_set_prefix, .Start) { return matcher_pike(h, nil) }
	e := extractor_new(.Prefix)
	prefixes := extractor_extract(&e, h)
	seq_optimize_for_prefix_by_preference(&prefixes)
	lits, finite := seq_literals(prefixes)
	if !finite { return matcher_pike(h, nil) }
	needles := make([][]u8, len(lits))
	for l, i in lits { needles[i] = l.bytes[:] }
	pre, built := prefilter_new(needles)
	if !built { return matcher_pike(h, nil) }
	if seq_is_exact(prefixes) && h.props.explicit_captures_len == 0 && h.props.look_set == 0 {
		strs := make([]string, len(lits))
		for l, i in lits { strs[i] = string(l.bytes[:]) }
		m = matcher_literals(strs)
		m.non_matching = non_matching_bytes(h)
		return m
	}
	return matcher_pike(h, pre)
}

// RegexMatcher's fast_line_regex (InnerLiterals::new and one_regex), for a matcher built
// with a line terminator: skipped when the regex already has a fast prefilter, unless it has
// a Unicode word boundary
matcher_add_fast_line :: proc(m: ^Matcher, h: ^Hir) {
	accelerated := false
	switch m.kind {
	case .Empty:
		return
	case .Literal, .Literals:
		needles := make([][]u8, len(m.needles), context.temp_allocator)
		for n, i in m.needles { needles[i] = transmute([]u8)n }
		if p, ok := prefilter_new(needles); ok { accelerated = prefilter_is_fast(p) }
	case .Pike:
		accelerated = m.nfa.pre != nil && prefilter_is_fast(m.nfa.pre)
	}
	lits := inner_literals(h, accelerated)
	ls, finite := seq_literals(lits)
	if !finite || len(ls) == 0 { return }
	needles := make([][]u8, len(ls))
	for l, i in ls { needles[i] = l.bytes[:] }
	if p, ok := prefilter_new(needles); ok { m.fast_line = p }
}

matcher_pike :: proc(h: ^Hir, pre: ^Prefilter) -> (m: Matcher) {
	m.kind = .Pike
	m.line_term = !look_set_contains_anchor_haystack(h.props.look_set)
	m.non_matching = non_matching_bytes(h)
	m.nfa = new(Rx_NFA)
	m.nfa^ = rx_compile(h)
	rx_finish(m.nfa)
	m.nfa.pre = pre
	m.cache = pike_cache_new(m.nfa)
	m.slots = make([]int, m.nfa.slots)
	m.dfa = dfa_new(m.nfa)
	return
}

// whether a match ends in hay[start:], and where the first does: the lazy DFA, or the
// PikeVM when the DFA gives up
@(private="file")
earliest :: proc(m: ^Matcher, hay: []u8, start: int) -> (end: int, ok: bool) {
	at, r := dfa_find_earliest(&m.dfa, hay, start, len(hay))
	switch r {
	case .Match: return at, true
	case .No_Match: return 0, false
	case .Quit:
	}
	if !pike_search(m.nfa, &m.cache, hay, start, len(hay), false, m.slots) { return }
	return m.slots[1], true
}

// grep-matcher's Matcher, as the searcher and printers call it. Lines never contain a match
// across a line terminator (strip_from_match removed it from the regex), so a candidate line
// is always confirmed.
matcher_find_at :: proc(m: ^Matcher, hay: []u8, at: int) -> (r: Range, ok: bool) {
	s, e := find(m, hay, at, len(hay)) or_return
	return {s, e}, true
}

matcher_is_match :: proc(m: ^Matcher, line: []u8) -> bool {
	if m.kind == .Pike {
		_, ok := earliest(m, line, 0)
		return ok
	}
	_, _, ok := find(m, line, 0, len(line))
	return ok
}

// ripgrep's shortest_match: the end of a match
// (the DFA's end is the earliest end, not the leftmost-first match's; both lie on the
// first line holding a match, since no match crosses a line terminator)
matcher_find_candidate_line :: proc(m: ^Matcher, buf: []u8) -> (at: int, confirmed: bool, ok: bool) {
	if m.fast_line != nil {
		// a line holding an inner literal; the searcher confirms it with the regex
		r := prefilter_find(m.fast_line, buf, 0, len(buf)) or_return
		return r.end, false, true
	}
	if m.kind == .Pike {
		e := earliest(m, buf, 0) or_return
		return e, true, true
	}
	_, e := find(m, buf, 0, len(buf)) or_return
	return e, true, true
}

// grep-matcher's captures_at: the leftmost-first match in hay[at:] and its capture groups,
// read back with matcher_group
matcher_captures_at :: proc(m: ^Matcher, hay: []u8, at: int) -> bool {
	s, e, ok := find(m, hay, at, len(hay))
	if ok && m.kind != .Pike { m.lit_slots = {s, e} }
	return ok
}

// the capture group i of the last matcher_captures_at (not ok when it did not take part);
// the literal kinds have group 0 only
matcher_group :: proc(m: ^Matcher, i: int) -> (r: Range, ok: bool) {
	if m.kind != .Pike {
		if i != 0 { return }
		return {m.lit_slots[0], m.lit_slots[1]}, true
	}
	if 2 * i + 1 >= len(m.slots) || m.slots[2 * i] < 0 || m.slots[2 * i + 1] < 0 { return }
	return {m.slots[2 * i], m.slots[2 * i + 1]}, true
}

// The leftmost-first match in hay[start:end): its bounds in hay. Among needles starting at
// the same byte, the first given.
find :: proc(m: ^Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	switch m.kind {
	case .Empty:
		return start, start, true
	case .Literal:
		i := nvol.memmem_find(&m.finders[0], hay[start:end]) or_return
		return start + i, start + i + len(m.needles[0]), true
	case .Literals:
		if m.teddy_ok {
			t := nvol.teddy_find_in(&m.teddy, hay, start, end) or_return
			return t.start, t.end, true
		}
		best := -1
		for _, k in m.needles {
			i, found := nvol.memmem_find(&m.finders[k], hay[start:end])
			if found && (best < 0 || start + i < s) {
				best, s, e = k, start + i, start + i + len(m.needles[k])
			}
		}
		return s, e, best >= 0
	case .Pike:
		if !pike_search(m.nfa, &m.cache, hay[:end], start, end, false, m.slots) { return }
		return m.slots[0], m.slots[1], true
	}
	return
}
