// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:text/regex"
import nvol "nvol:odin"

// What a search looks for. Literals go to NVOL's kernels: one needle to memmem (memchr's
// Finder in ripgrep), several to Teddy (aho-corasick's packed searcher), with a memmem per
// needle when Teddy cannot take them (the cases aho-corasick also refuses).
Matcher_Kind :: enum { Empty, Literal, Literals, Regex }

Matcher :: struct {
	kind:    Matcher_Kind,
	needles: []string,
	finders: []nvol.Memmem_Finder,
	teddy:   nvol.Teddy,
	teddy_ok: bool,
	rx:      ^Regex_Matcher,
}

// a worker's own copy: the memmem finders and the regex capture change while searching
matcher_clone :: proc(m: Matcher) -> (c: Matcher) {
	c = m
	if m.finders != nil {
		c.finders = make([]nvol.Memmem_Finder, len(m.finders))
		copy(c.finders, m.finders)
	}
	if m.rx != nil {
		c.rx = new(Regex_Matcher)
		c.rx^ = m.rx^
		c.rx.capture = regex.preallocate_capture()
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

// grep-matcher's Matcher, as the searcher and printers call it. The interim engines never
// match across a line terminator, so a candidate line is always confirmed.
matcher_find_at :: proc(m: ^Matcher, hay: []u8, at: int) -> (r: Range, ok: bool) {
	s, e := find(m, hay, at, len(hay)) or_return
	return {s, e}, true
}

matcher_is_match :: proc(m: ^Matcher, line: []u8) -> bool {
	_, _, ok := find(m, line, 0, len(line))
	return ok
}

matcher_find_candidate_line :: proc(m: ^Matcher, buf: []u8) -> (at: int, confirmed: bool, ok: bool) {
	s, _ := find(m, buf, 0, len(buf)) or_return
	return s, true, true
}

// The leftmost match in hay[start:end): its bounds in hay. Among needles starting at the same
// byte, the first given (leftmost-first, as ripgrep).
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
	case .Regex:
		return find_regex(m.rx, hay, start, end)
	}
	return
}
