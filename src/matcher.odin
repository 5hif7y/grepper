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
}

// a worker's own copy: the memmem finders and the PikeVM's scratch change while searching
matcher_clone :: proc(m: Matcher) -> (c: Matcher) {
	c = m
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

matcher_pike :: proc(h: ^Hir) -> (m: Matcher) {
	m.kind = .Pike
	m.line_term = !look_set_contains_anchor_haystack(h.props.look_set)
	m.nfa = new(Rx_NFA)
	m.nfa^ = rx_compile(h)
	rx_finish(m.nfa)
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
	if m.kind == .Pike {
		e := earliest(m, buf, 0) or_return
		return e, true, true
	}
	_, e := find(m, buf, 0, len(buf)) or_return
	return e, true, true
}

// the capture group i of the last Pike search (-1 when it did not take part)
matcher_group :: proc(m: ^Matcher, i: int) -> (r: Range, ok: bool) {
	if m.kind != .Pike {
		if i != 0 { return }
		return {m.slots[0], m.slots[1]}, m.slots != nil
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
