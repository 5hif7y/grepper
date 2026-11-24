// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import nvol "nvol:odin"

// regex-automata 0.4.7's prefilters (util/prefilter): a literal search that finds where a
// match may start, so the regex engines skip what lies before it. Every kind runs on an NVOL
// kernel, picked in regex-automata's order (Choice::new): memchr, memchr2, memchr3, memmem,
// Teddy, then a byte set. regex-automata's last resort, an Aho-Corasick automaton, is not
// ported yet; a set Teddy refuses then gets no prefilter.

Prefilter_Kind :: enum { Memchr, Memchr2, Memchr3, Memmem, Teddy, Byte_Set }

Prefilter :: struct {
	kind:           Prefilter_Kind,
	bytes:          [3]u8,
	finder:         nvol.Memmem_Finder,
	needle_len:     int,
	teddy:          nvol.Teddy,
	set:            [256]bool,
	minimum_len:    int,
	max_needle_len: int,
}

// Choice::new; none when a needle is empty or no kind takes the set
prefilter_new :: proc(needles: [][]u8) -> (p: ^Prefilter, ok: bool) {
	if len(needles) == 0 { return }
	min_len, max_len := max(int), 0
	for n in needles {
		if len(n) == 0 { return }
		min_len = min(min_len, len(n))
		max_len = max(max_len, len(n))
	}
	pre: Prefilter
	pre.minimum_len, pre.max_needle_len = min_len, max_len
	all_one := max_len == 1
	switch {
	case len(needles) == 1 && all_one:
		pre.kind = .Memchr
		pre.bytes[0] = needles[0][0]
	case len(needles) == 2 && all_one:
		pre.kind = .Memchr2
		pre.bytes = {needles[0][0], needles[1][0], 0}
	case len(needles) == 3 && all_one:
		pre.kind = .Memchr3
		pre.bytes = {needles[0][0], needles[1][0], needles[2][0]}
	case len(needles) == 1:
		pre.kind = .Memmem
		pre.finder = nvol.memmem_finder(needles[0])
		pre.needle_len = len(needles[0])
	case:
		strs := make([]string, len(needles))
		for n, i in needles { strs[i] = string(n) }
		t, built := nvol.teddy_build(strs)
		if built {
			pre.kind = .Teddy
			pre.teddy = t
		} else if all_one {
			pre.kind = .Byte_Set
			for n in needles { pre.set[n[0]] = true }
		} else {
			return
		}
	}
	p = new(Prefilter)
	p^ = pre
	return p, true
}

// a worker's own copy: the memmem finder keeps state while it searches
prefilter_clone :: proc(p: ^Prefilter) -> ^Prefilter {
	if p == nil { return nil }
	c := new(Prefilter)
	c^ = p^
	return c
}

// PrefilterI::is_fast: whether it skips far enough to be worth running on its own; a byte
// set is not, and Teddy only with needles of three bytes or more
prefilter_is_fast :: proc(p: ^Prefilter) -> bool {
	#partial switch p.kind {
	case .Byte_Set: return false
	case .Teddy: return p.minimum_len >= 3
	}
	return true
}

// the first candidate in h[start:end): where it starts and ends
prefilter_find :: proc(p: ^Prefilter, h: []u8, start, end: int) -> (r: Range, ok: bool) {
	hay := h[start:end]
	switch p.kind {
	case .Memchr:
		i := nvol.memchr(p.bytes[0], hay) or_return
		return {start + i, start + i + 1}, true
	case .Memchr2:
		i := nvol.memchr2(p.bytes[0], p.bytes[1], hay) or_return
		return {start + i, start + i + 1}, true
	case .Memchr3:
		i := nvol.memchr3(p.bytes[0], p.bytes[1], p.bytes[2], hay) or_return
		return {start + i, start + i + 1}, true
	case .Memmem:
		i := nvol.memmem_find(&p.finder, hay) or_return
		return {start + i, start + i + p.needle_len}, true
	case .Teddy:
		m := nvol.teddy_find_in(&p.teddy, h, start, end) or_return
		return {m.start, m.end}, true
	case .Byte_Set:
		for b, i in hay {
			if p.set[b] { return {start + i, start + i + 1}, true }
		}
	}
	return
}
