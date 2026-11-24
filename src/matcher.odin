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
	needles:  []string,
	finders:  []nvol.Memmem_Finder,
	teddy:    nvol.Teddy,
	teddy_ok: bool,
	nfa:      ^Rx_NFA,
	cache:    Pike_Cache,
	slots:    []int,
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
	}
	return
}

matcher_literals :: proc(needles: []string) -> (m: Matcher) {
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
	m.nfa = new(Rx_NFA)
	m.nfa^ = rx_compile(h)
	rx_finish(m.nfa)
	m.cache = pike_cache_new(m.nfa)
	m.slots = make([]int, m.nfa.slots)
	return
}

// grep-matcher's Matcher, as the searcher and printers call it. Lines never contain a match
// across a line terminator (strip_from_match removed it from the regex), so a candidate line
// is always confirmed.
matcher_find_at :: proc(m: ^Matcher, hay: []u8, at: int) -> (r: Range, ok: bool) {
	s, e := find(m, hay, at, len(hay)) or_return
	return {s, e}, true
}

matcher_is_match :: proc(m: ^Matcher, line: []u8) -> bool {
	_, _, ok := find(m, line, 0, len(line))
	return ok
}

// ripgrep's shortest_match: the end of a match
matcher_find_candidate_line :: proc(m: ^Matcher, buf: []u8) -> (at: int, confirmed: bool, ok: bool) {
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
