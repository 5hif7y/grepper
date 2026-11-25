// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import nvol "nvol:odin"

// What a search looks for. Plain literals go to NVOL's kernels: one needle to memmem
// (memchr's Finder in ripgrep), several to Teddy (aho-corasick's packed searcher), with a
// memmem per needle when Teddy cannot take them (the cases aho-corasick also refuses).
// Anything else is a regex: the HIR compiled to a Thompson NFA, run by the PikeVM.
Matcher_Kind :: enum { Empty, Literal, Literals, Pike }

// regex-automata's meta strategy over the Core engines (meta/strategy.rs::new), tried in this
// order: the reverse anchored, reverse suffix and reverse inner searches, else Core
Meta_Strategy :: enum { Core, Reverse_Anchored, Reverse_Suffix, Reverse_Inner }

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
	// the meta engine's hybrid regex: a forward leftmost-first lazy DFA for the end of a
	// match, a reverse one (MatchKind::All, over nfa_rev) for its start
	nfa_rev:  ^Rx_NFA,
	dfa_fwd:  Lazy_Dfa,
	dfa_rev:  Lazy_Dfa,
	lit_slots: [2]int,     // group 0 of the last matcher_captures_at, for the literal kinds
	bt:        Backtrack_Cache,
	bt_max:    int,        // the longest haystack the backtracker takes
	non_matching: [256]bool,   // grep-regex's non_matching_bytes: bytes no match contains
	// grep-regex's fast line regex: inner literals every match contains, searched first to
	// find a candidate line, which the regex then confirms (nil: none)
	fast_line: ^Prefilter,
	strategy:  Meta_Strategy,
	// whether the lazy DFAs fit --dfa-size-limit at all; without them the backtracker and
	// the PikeVM run every search, and no reverse strategy is used
	dfa_ok:    bool,
	suffix_pre: ^Prefilter,   // ReverseSuffix: the longest common suffix's prefilter
	// ReverseInner: the inner literals' prefilter, and the part of the regex before them
	// compiled in reverse, with its All DFA
	inner_pre: ^Prefilter,
	inner_nfa: ^Rx_NFA,
	inner_dfa: Lazy_Dfa,
}

// a worker's own copy: the memmem finders and the PikeVM's scratch change while searching
matcher_clone :: proc(m: Matcher) -> (c: Matcher) {
	c = m
	c.fast_line = prefilter_clone(m.fast_line)
	c.suffix_pre = prefilter_clone(m.suffix_pre)
	c.inner_pre = prefilter_clone(m.inner_pre)
	if m.inner_nfa != nil { c.inner_dfa = dfa_clone(m.inner_dfa) }
	if m.finders != nil {
		c.finders = make([]nvol.Memmem_Finder, len(m.finders))
		copy(c.finders, m.finders)
	}
	if m.nfa != nil {
		c.cache = pike_cache_new(m.nfa)
		c.bt = backtrack_cache_new(m.nfa)
		c.slots = make([]int, m.nfa.slots)
		c.dfa = dfa_new(m.nfa)
		c.dfa_fwd = dfa_clone(m.dfa_fwd)
		c.dfa_rev = dfa_clone(m.dfa_rev)
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
	m.bt = backtrack_cache_new(m.nfa)
	m.bt_max = backtrack_max_haystack_len(m.nfa)
	m.slots = make([]int, m.nfa.slots)
	m.dfa = dfa_new(m.nfa)
	m.nfa_rev = new(Rx_NFA)
	m.nfa_rev^ = rx_compile_reverse(h)
	// regex-automata leaves the unanchored prefix out of an NFA anchored at the start
	m.dfa_fwd = dfa_new(m.nfa, .Leftmost_First, !look_set_contains(h.props.look_set_prefix, .Start))
	m.dfa_rev = dfa_new(m.nfa_rev, .All)
	m.dfa_ok = dfa_capacity_suffices(m.nfa) && dfa_capacity_suffices(m.nfa_rev)
	if !m.dfa_ok { return }
	anchored_start := look_set_contains(h.props.look_set_prefix, .Start)
	// ReverseAnchored::new: always anchored at the end (\z) and not at the start; the lazy
	// DFAs are always there
	if look_set_contains(h.props.look_set_suffix, .End) && !anchored_start {
		m.strategy = .Reverse_Anchored
		return
	}
	// the reverse suffix and inner searches assume unanchored searches, and would scan too
	// much for a regex anchored at the start; and a fast prefix prefilter is better
	if anchored_start || (pre != nil && prefilter_is_fast(pre)) { return }
	if try_reverse_suffix(&m, h) { return }
	try_reverse_inner(&m, h)
	return
}

// ReverseSuffix::new: the longest common suffix of the regex's suffixes (leftmost-first),
// when it is not empty, its own prefilter is fast, and regex 1.13.1's proofs hold
@(private="file")
try_reverse_suffix :: proc(m: ^Matcher, h: ^Hir) -> bool {
	e := extractor_new(.Suffix)
	suffixes := extractor_extract(&e, h)
	seq_optimize_for_suffix_by_preference(&suffixes)
	lcs, has := seq_longest_common_suffix(suffixes)
	if !has || len(lcs) == 0 { return false }
	needles := make([][]u8, 1)
	needles[0] = lcs
	sp, built := prefilter_new(needles)
	if !built || !prefilter_is_fast(sp) { return false }
	// regex 1.13.1's fix (meta_prefix.odin): only when no earlier match can end at a later
	// occurrence of the suffix
	if !reverse_suffix_has_no_earlier_match(h, lcs) { return false }
	m.strategy = .Reverse_Suffix
	m.suffix_pre = sp
	return true
}

// ReverseInner::new: inner literals with a fast prefilter (meta_reverse_inner.odin), when
// regex 1.13.1's proofs hold for the part of the regex before them, which is compiled in
// reverse without captures
@(private="file")
try_reverse_inner :: proc(m: ^Matcher, h: ^Hir) -> bool {
	ip := inner_prefilter(h) or_return
	if !reverse_inner_has_no_earlier_match(ip.prefix, ip.literals) { return false }
	inner := new(Rx_NFA)
	inner^ = rx_compile_reverse(ip.prefix)
	if !dfa_capacity_suffices(inner) { return false }
	m.inner_nfa = inner
	m.inner_dfa = dfa_new(m.inner_nfa, .All)
	m.inner_pre = ip.pre
	m.strategy = .Reverse_Inner
	return true
}

// hybrid::regex::Regex::try_search: the end of the leftmost-first match from the forward
// DFA, then its start from the reverse DFA run anchored at that end; Quit when either gives up
@(private="file")
find_dfa :: proc(m: ^Matcher, h: []u8, start, end: int) -> (s, e: int, r: Dfa_Result) {
	e, r = dfa_find_fwd(&m.dfa_fwd, h, start, end)
	if r != .Match { return }
	// an empty match at the start, or a regex anchored at the start: no reverse search
	if e == start || !m.dfa_fwd.unanchored { return start, e, .Match }
	at, rr := dfa_find_rev(&m.dfa_rev, h, start, e)
	if rr == .Quit { return 0, 0, .Quit }
	assert(rr == .Match, "reverse search must match if forward search does")
	return at, e, .Match
}

// The meta strategy's search (Strategy::search, unanchored) for a strategy other than Core:
// the match, or the Core search when the fast one gives up
@(private="file")
find_strategy :: proc(m: ^Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	switch m.strategy {
	case .Core:
	case .Reverse_Anchored:
		// the only end a match can have is the end of the input: the reverse DFA, anchored
		// there, finds the leftmost start
		at, r := dfa_find_rev(&m.dfa_rev, hay[:end], start, end)
		switch r {
		case .Match: return at, end, true
		case .No_Match: return
		case .Quit: return core_slots(m, hay, start, end)
		}
	case .Reverse_Inner:
		ms, me, r, quadratic := inner_full(m, hay[:end], start, end, false)
		if quadratic { return core_find(m, hay, start, end) }
		switch r {
		case .Match: return ms, me, true
		case .No_Match: return
		case .Quit: return core_slots(m, hay, start, end)
		}
	case .Reverse_Suffix:
		ms, r, quadratic := suffix_start(m, hay[:end], start, end)
		if quadratic { return core_find(m, hay, start, end) }
		switch r {
		case .No_Match: return
		case .Quit: return core_slots(m, hay, start, end)
		case .Match:
		}
		// the suffix found need not end the leftmost-first match (/[a-z]+ing/ on
		// "tingling"): the forward DFA, anchored at the start, finds its end
		me, fr := dfa_find_fwd(&m.dfa_fwd, hay[:end], ms, end, anchored = true)
		switch fr {
		case .Match: return ms, me, true
		case .Quit: return core_slots(m, hay, start, end)
		case .No_Match: panic("a suffix match and a reverse match imply a match")
		}
	}
	unreachable()
}

// ReverseInner::try_search_full: each occurrence of the inner literals, in order, with the
// reverse DFA of the prefix run anchored at its start for the leftmost start of the prefix,
// then the forward DFA, anchored at that start, for the end (the first end when earliest).
// The reverse scans stop at the previous occurrence's end, and an occurrence starting
// before the end of the last forward scan gives up (both quadratic)
@(private="file")
inner_full :: proc(m: ^Matcher, h: []u8, start, end: int, earliest: bool) -> (ms, me: int, r: Dfa_Result, quadratic: bool) {
	from := start
	min_match_start, min_pre_start := 0, 0
	for {
		lit := prefilter_find(m.inner_pre, h, from, end) or_return
		if lit.start < min_pre_start { return 0, 0, .No_Match, true }
		hs, rr, quad := dfa_find_rev_limited(&m.inner_dfa, h, start, lit.start, min_match_start)
		if quad { return 0, 0, .No_Match, true }
		if rr == .Quit { return 0, 0, .Quit, false }
		if rr == .Match {
			stop: int
			fe, fr := dfa_find_fwd(&m.dfa_fwd, h, hs, end, anchored = true, earliest = earliest, stop = &stop)
			switch fr {
			case .Match: return hs, fe, .Match, false
			case .Quit: return 0, 0, .Quit, false
			case .No_Match:
				min_pre_start = stop
				from = lit.start + 1
			}
		}
		if from >= end { return 0, 0, .No_Match, false }
		from = lit.start + 1
		min_match_start = lit.end
	}
}

// ReverseSuffix::try_search_half_start: each occurrence of the suffix, in order, with the
// reverse DFA run anchored at its end for the leftmost start of a match ending there; the
// reverse scans stop at the previous occurrence's end, or the search gives up (quadratic)
@(private="file")
suffix_start :: proc(m: ^Matcher, h: []u8, start, end: int) -> (at: int, r: Dfa_Result, quadratic: bool) {
	from := start
	min_start := 0
	for {
		lit := prefilter_find(m.suffix_pre, h, from, end) or_return
		at, r, quadratic = dfa_find_rev_limited(&m.dfa_rev, h, start, lit.end, min_start)
		if quadratic || r != .No_Match { return }
		if from >= end { return 0, .No_Match, false }
		from = lit.start + 1
		min_start = lit.end
	}
}

// Strategy::search_slots: with a strategy other than Core, its match narrows the span and
// the engines with slots run from its start (they find the same match there: none starts
// earlier)
@(private="file")
find_slots :: proc(m: ^Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	if m.strategy == .Core { return core_slots(m, hay, start, end) }
	ms, _ := find_strategy(m, hay, start, end) or_return
	return core_slots(m, hay, ms, end)
}

// the leftmost-first match and its capture groups in m.slots: the bounded backtracker when
// the span fits it, else the PikeVM, as the meta engine orders them for a search with slots
@(private="file")
core_slots :: proc(m: ^Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	if end - start <= m.bt_max {
		if !backtrack_search(m.nfa, &m.bt, hay[:end], start, end, m.slots) { return }
	} else if !pike_search(m.nfa, &m.cache, hay[:end], start, end, false, m.slots) {
		return
	}
	return m.slots[0], m.slots[1], true
}

// Strategy::search_half with an earliest input (grep-regex's shortest_match_at, and
// is_match): where a match ends in hay[start:]. A strategy other than Core finds a start and
// then the first end from there; when it gives up, the Core search
@(private="file")
earliest :: proc(m: ^Matcher, hay: []u8, start: int) -> (end: int, ok: bool) {
	end_ := len(hay)
	if !m.dfa_ok { return pike_end(m, hay, start) }
	switch m.strategy {
	case .Core:
	case .Reverse_Anchored:
		// a match can only end at the end of the input
		_, r := dfa_find_rev(&m.dfa_rev, hay, start, end_)
		switch r {
		case .Match: return end_, true
		case .No_Match: return
		case .Quit: return pike_end(m, hay, start)
		}
	case .Reverse_Inner:
		_, me, r, quadratic := inner_full(m, hay, start, end_, true)
		if quadratic { return core_earliest(m, hay, start) }
		switch r {
		case .Match: return me, true
		case .No_Match: return
		case .Quit: return pike_end(m, hay, start)
		}
	case .Reverse_Suffix:
		ms, r, quadratic := suffix_start(m, hay, start, end_)
		if quadratic { return core_earliest(m, hay, start) }
		switch r {
		case .No_Match: return
		case .Quit: return pike_end(m, hay, start)
		case .Match:
		}
		me, fr := dfa_find_fwd(&m.dfa_fwd, hay, ms, end_, anchored = true, earliest = true)
		switch fr {
		case .Match: return me, true
		case .Quit: return pike_end(m, hay, start)
		case .No_Match: panic("a suffix match and a reverse match imply a match")
		}
	}
	return core_earliest(m, hay, start)
}

// search_half_nofail: the PikeVM's end of the leftmost-first match
@(private="file")
pike_end :: proc(m: ^Matcher, hay: []u8, start: int) -> (end: int, ok: bool) {
	if !pike_search(m.nfa, &m.cache, hay, start, len(hay), false, m.slots) { return }
	return m.slots[1], true
}

// Core::search_half, earliest: the lazy DFA, or the PikeVM when the DFA gives up
@(private="file")
core_earliest :: proc(m: ^Matcher, hay: []u8, start: int) -> (end: int, ok: bool) {
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
	if m.kind == .Pike {
		_, _, ok := find_slots(m, hay, at, len(hay))
		return ok
	}
	s, e, ok := find(m, hay, at, len(hay))
	if ok { m.lit_slots = {s, e} }
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
		if m.strategy != .Core { return find_strategy(m, hay, start, end) }
		return core_find(m, hay, start, end)
	}
	return
}

// Core::search without capture groups: the lazy DFAs, and the engines with slots when they
// give up
@(private="file")
core_find :: proc(m: ^Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	if !m.dfa_ok { return core_slots(m, hay, start, end) }
	ds, de, r := find_dfa(m, hay[:end], start, end)
	switch r {
	case .Match: return ds, de, true
	case .No_Match: return
	case .Quit:
	}
	return core_slots(m, hay, start, end)
}
