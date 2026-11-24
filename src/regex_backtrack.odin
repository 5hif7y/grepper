// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// regex-automata 0.4.7's BoundedBacktracker (nfa/thompson/backtrack.rs): a depth-first walk
// of the NFA in priority order, so the first match it reaches is the leftmost-first one, with
// a visited set of (state, position) pairs that makes it linear. The set has a fixed size
// (regex-automata's default, 256 KiB of bits), so it only takes haystacks up to
// backtrack_max_haystack_len; the meta engine prefers it to the PikeVM there, and so does
// grepper for the matches of a line.

BACKTRACK_VISITED_CAPACITY :: 256 * 1024   // bytes

@(private="file")
Bt_Frame :: struct {
	sid:          i32,
	at:           int,
	restore_slot: i32,     // >= 0: a RestoreCapture frame
	restore_val:  int,
}

Backtrack_Cache :: struct {
	pre:     ^Prefilter,
	stack:   [dynamic]Bt_Frame,
	visited: [dynamic]u64,
	stride:  int,
}

backtrack_cache_new :: proc(n: ^Rx_NFA) -> (c: Backtrack_Cache) {
	c.pre = prefilter_clone(n.pre)
	return
}

// BoundedBacktracker::max_haystack_len
backtrack_max_haystack_len :: proc(n: ^Rx_NFA) -> int {
	capacity := 8 * BACKTRACK_VISITED_CAPACITY
	blocks := (capacity + 63) / 64
	real_capacity := blocks * 64
	return max(real_capacity / len(n.states) - 1, 0)
}

// the leftmost-first match in h[start:end), its capture groups in slots (-1: none); h ends at
// end, as the PikeVM's haystack does
backtrack_search :: proc(n: ^Rx_NFA, c: ^Backtrack_Cache, h: []u8, start, end: int, slots: []int) -> bool {
	for &x in slots { x = -1 }
	clear(&c.stack)
	c.stride = end - start + 1
	bits := len(n.states) * c.stride
	blocks := (bits + 63) / 64
	resize(&c.visited, blocks)
	for &b in c.visited { b = 0 }
	at := start
	for at <= end {
		if c.pre != nil {
			r, ok := prefilter_find(c.pre, h, at, end)
			if !ok { break }
			at = r.start
		}
		if backtrack(n, c, h, start, end, at, slots) { return true }
		at += 1
	}
	return false
}

@(private="file")
backtrack :: proc(n: ^Rx_NFA, c: ^Backtrack_Cache, h: []u8, start, end, at: int, slots: []int) -> bool {
	append(&c.stack, Bt_Frame{sid = n.start, at = at, restore_slot = -1})
	for len(c.stack) > 0 {
		f := pop(&c.stack)
		if f.restore_slot >= 0 {
			slots[f.restore_slot] = f.restore_val
			continue
		}
		if step(n, c, h, start, end, f.sid, f.at, slots) { return true }
	}
	return false
}

@(private="file")
step :: proc(n: ^Rx_NFA, c: ^Backtrack_Cache, h: []u8, start, end: int, sid_in: i32, at_in: int, slots: []int) -> bool {
	sid, at := sid_in, at_in
	for {
		// Visited::insert
		k := int(sid) * c.stride + (at - start)
		bit := u64(1) << u64(k & 63)
		if c.visited[k >> 6] & bit != 0 { return false }
		c.visited[k >> 6] |= bit
		s := &n.states[sid]
		switch s.kind {
		case .Range:
			if at >= end { return false }
			b := h[at]
			if b < s.lo || b > s.hi { return false }
			sid = s.next
			at += 1
		case .Sparse:
			if at >= end { return false }
			b := h[at]
			next: i32 = -1
			for t in s.trans {
				if t.lo <= b && b <= t.hi { next = t.next; break }
			}
			if next < 0 { return false }
			sid = next
			at += 1
		case .Look:
			if !look_matches(s.look, h, at) { return false }
			sid = s.next
		case .Union:
			if len(s.alts) == 0 { return false }
			#reverse for a in s.alts[1:] { append(&c.stack, Bt_Frame{sid = a, at = at, restore_slot = -1}) }
			sid = s.alts[0]
		case .Capture:
			if int(s.slot) < len(slots) {
				append(&c.stack, Bt_Frame{restore_slot = s.slot, restore_val = slots[s.slot]})
				slots[s.slot] = at
			}
			sid = s.next
		case .Fail:
			return false
		case .Match:
			return true
		}
	}
}
