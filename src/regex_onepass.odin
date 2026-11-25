// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// regex-automata's one-pass DFA (0.4.7, dfa/onepass.rs), for one pattern: a DFA that also
// resolves capture groups, for regexes where at each position at most one NFA thread can
// continue. The meta engine runs it for anchored capture searches before the bounded
// backtracker (Core::search_slots_nofail): here, over the span the lazy DFAs found
// (slots_in_match), and for a regex anchored at the start.
//
// The build, as upstream: from the anchored start, each DFA state is an NFA state; its
// epsilon closure (in priority order) collects the looks that must hold and the explicit
// capture slots to set on the way to each byte transition. The regex is not one-pass when
// the closure reaches an NFA state twice, reaches two Match states, or two paths give one
// byte different transitions. A transition compiled after the closure reached Match has
// match_wins set: leftmost-first stops there instead of going on.

// Slots::LIMIT: the explicit slots one bit set holds (16 groups)
ONEPASS_SLOT_LIMIT :: 32

@(private="file")
Onepass_Trans :: struct {
	next:       i32,     // 0: dead
	match_wins: bool,
	slots:      u32,     // explicit slots (offset from 2) set to the position
	looks:      u32,     // Look bits that must hold at the position
}

@(private="file")
Onepass_State :: struct {
	is_match: bool,
	slots:    u32,       // the Match epsilons: slots set and looks needed at the end
	looks:    u32,
}

Onepass :: struct {
	table:  []Onepass_Trans,   // 256 per state
	states: []Onepass_State,
	start:  i32,
	explicit: int,             // explicit slots used (nfa.slots - 2, at most 32)
	scratch: []int,            // the cache's explicit slots (a worker's own copy)
}

// rg's onepass_size_limit (10 MiB) bounds the table
ONEPASS_SIZE_LIMIT :: 10 * (1 << 20)

// not ok when the regex is not one-pass, or the DFA would pass the size limit
onepass_build :: proc(n: ^Rx_NFA) -> (o: ^Onepass, ok: bool) {
	if n.reverse { return }
	explicit := n.slots - 2
	if explicit > ONEPASS_SLOT_LIMIT { return }
	// looks past the word boundaries (the half and start/end ones) are not supported
	for s in n.states {
		if s.kind == .Look && u32(s.look) > u32(Look.Word_Unicode_Negate) { return }
	}
	table: [dynamic]Onepass_Trans
	states: [dynamic]Onepass_State
	nfa_to_dfa := make([]i32, len(n.states))
	defer delete(nfa_to_dfa)
	uncompiled: [dynamic]i32
	defer delete(uncompiled)
	seen := make([]bool, len(n.states))
	defer delete(seen)
	Item :: struct { id: i32, slots, looks: u32 }
	stack: [dynamic]Item
	defer delete(stack)
	add_state :: proc(table: ^[dynamic]Onepass_Trans, states: ^[dynamic]Onepass_State) -> (i32, bool) {
		if (len(states) + 1) * (256 * size_of(Onepass_Trans) + size_of(Onepass_State)) > ONEPASS_SIZE_LIMIT { return 0, false }
		base := len(table)
		if base + 256 > cap(table) { reserve(table, max(base + 256, 2 * cap(table))) }
		resize(table, base + 256)
		append(states, Onepass_State{})
		return i32(len(states) - 1), true
	}
	fail :: proc(t: ^[dynamic]Onepass_Trans, s: ^[dynamic]Onepass_State) -> (^Onepass, bool) {
		delete(t^)
		delete(s^)
		return nil, false
	}
	_, k0 := add_state(&table, &states)   // the dead state
	if !k0 { return fail(&table, &states) }
	for &x in nfa_to_dfa { x = 0 }
	dfa_for :: proc(nfa_id: i32, nfa_to_dfa: []i32, uncompiled: ^[dynamic]i32, table: ^[dynamic]Onepass_Trans, states: ^[dynamic]Onepass_State) -> (i32, bool) {
		if d := nfa_to_dfa[nfa_id]; d != 0 { return d, true }
		d, ok := add_state(table, states)
		if !ok { return 0, false }
		nfa_to_dfa[nfa_id] = d
		append(uncompiled, nfa_id)
		return d, true
	}
	start, ks := dfa_for(n.start, nfa_to_dfa, &uncompiled, &table, &states)
	if !ks { return fail(&table, &states) }
	for len(uncompiled) > 0 {
		nfa_id := pop(&uncompiled)
		dfa_id := nfa_to_dfa[nfa_id]
		matched := false
		for &x in seen { x = false }
		clear(&stack)
		seen[nfa_id] = true
		append(&stack, Item{nfa_id, 0, 0})
		for len(stack) > 0 {
			it := pop(&stack)
			s := &n.states[it.id]
			push :: proc(stack: ^[dynamic]Item, seen: []bool, id: i32, slots, looks: u32) -> bool {
				if seen[id] { return false }       // two epsilon paths to one state
				seen[id] = true
				append(stack, Item{id, slots, looks})
				return true
			}
			switch s.kind {
			case .Range:
				next := dfa_for(s.next, nfa_to_dfa, &uncompiled, &table, &states) or_else -1
				if next < 0 { return fail(&table, &states) }
				if !compile_trans(table[:], dfa_id, s.lo, s.hi, Onepass_Trans{next, matched, it.slots, it.looks}) { return fail(&table, &states) }
			case .Sparse:
				for t in s.trans {
					next := dfa_for(t.next, nfa_to_dfa, &uncompiled, &table, &states) or_else -1
					if next < 0 { return fail(&table, &states) }
					if !compile_trans(table[:], dfa_id, t.lo, t.hi, Onepass_Trans{next, matched, it.slots, it.looks}) { return fail(&table, &states) }
				}
			case .Look:
				if !push(&stack, seen, s.next, it.slots, it.looks | u32(s.look)) { return fail(&table, &states) }
			case .Union:
				#reverse for a in s.alts {
					if !push(&stack, seen, a, it.slots, it.looks) { return fail(&table, &states) }
				}
			case .Capture:
				sl := it.slots
				if s.slot >= 2 { sl |= 1 << u32(s.slot - 2) }
				if !push(&stack, seen, s.next, sl, it.looks) { return fail(&table, &states) }
			case .Fail:
			case .Match:
				if matched { return fail(&table, &states) }   // two epsilon paths to Match
				matched = true
				states[dfa_id] = Onepass_State{is_match = true, slots = it.slots, looks = it.looks}
			}
		}
	}
	o = new(Onepass)
	o.table, o.states, o.start, o.explicit = table[:], states[:], start, explicit
	o.scratch = make([]int, max(explicit, 0))
	return o, true
}

// each byte of [lo, hi] gets t, unless it already has a different transition
@(private="file")
compile_trans :: proc(table: []Onepass_Trans, dfa_id: i32, lo, hi: u8, t: Onepass_Trans) -> bool {
	base := int(dfa_id) * 256
	for b in int(lo) ..= int(hi) {
		old := &table[base + b]
		if old.next == 0 {
			old^ = t
		} else if old^ != t {
			return false
		}
	}
	return true
}

// a worker's own copy: the explicit slots are scratch
onepass_clone :: proc(o: ^Onepass) -> ^Onepass {
	if o == nil { return nil }
	c := new(Onepass)
	c^ = o^
	c.scratch = make([]int, len(o.scratch))
	return c
}

@(private="file")
looks_hold :: #force_inline proc(looks: u32, h: []u8, at: int) -> bool {
	l := looks
	for l != 0 {
		bit := l & (~l + 1)
		if !look_matches(Look(bit), h, at) { return false }
		l &= l - 1
	}
	return true
}

// search_imp, anchored at start, leftmost-first: whether a match starts at start and ends
// by end, with group 0 and the explicit groups in slots (unset: -1). The looks see h beyond
// [start, end)
onepass_search :: proc(o: ^Onepass, h: []u8, start, end: int, slots: []int) -> bool {
	for &x in slots { x = -1 }
	for &x in o.scratch { x = -1 }
	if len(slots) > 0 { slots[0] = start }
	matched := false
	next := o.start
	for at := start; at < end; at += 1 {
		sid := next
		t := o.table[int(sid) * 256 + int(h[at])]
		next = t.next
		if o.states[sid].is_match {
			if find_match(o, h, at, sid, slots) {
				matched = true
				if t.match_wins { return true }
			}
		}
		if sid == 0 || (t.looks != 0 && !looks_hold(t.looks, h, at)) { return matched }
		apply_slots(t.slots, at, o.scratch)
	}
	if o.states[next].is_match { matched = find_match(o, h, end, next, slots) || matched }
	return matched
}

@(private="file")
find_match :: proc(o: ^Onepass, h: []u8, at: int, sid: i32, slots: []int) -> bool {
	st := o.states[sid]
	if st.looks != 0 && !looks_hold(st.looks, h, at) { return false }
	if len(slots) > 1 { slots[1] = at }
	if len(slots) > 2 {
		copy(slots[2:], o.scratch)
		apply_slots(st.slots, at, slots[2:])
	}
	return true
}

@(private="file")
apply_slots :: #force_inline proc(bits: u32, at: int, dst: []int) {
	b := bits
	for b != 0 {
		i := int(count_trailing_zeros_u32(b))
		if i < len(dst) { dst[i] = at }
		b &= b - 1
	}
}

@(private="file")
count_trailing_zeros_u32 :: #force_inline proc(x: u32) -> u32 {
	n: u32 = 0
	y := x
	for y & 1 == 0 { y >>= 1; n += 1 }
	return n
}
