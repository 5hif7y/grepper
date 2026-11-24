// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"

// regex-automata 0.4.7's Thompson NFA (src/nfa/thompson/compiler.rs, with regex-syntax's
// UTF-8 sequences, src/utf8.rs) and its PikeVM (src/nfa/thompson/pikevm.rs): a leftmost-first
// search over bytes with capture groups and look-around assertions (src/util/look.rs). The
// NFA's shape differs from regex-automata's where only size is at stake (no suffix sharing for
// Unicode classes); the order of alternatives, which decides leftmost-first matches, is the
// same.

// ---------------------------------------------------------------------------------------------
// UTF-8 sequences

Utf8_Range :: struct { lo, hi: u8 }

Utf8_Sequence :: struct {
	n:      int,
	ranges: [4]Utf8_Range,
}

// every scalar value in [start, end] as sequences of byte ranges (Utf8Sequences)
utf8_sequences :: proc(start, end: u32, out: ^[dynamic]Utf8_Sequence) {
	Scalar_Range :: struct { start, end: u32 }
	stack: [dynamic]Scalar_Range
	defer delete(stack)
	append(&stack, Scalar_Range{start, end})
	max_scalar := [5]u32{0, 0x7F, 0x7FF, 0xFFFF, 0x10FFFF}
	top: for len(stack) > 0 {
		r := pop(&stack)
		inner: for {
			if r.start < 0xE000 && r.end > 0xD7FF {
				append(&stack, Scalar_Range{0xE000, r.end})
				r.end = 0xD7FF
				continue inner
			}
			if r.start > r.end { continue top }
			for i in 1 ..< 4 {
				mx := max_scalar[i]
				if r.start <= mx && mx < r.end {
					append(&stack, Scalar_Range{mx + 1, r.end})
					r.end = mx
					continue inner
				}
			}
			if r.end <= 0x7F {
				append(out, Utf8_Sequence{n = 1, ranges = {0 = {u8(r.start), u8(r.end)}}})
				continue top
			}
			for i in 1 ..< 4 {
				m := u32(1) << u32(6 * i) - 1
				if (r.start & ~m) != (r.end & ~m) {
					if (r.start & m) != 0 {
						append(&stack, Scalar_Range{(r.start | m) + 1, r.end})
						r.end = r.start | m
						continue inner
					}
					if (r.end & m) != m {
						append(&stack, Scalar_Range{r.end & ~m, r.end})
						r.end = (r.end & ~m) - 1
						continue inner
					}
				}
			}
			sb, n := encode_scalar(r.start)
			eb, _ := encode_scalar(r.end)
			seq := Utf8_Sequence{n = n}
			for k in 0 ..< n { seq.ranges[k] = {sb[k], eb[k]} }
			append(out, seq)
			continue top
		}
	}
}

encode_scalar :: proc(c: u32) -> (b: [4]u8, n: int) {
	switch {
	case c < 0x80:
		b[0] = u8(c); n = 1
	case c < 0x800:
		b[0] = u8(0xC0 | c >> 6); b[1] = u8(0x80 | c & 0x3F); n = 2
	case c < 0x10000:
		b[0] = u8(0xE0 | c >> 12); b[1] = u8(0x80 | (c >> 6) & 0x3F); b[2] = u8(0x80 | c & 0x3F); n = 3
	case:
		b[0] = u8(0xF0 | c >> 18); b[1] = u8(0x80 | (c >> 12) & 0x3F); b[2] = u8(0x80 | (c >> 6) & 0x3F); b[3] = u8(0x80 | c & 0x3F); n = 4
	}
	return
}

// ---------------------------------------------------------------------------------------------
// The NFA

Rx_State_Kind :: enum u8 { Range, Sparse, Look, Union, Capture, Fail, Match }

Rx_Trans :: struct { lo, hi: u8, next: i32 }

Rx_State :: struct {
	kind:   Rx_State_Kind,
	lo, hi: u8,                  // Range
	next:   i32,                 // Range, Look, Capture
	trans:  [dynamic]Rx_Trans,   // Sparse
	look:   Look,
	alts:   [dynamic]i32,        // Union, in priority order
	slot:   i32,                 // Capture
}

Rx_NFA :: struct {
	states:      [dynamic]Rx_State,
	start:       i32,
	slots:       int,              // 2 per capture group, group 0 included
	group_names: [dynamic]Maybe(string),
}

Rx_Ref :: struct { start, end: i32 }

@(private="file")
add_state :: proc(n: ^Rx_NFA, s: Rx_State) -> i32 {
	append(&n.states, s)
	return i32(len(n.states) - 1)
}

@(private="file") add_empty :: proc(n: ^Rx_NFA) -> i32 { return add_state(n, {kind = .Union}) }

// patch from -> to: a Union gains an alternative, the others get their next
@(private="file")
patch :: proc(n: ^Rx_NFA, from, to: i32) {
	s := &n.states[from]
	#partial switch s.kind {
	case .Union: append(&s.alts, to)
	case .Range, .Look, .Capture: s.next = to
	case .Sparse:
		for &t in s.trans { t.next = to }
	}
}

rx_compile :: proc(h: ^Hir) -> (n: Rx_NFA) {
	append(&n.group_names, nil)
	nfa_group_names(h, &n.group_names)
	n.slots = 2 * len(n.group_names)
	ref := c_cap(&n, 0, h)
	m := add_state(&n, {kind = .Match})
	patch(&n, ref.end, m)
	n.start = ref.start
	return
}

@(private="file")
nfa_group_names :: proc(h: ^Hir, names: ^[dynamic]Maybe(string)) {
	#partial switch h.kind {
	case .Capture:
		for len(names) <= int(h.index) { append(names, nil) }
		names[h.index] = h.name
		nfa_group_names(h.sub, names)
	case .Repetition: nfa_group_names(h.sub, names)
	case .Concat, .Alternation:
		for s in h.subs { nfa_group_names(s, names) }
	}
}

@(private="file")
c :: proc(n: ^Rx_NFA, h: ^Hir) -> Rx_Ref {
	switch h.kind {
	case .Empty:
		e := add_empty(n)
		return {e, e}
	case .Literal:
		first := Rx_Ref{-1, -1}
		for b in h.lit {
			id := add_state(n, {kind = .Range, lo = b, hi = b})
			if first.start < 0 { first.start = id } else { patch(n, first.end, id) }
			first.end = id
		}
		return first
	case .Class:
		return c_class(n, h.class)
	case .Look:
		id := add_state(n, {kind = .Look, look = h.look})
		return {id, id}
	case .Repetition:
		return c_repetition(n, h)
	case .Capture:
		return c_cap(n, h.index, h.sub)
	case .Concat:
		r := c(n, h.subs[0])
		for s in h.subs[1:] {
			x := c(n, s)
			patch(n, r.end, x.start)
			r.end = x.end
		}
		return r
	case .Alternation:
		u := add_state(n, {kind = .Union})
		e := add_empty(n)
		for s in h.subs {
			x := c(n, s)
			patch(n, u, x.start)
			patch(n, x.end, e)
		}
		return {u, e}
	}
	return {}
}

@(private="file")
c_cap :: proc(n: ^Rx_NFA, index: u32, sub: ^Hir) -> Rx_Ref {
	s := add_state(n, {kind = .Capture, slot = i32(2 * index)})
	inner := c(n, sub)
	e := add_state(n, {kind = .Capture, slot = i32(2 * index + 1)})
	patch(n, s, inner.start)
	patch(n, inner.end, e)
	return {s, e}
}

@(private="file")
c_class :: proc(n: ^Rx_NFA, cls: Hir_Class) -> Rx_Ref {
	end := add_empty(n)
	if len(cls.ranges) == 0 {
		f := add_state(n, {kind = .Fail})
		return {f, f}
	}
	if !cls.unicode || class_is_ascii(cls) {
		s := Rx_State{kind = .Sparse}
		for r in cls.ranges { append(&s.trans, Rx_Trans{u8(r.lo), u8(r.hi), end}) }
		return {add_state(n, s), end}
	}
	// a Unicode class: an alternation of its UTF-8 sequences (disjoint, so their order
	// does not matter)
	seqs: [dynamic]Utf8_Sequence
	defer delete(seqs)
	for r in cls.ranges { utf8_sequences(r.lo, r.hi, &seqs) }
	u := add_state(n, {kind = .Union})
	for seq in seqs {
		prev: i32 = -1
		first: i32 = -1
		for k in 0 ..< seq.n {
			id := add_state(n, {kind = .Range, lo = seq.ranges[k].lo, hi = seq.ranges[k].hi})
			if first < 0 { first = id } else { patch(n, prev, id) }
			prev = id
		}
		patch(n, prev, end)
		patch(n, u, first)
	}
	return {u, end}
}

// greedy unions try the expression first; lazy ones (union_reverse) the exit first
@(private="file")
add_union_for :: proc(n: ^Rx_NFA, greedy: bool) -> i32 {
	return add_state(n, {kind = .Union, slot = 0 if greedy else 1})
}

// a union's alternatives in priority order: a lazy union's are reversed once all are in
@(private="file")
finish_union :: proc(n: ^Rx_NFA, u: i32) {
	s := &n.states[u]
	if s.slot == 1 {
		slice.reverse(s.alts[:])
		s.slot = 0
	}
}

@(private="file")
c_repetition :: proc(n: ^Rx_NFA, h: ^Hir) -> Rx_Ref {
	mx, bounded := h.max.?
	switch {
	case h.min == 0 && bounded && mx == 1:
		u := add_union_for(n, h.greedy)
		x := c(n, h.sub)
		e := add_empty(n)
		patch(n, u, x.start)
		patch(n, u, e)
		finish_union(n, u)
		patch(n, x.end, e)
		return {u, e}
	case !bounded:
		return c_at_least(n, h.sub, h.greedy, h.min)
	case h.min == mx:
		return c_exactly(n, h.sub, h.min)
	}
	prefix := c_exactly(n, h.sub, h.min)
	e := add_empty(n)
	prev := prefix.end
	for _ in h.min ..< mx {
		u := add_union_for(n, h.greedy)
		x := c(n, h.sub)
		patch(n, prev, u)
		patch(n, u, x.start)
		patch(n, u, e)
		finish_union(n, u)
		prev = x.end
	}
	patch(n, prev, e)
	return {prefix.start, e}
}

@(private="file")
c_exactly :: proc(n: ^Rx_NFA, sub: ^Hir, count: u32) -> Rx_Ref {
	if count == 0 {
		e := add_empty(n)
		return {e, e}
	}
	r := c(n, sub)
	for _ in 1 ..< count {
		x := c(n, sub)
		patch(n, r.end, x.start)
		r.end = x.end
	}
	return r
}

@(private="file")
c_at_least :: proc(n: ^Rx_NFA, sub: ^Hir, greedy: bool, count: u32) -> Rx_Ref {
	if count == 0 {
		if ml, ok := sub.props.minimum_len.?; ok && ml > 0 {
			u := add_union_for(n, greedy)
			x := c(n, sub)
			patch(n, u, x.start)
			patch(n, x.end, u)
			// the exit is patched later: a lazy union must prefer it, so it is reversed
			// when the exit arrives (see patch_exit below)
			return {u, u}
		}
		x := c(n, sub)
		plus := add_union_for(n, greedy)
		patch(n, x.end, plus)
		patch(n, plus, x.start)
		question := add_union_for(n, greedy)
		e := add_empty(n)
		patch(n, question, x.start)
		patch(n, question, e)
		finish_union(n, question)
		patch(n, plus, e)
		finish_union(n, plus)
		return {question, e}
	}
	if count == 1 {
		x := c(n, sub)
		u := add_union_for(n, greedy)
		patch(n, x.end, u)
		patch(n, u, x.start)
		return {x.start, u}
	}
	prefix := c_exactly(n, sub, count - 1)
	last := c(n, sub)
	u := add_union_for(n, greedy)
	patch(n, prefix.end, last.start)
	patch(n, last.end, u)
	patch(n, u, last.start)
	return {prefix.start, u}
}

// Unions left open by c_at_least get their exit through patch; a lazy one's alternatives
// are put in priority order when the NFA is finished
rx_finish :: proc(n: ^Rx_NFA) {
	for &s, i in n.states {
		if s.kind == .Union && s.slot == 1 { finish_union(n, i32(i)) }
	}
}

// ---------------------------------------------------------------------------------------------
// Look-around (util/look.rs, line terminator '\n')

is_word_byte :: #force_inline proc(b: u8) -> bool {
	return ('a' <= b && b <= 'z') || ('A' <= b && b <= 'Z') || ('0' <= b && b <= '9') || b == '_'
}

// regex-automata's utf8::decode: the scalar at the start of bytes, or an error
@(private="file")
decode_fwd :: proc(b: []u8) -> (c: rune, ok: bool, empty: bool) {
	if len(b) == 0 { return 0, false, true }
	b0 := b[0]
	n: int
	switch {
	case b0 <= 0x7F: return rune(b0), true, false
	case b0 & 0xC0 == 0x80: return 0, false, false
	case b0 <= 0xDF: n = 2
	case b0 <= 0xEF: n = 3
	case b0 <= 0xF7: n = 4
	case: return 0, false, false
	}
	if n > len(b) || !utf8_valid(b[:n]) { return 0, false, false }
	r: u32
	switch n {
	case 2: r = u32(b0 & 0x1F) << 6 | u32(b[1] & 0x3F)
	case 3: r = u32(b0 & 0x0F) << 12 | u32(b[1] & 0x3F) << 6 | u32(b[2] & 0x3F)
	case 4: r = u32(b0 & 0x07) << 18 | u32(b[1] & 0x3F) << 12 | u32(b[2] & 0x3F) << 6 | u32(b[3] & 0x3F)
	}
	return rune(r), true, false
}

// utf8::decode_last
@(private="file")
decode_rev :: proc(b: []u8) -> (c: rune, ok: bool, empty: bool) {
	if len(b) == 0 { return 0, false, true }
	start := len(b) - 1
	limit := max(len(b) - 4, 0)
	is_leading_or_invalid :: proc(x: u8) -> bool { return x & 0xC0 != 0x80 }
	for start > limit && !is_leading_or_invalid(b[start]) { start -= 1 }
	c, ok, _ = decode_fwd(b[start:])
	return c, ok, false
}

is_word_char_unicode :: proc(c: rune) -> bool {
	if c < 0x80 { return is_word_byte(u8(c)) }
	rs := UT_PERL_WORD_RANGES[:]
	lo, hi := 0, len(rs)
	for lo < hi {
		mid := (lo + hi) / 2
		if rs[mid][1] < c { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(rs) && rs[lo][0] <= c
}

@(private="file")
word_fwd :: proc(h: []u8, at: int) -> bool {
	c, ok, _ := decode_fwd(h[at:])
	return ok && is_word_char_unicode(c)
}

@(private="file")
word_rev :: proc(h: []u8, at: int) -> bool {
	c, ok, _ := decode_rev(h[:at])
	return ok && is_word_char_unicode(c)
}

look_matches :: proc(l: Look, h: []u8, at: int) -> bool {
	n := len(h)
	switch l {
	case .Start: return at == 0
	case .End: return at == n
	case .Start_LF: return at == 0 || h[at - 1] == '\n'
	case .End_LF: return at == n || h[at] == '\n'
	case .Start_CRLF: return at == 0 || h[at - 1] == '\n' || (h[at - 1] == '\r' && (at >= n || h[at] != '\n'))
	case .End_CRLF: return at == n || h[at] == '\r' || (h[at] == '\n' && (at == 0 || h[at - 1] != '\r'))
	case .Word_Ascii:
		return (at > 0 && is_word_byte(h[at - 1])) != (at < n && is_word_byte(h[at]))
	case .Word_Ascii_Negate:
		return (at > 0 && is_word_byte(h[at - 1])) == (at < n && is_word_byte(h[at]))
	case .Word_Unicode:
		return word_rev(h, at) != word_fwd(h, at)
	case .Word_Unicode_Negate:
		before, after := false, false
		if at > 0 {
			_, ok, _ := decode_rev(h[:at])
			if !ok { return false }
			before = word_rev(h, at)
		}
		if at < n {
			_, ok, _ := decode_fwd(h[at:])
			if !ok { return false }
			after = word_fwd(h, at)
		}
		return before == after
	case .Word_Start_Ascii:
		return !(at > 0 && is_word_byte(h[at - 1])) && (at < n && is_word_byte(h[at]))
	case .Word_End_Ascii:
		return (at > 0 && is_word_byte(h[at - 1])) && !(at < n && is_word_byte(h[at]))
	case .Word_Start_Unicode: return !word_rev(h, at) && word_fwd(h, at)
	case .Word_End_Unicode: return word_rev(h, at) && !word_fwd(h, at)
	case .Word_Start_Half_Ascii: return !(at > 0 && is_word_byte(h[at - 1]))
	case .Word_End_Half_Ascii: return !(at < n && is_word_byte(h[at]))
	case .Word_Start_Half_Unicode:
		before := false
		if at > 0 {
			_, ok, _ := decode_rev(h[:at])
			if !ok { return false }
			before = word_rev(h, at)
		}
		return !before
	case .Word_End_Half_Unicode:
		after := false
		if at < n {
			_, ok, _ := decode_fwd(h[at:])
			if !ok { return false }
			after = word_fwd(h, at)
		}
		return !after
	}
	return false
}

// ---------------------------------------------------------------------------------------------
// The PikeVM: leftmost-first, the threads in priority order, each with its capture slots

Pike_Cache :: struct {
	clist, nlist: [dynamic]i32,
	cslots, nslots: [dynamic]int,      // per thread in the list: n.slots values
	mark:   []u32,
	gen:    u32,
	stack:  [dynamic]Pike_Frame,
	scratch: []int,
}

Pike_Frame :: struct {
	sid:          i32,
	restore_slot: i32,     // >= 0: put restore_val back into this slot
	restore_val:  int,
}

pike_cache_new :: proc(n: ^Rx_NFA) -> (c: Pike_Cache) {
	c.mark = make([]u32, len(n.states))
	c.scratch = make([]int, n.slots)
	return
}

// follow epsilon transitions from sid at position `at`, adding the threads reached to list
// in priority order (a depth-first walk with the capture slots set and restored on the way)
@(private="file")
epsilon_closure :: proc(n: ^Rx_NFA, c: ^Pike_Cache, list: ^[dynamic]i32, lslots: ^[dynamic]int, sid: i32, slots: []int, h: []u8, at: int) {
	append(&c.stack, Pike_Frame{sid = sid, restore_slot = -1})
	for len(c.stack) > 0 {
		f := pop(&c.stack)
		if f.restore_slot >= 0 {
			slots[f.restore_slot] = f.restore_val
			continue
		}
		id := f.sid
		for {
			if c.mark[id] == c.gen { break }
			c.mark[id] = c.gen
			s := &n.states[id]
			#partial switch s.kind {
			case .Union:
				if len(s.alts) == 0 { break }
				#reverse for alt in s.alts[1:] { append(&c.stack, Pike_Frame{sid = alt, restore_slot = -1}) }
				id = s.alts[0]
				continue
			case .Look:
				if !look_matches(s.look, h, at) { break }
				id = s.next
				continue
			case .Capture:
				if int(s.slot) < len(slots) {
					append(&c.stack, Pike_Frame{restore_slot = s.slot, restore_val = slots[s.slot]})
					slots[s.slot] = at
				}
				id = s.next
				continue
			case .Fail:
				break
			case:
				append(list, id)
				append(lslots, ..slots)
			}
			break
		}
	}
}

// the leftmost-first match in h[start:end) (look-around sees all of h); slots get the
// capture positions (slots[0], slots[1] the match)
pike_search :: proc(n: ^Rx_NFA, c: ^Pike_Cache, h: []u8, start, end: int, anchored: bool, slots: []int) -> bool {
	ns := n.slots
	clear(&c.clist); clear(&c.cslots)
	matched := false
	for &x in slots { x = -1 }
	for at := start; at <= end; at += 1 {
		// a new thread at the lowest priority, until a match is found
		if !matched && (!anchored || at == start) {
			c.gen += 1
			if c.gen == 0 { slice.fill(c.mark, 0); c.gen = 1 }
			// threads already in clist keep their marks from this generation
			for sid in c.clist { c.mark[sid] = c.gen }
			for &x in c.scratch { x = -1 }
			epsilon_closure(n, c, &c.clist, &c.cslots, n.start, c.scratch[:ns], h, at)
		}
		if len(c.clist) == 0 {
			if matched || anchored { break }
			continue
		}
		c.gen += 1
		if c.gen == 0 { slice.fill(c.mark, 0); c.gen = 1 }
		clear(&c.nlist); clear(&c.nslots)
		for sid, i in c.clist {
			s := &n.states[sid]
			tslots := c.cslots[i * ns:(i + 1) * ns]
			next: i32 = -1
			#partial switch s.kind {
			case .Match:
				matched = true
				copy(slots, tslots)
				break      // lower priority threads are cut
			case .Range:
				if at < end && s.lo <= h[at] && h[at] <= s.hi { next = s.next }
			case .Sparse:
				if at < end {
					b := h[at]
					for t in s.trans {
						if t.lo <= b && b <= t.hi { next = t.next; break }
					}
				}
			}
			if s.kind == .Match { break }
			if next >= 0 {
				copy(c.scratch[:ns], tslots)
				epsilon_closure(n, c, &c.nlist, &c.nslots, next, c.scratch[:ns], h, at + 1)
			}
		}
		c.clist, c.nlist = c.nlist, c.clist
		c.cslots, c.nslots = c.nslots, c.cslots
		if len(c.clist) == 0 && matched { break }
	}
	return matched
}
