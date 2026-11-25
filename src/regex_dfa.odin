// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"
import nvol "nvol:odin"

// A lazy DFA over the Thompson NFA, in the manner of regex-automata's hybrid DFA: states are
// built on demand and their transitions cached. It answers the question the line searcher
// asks most, whether (and where first) a match ends, and leaves match positions to the
// PikeVM. Look-around is decided from the byte before and the byte after each position, as
// regex-automata's determinizer does; a Unicode word boundary next to a non-ASCII byte cannot
// be, so the DFA then gives up ("quits") and the PikeVM answers, as regex-automata falls back.
//
// A state is the NFA states reached by the last byte (before their epsilon closure) and the
// class of that byte; the unanchored start is in every state, as a `(?s-u:.)*?` prefix.

Dfa_Ctx :: enum u8 { Start, LF, CR, Word, Other, Non_Ascii }

// The transitions of every state are one flat table, 257 entries a state (each byte, and
// the end at 256), and a transition holds its target premultiplied: the index of the target's
// first entry. Everything the search must stop for is negative, so the inner loop does one
// comparison a byte, as regex-automata's lazy DFA does with its tagged state ids.
DFA_STRIDE :: 257

DFA_UNKNOWN :: -1
DFA_MATCH   :: -2      // a match ends where the byte would be read
DFA_QUIT    :: -3
DFA_NO_EOI  :: -4      // at the end: no match
DFA_DEAD    :: -5      // no thread left (leftmost-first and All modes)
// A transition into a state the search must act on when it enters it: DFA_TAG - (target * 4
// + kind), kind 0 for a start state when there is a prefilter (skip with the prefilter),
// kind 1 for an accelerated state (skip to its next escape byte), kind 2 for a match state
// (leftmost-first and All modes: a match ends, or starts, where the byte was read).
DFA_TAG :: -16

// What a DFA answers. Earliest: where the first match ends (the line search). Leftmost_First:
// where the leftmost-first match ends, as the meta engine's forward lazy DFA finds it.
// All: run anchored over the reverse NFA, where that match starts (the reverse lazy DFA,
// built with MatchKind::All).
Dfa_Mode :: enum u8 { Earliest, Leftmost_First, All }

// Acceleration, which regex-automata gives its dense DFAs and not its lazy one: a state that
// goes back to itself on every byte but one to three "escape" bytes skips ahead to the next
// of them with NVOL's memchr, memchr2 or memchr3. A state is checked the first time one of
// its self-loops is computed, which computes its whole row; at most DFA_ACCEL_CHECKS states
// per cache, and never when the row could fill the cache.
DFA_ACCEL_CHECKS :: 64

Dfa_State :: struct {
	is_start: bool,          // no seeds: only the unanchored start's closure is alive
	ctx:   Dfa_Ctx,
	seeds: []i32,
	// leftmost-first and All modes: whether the unanchored prefix is still alive (it is
	// dropped with every thread of lower priority than a match), and whether the set this
	// state came from reached a match (regex-automata's matches delayed by one byte)
	unanchored: bool,
	is_match:   bool,
	accel_checked: bool,
	accel_n:       int,      // escape bytes, 1 to 3 (or 0 with accel set: none at all)
	accel:         bool,
	escapes:       [3]u8,
}

Lazy_Dfa :: struct {
	mode:         Dfa_Mode,
	rev:          bool,           // over a reverse NFA: the previous byte is the next one up
	unanchored:   bool,           // leftmost-first: the start states hold the unanchored prefix
	nfa:          ^Rx_NFA,
	pre:          ^Prefilter,     // the NFA's prefilter, this DFA's own copy
	states:       [dynamic]Dfa_State,
	trans:        [dynamic]i32,   // DFA_STRIDE entries per state, encoded as above
	index:        map[string]i32,
	has_uni_word: bool,
	// the context each byte leaves behind, and the one before the input: only the
	// distinctions the regex's look-around reads (no word boundary, no Word context), so
	// that bytes the regex treats alike lead to one state, as regex-automata's start and
	// look-behind handling only tracks what the NFA's look set needs
	ctx_of:       [256]Dfa_Ctx,
	start_ctx:    Dfa_Ctx,
	// scratch
	mark:         []u32,
	gen:          u32,
	stack:        [dynamic]i32,
	closure:      [dynamic]i32,
	next:         [dynamic]i32,
	key:          [dynamic]u8,
	// the cache (hybrid::dfa::Config::cache_capacity, from --dfa-size-limit): the bytes its
	// states use, and when it gives up (minimum_cache_clear_count 3, minimum_bytes_per_state
	// 10, as the meta engine configures them)
	capacity:       int,
	mem:            int,
	clear_count:    int,
	searched:       int,      // bytes searched since the last clear, by finished searches
	progress_start: int,      // where the current search's progress since a clear began
	at:             int,      // the position of the transition being computed
	accel_checks: int,        // states still to check for acceleration in this cache
	start_ids:    [Dfa_Ctx]i32, // the start state per context once built (-1: not yet)
	// an unanchored leftmost-first DFA's anchored start states (Anchored::Pattern), for the
	// reverse strategies' forward search from a start already found
	start_ids_anchored: [Dfa_Ctx]i32,
}

// a leftmost-first DFA is unanchored unless the regex is anchored at the start; an All DFA
// runs anchored over a reverse NFA
dfa_new :: proc(n: ^Rx_NFA, mode := Dfa_Mode.Earliest, unanchored := true) -> (d: Lazy_Dfa) {
	d.mode = mode
	d.rev = n.reverse
	d.unanchored = unanchored && mode == .Leftmost_First
	d.nfa = n
	d.pre = prefilter_clone(n.pre) if mode != .All else nil
	for &x in d.start_ids { x = -1 }
	for &x in d.start_ids_anchored { x = -1 }
	d.mark = make([]u32, len(n.states))
	d.capacity = dfa_cache_capacity
	d.accel_checks = DFA_ACCEL_CHECKS
	need_start, need_lf, need_cr, need_word := false, false, false, false
	for s in n.states {
		if s.kind == .Look {
			#partial switch s.look {
			case .Word_Unicode, .Word_Unicode_Negate, .Word_Start_Unicode, .Word_End_Unicode, .Word_Start_Half_Unicode, .Word_End_Half_Unicode:
				d.has_uni_word = true
				need_word = true
			case .Word_Ascii, .Word_Ascii_Negate, .Word_Start_Ascii, .Word_End_Ascii, .Word_Start_Half_Ascii, .Word_End_Half_Ascii:
				need_word = true
			case .Start:
				need_start = true
			case .Start_LF:
				need_start, need_lf = true, true
			case .Start_CRLF:
				need_start, need_lf, need_cr = true, true, true
			case .End_CRLF:
				// backwards it asks whether the byte above is a \n, forwards whether the
				// byte below is a \r
				if d.rev { need_lf = true } else { need_cr = true }
			}
		}
	}
	for b in 0 ..< 256 {
		c := byte_ctx(u8(b))
		switch c {
		case .LF: if !need_lf { c = .Other }
		case .CR: if !need_cr { c = .Other }
		case .Word: if !need_word { c = .Other }
		case .Non_Ascii: if !d.has_uni_word { c = .Other }
		case .Start, .Other:
		}
		d.ctx_of[b] = c
	}
	d.start_ctx = .Start if need_start else .Other
	return
}

// grep-regex's dfa_size_limit: 1000 MiB unless --dfa-size-limit says otherwise
dfa_cache_capacity := 1000 * (1 << 20)

// the bytes one state costs: its row of transitions, its NFA states (kept in the state and
// in the index's key), and the state itself
@(private="file")
state_cost :: #force_inline proc(seeds: int) -> int {
	return DFA_STRIDE * size_of(i32) + 2 * (seeds * 4 + 1) + size_of(Dfa_State)
}

// hybrid::dfa's minimum_cache_capacity, in grepper's terms: the start states of every context,
// and room for a few more; below it there is no lazy DFA (the builder's "insufficient cache
// capacity"), and the meta engine runs without one
dfa_capacity_suffices :: proc(n: ^Rx_NFA) -> bool {
	// as minimum_cache_capacity counts it: the NFA's two sparse sets, and the start states
	// plus 5 (its MIN_STATES), each a row with no NFA states yet
	return dfa_cache_capacity >= 2 * len(n.states) * 4 + (len(Dfa_Ctx) + 5) * state_cost(0)
}

// try_clear_cache: once cleared 3 times, a cache that has searched fewer than 10 bytes per
// state since its last clear gives up (the search quits and the caller falls back)
@(private="file")
gives_up :: proc(d: ^Lazy_Dfa) -> bool {
	if d.clear_count < 3 { return false }
	return d.searched + abs(d.at - d.progress_start) < 10 * len(d.states)
}

dfa_clone :: proc(d: Lazy_Dfa) -> (c: Lazy_Dfa) {
	return dfa_new(d.nfa, d.mode, d.unanchored)
}

@(private="file")
byte_ctx :: #force_inline proc(b: u8) -> Dfa_Ctx {
	switch {
	case b == '\n': return .LF
	case b == '\r': return .CR
	case b >= 0x80: return .Non_Ascii
	case is_word_byte(b): return .Word
	}
	return .Other
}

// the look-around at a position whose previous byte has class prev and whose next byte is
// next (256 for the end); quit when it cannot be decided from them. Backwards (rev), the
// previous byte is the one above the position and the next the one below; the looks of a
// reverse NFA are mirrored, so the same tests hold, but for the CRLF anchors, whose \r\n
// reads \n\r backwards (the determinizer's is_half_crlf handling)
@(private="file")
dfa_look :: proc(l: Look, prev: Dfa_Ctx, next: int, rev: bool) -> (ok: bool, quit: bool) {
	eoi := next == 256
	nb := u8(next) if !eoi else 0
	before_word := prev == .Word
	after_word := !eoi && is_word_byte(nb)
	#partial switch l {
	case .Word_Unicode, .Word_Unicode_Negate, .Word_Start_Unicode, .Word_End_Unicode, .Word_Start_Half_Unicode, .Word_End_Half_Unicode:
		if prev == .Non_Ascii || (!eoi && nb >= 0x80) { return false, true }
	}
	switch l {
	case .Start: return prev == .Start, false
	case .End: return eoi, false
	case .Start_LF: return prev == .Start || prev == .LF, false
	case .End_LF: return eoi || nb == '\n', false
	case .Start_CRLF:
		if rev { return prev == .Start || prev == .CR || (prev == .LF && (eoi || nb != '\r')), false }
		return prev == .Start || prev == .LF || (prev == .CR && (eoi || nb != '\n')), false
	case .End_CRLF:
		if rev { return eoi || nb == '\n' || (nb == '\r' && prev != .LF), false }
		return eoi || nb == '\r' || (nb == '\n' && prev != .CR), false
	case .Word_Ascii, .Word_Unicode: return before_word != after_word, false
	case .Word_Ascii_Negate, .Word_Unicode_Negate: return before_word == after_word, false
	case .Word_Start_Ascii, .Word_Start_Unicode: return !before_word && after_word, false
	case .Word_End_Ascii, .Word_End_Unicode: return before_word && !after_word, false
	case .Word_Start_Half_Ascii, .Word_Start_Half_Unicode: return !before_word, false
	case .Word_End_Half_Ascii, .Word_End_Half_Unicode: return !after_word, false
	}
	return false, false
}

@(private="file")
state_for :: proc(d: ^Lazy_Dfa, ctx: Dfa_Ctx, seeds: []i32, unanchored := false, is_match := false) -> i32 {
	clear(&d.key)
	append(&d.key, u8(ctx) | (u8(unanchored) << 4) | (u8(is_match) << 5))
	for s in seeds {
		x := u32(s)
		append(&d.key, u8(x), u8(x >> 8), u8(x >> 16), u8(x >> 24))
	}
	if id, ok := d.index[string(d.key[:])]; ok { return id }
	st := Dfa_State{ctx = ctx, seeds = slice.clone(seeds), unanchored = unanchored, is_match = is_match}
	switch d.mode {
	case .Earliest: st.is_start = len(seeds) == 0
	case .Leftmost_First: st.is_start = len(seeds) == 0 && unanchored && !is_match
	case .All:
	}
	append(&d.states, st)
	d.mem += state_cost(len(seeds))
	base := len(d.trans)
	resize(&d.trans, base + DFA_STRIDE)
	for k in base ..< base + DFA_STRIDE { d.trans[k] = DFA_UNKNOWN }
	id := i32(len(d.states) - 1)
	d.index[string(slice.clone(d.key[:]))] = id
	return id
}

@(private="file")
start_state :: #force_inline proc(d: ^Lazy_Dfa, ctx: Dfa_Ctx, anchored := false) -> i32 {
	if anchored && d.unanchored {
		// the regex's start alone: these states never hold the unanchored prefix, so none of
		// them is a start state the prefilter would skip from
		if id := d.start_ids_anchored[ctx]; id >= 0 { return id }
		seed := [1]i32{d.nfa.start}
		id := state_for(d, ctx, seed[:])
		d.start_ids_anchored[ctx] = id
		return id
	}
	if id := d.start_ids[ctx]; id >= 0 { return id }
	id: i32
	if d.mode == .Earliest || d.unanchored {
		id = state_for(d, ctx, nil, d.unanchored)
	} else {
		// anchored: the regex's start is the only seed
		seed := [1]i32{d.nfa.start}
		id = state_for(d, ctx, seed[:])
	}
	d.start_ids[ctx] = id
	return id
}

@(private="file")
dfa_reset :: proc(d: ^Lazy_Dfa) {
	d.mem = 0
	d.clear_count += 1
	d.searched = 0
	d.progress_start = d.at
	for &x in d.start_ids { x = -1 }
	for &x in d.start_ids_anchored { x = -1 }
	for s in d.states { delete(s.seeds) }
	clear(&d.states)
	clear(&d.trans)
	d.accel_checks = DFA_ACCEL_CHECKS
	for k in d.index { delete(k) }
	clear(&d.index)
}

// the transition of state sid on next (a byte, or 256 for the end)
@(private="file")
compute :: proc(d: ^Lazy_Dfa, sid: i32, next: int) -> (to: i32, reset: bool) {
	if d.mode != .Earliest { return compute_ordered(d, sid, next) }
	n := d.nfa
	st := &d.states[sid]
	ctx := st.ctx
	d.gen += 1
	if d.gen == 0 { slice.fill(d.mark, 0); d.gen = 1 }
	clear(&d.closure)
	clear(&d.stack)
	append(&d.stack, n.start)
	#reverse for s in st.seeds { append(&d.stack, s) }
	matched := false
	for len(d.stack) > 0 {
		id := pop(&d.stack)
		if d.mark[id] == d.gen { continue }
		d.mark[id] = d.gen
		s := &n.states[id]
		switch s.kind {
		case .Union:
			#reverse for a in s.alts { append(&d.stack, a) }
		case .Look:
			ok, quit := dfa_look(s.look, ctx, next, false)
			if quit { return DFA_QUIT, false }
			if ok { append(&d.stack, s.next) }
		case .Capture:
			append(&d.stack, s.next)
		case .Match:
			matched = true
		case .Fail:
		case .Range, .Sparse:
			append(&d.closure, id)
		}
	}
	if matched { return DFA_MATCH, false }
	if next == 256 { return DFA_NO_EOI, false }
	b := u8(next)
	clear(&d.next)
	for id in d.closure {
		s := &n.states[id]
		if s.kind == .Range {
			if s.lo <= b && b <= s.hi { append(&d.next, s.next) }
		} else {
			for t in s.trans {
				if t.lo <= b && b <= t.hi { append(&d.next, t.next); break }
			}
		}
	}
	slice.sort(d.next[:])
	uniq := slice.unique(d.next[:])
	if d.mem + state_cost(len(uniq)) > d.capacity {
		// the cache is full: start over, keeping only what the search needs next; or give
		// up (QUIT, not stored: reset is true)
		if gives_up(d) { return DFA_QUIT, true }
		ctx_next := d.ctx_of[b]
		seeds := slice.clone(uniq, context.temp_allocator)
		dfa_reset(d)
		return state_for(d, ctx_next, seeds), true
	}
	return state_for(d, d.ctx_of[b], uniq), false
}

Dfa_Result :: enum { No_Match, Match, Quit }

// a computed transition as the table holds it
@(private="file")
encode :: #force_inline proc(d: ^Lazy_Dfa, to: i32) -> i32 {
	if to < 0 { return to }
	base := to * DFA_STRIDE
	if d.states[to].is_match { return DFA_TAG - (base * 4 + 2) }
	if d.pre != nil && d.states[to].is_start { return DFA_TAG - base * 4 }
	if d.states[to].accel { return DFA_TAG - (base * 4 + 1) }
	return base
}

// whether state sid loops on all but at most three bytes; if so it becomes accelerated, and
// every transition into it is tagged. The row is computed in full on the way.
@(private="file")
check_accel :: proc(d: ^Lazy_Dfa, sid: i32) {
	st := &d.states[sid]
	st.accel_checked = true
	if d.accel_checks <= 0 || d.mem + 256 * state_cost(len(d.nfa.states)) > d.capacity { return }
	if d.pre != nil && st.is_start { return }
	d.accel_checks -= 1
	base := int(sid) * DFA_STRIDE
	escapes: [3]u8
	n := 0
	for b in 0 ..< 256 {
		t := d.trans[base + b]
		if t == DFA_UNKNOWN {
			// no reset can happen: the cache has room for the whole row
			to, _ := compute(d, sid, b)
			t = encode(d, to)
			d.trans[base + b] = t
		}
		if t == i32(base) { continue }
		if n == 3 { return }
		escapes[n] = u8(b)
		n += 1
	}
	st = &d.states[sid]
	st.accel, st.accel_n, st.escapes = true, n, escapes
	tagged := DFA_TAG - (i32(base) * 4 + 1)
	for &t in d.trans {
		if t == i32(base) { t = tagged }
	}
}

// in an accelerated state at i: the next escape byte, or the end
@(private="file")
accel_skip :: #force_inline proc(d: ^Lazy_Dfa, h: []u8, i: int, cur, end: int) -> int {
	st := &d.states[cur / DFA_STRIDE]
	hay := h[i:end]
	k: int
	ok: bool
	switch st.accel_n {
	case 0: return end
	case 1: k, ok = nvol.memchr(st.escapes[0], hay)
	case 2: k, ok = nvol.memchr2(st.escapes[0], st.escapes[1], hay)
	case: k, ok = nvol.memchr3(st.escapes[0], st.escapes[1], st.escapes[2], hay)
	}
	return i + k if ok else end
}

// in a start state at i: the prefilter skips to where a match may start (find_fwd_imp). A
// prefilter exists only for a regex that cannot match the empty string, so no candidate means
// no match.
@(private="file")
prefilter_skip :: #force_inline proc(d: ^Lazy_Dfa, h: []u8, i: ^int, cur: ^int, end: int) -> bool {
	r, ok := prefilter_find(d.pre, h, i^, end)
	if !ok { return false }
	if r.start > i^ {
		i^ = r.start
		cur^ = int(start_state(d, d.ctx_of[h[i^ - 1]])) * DFA_STRIDE
	}
	return true
}

// the first position in h[start:end) (end included) where a match ends; look-behind sees
// h[start-1], and the end of h is the end of the input
dfa_find_earliest :: proc(d: ^Lazy_Dfa, h: []u8, start, end: int) -> (at: int, r: Dfa_Result) {
	ctx := d.start_ctx
	if start > 0 { ctx = d.ctx_of[h[start - 1]] }
	i := start
	d.progress_start = i
	defer d.searched += abs(i - d.progress_start)
	cur := int(start_state(d, ctx)) * DFA_STRIDE
	if d.pre != nil && i < end && !prefilter_skip(d, h, &i, &cur, end) { return 0, .No_Match }
	for i < end {
		// the hot loop: known transitions to ordinary states
		tbl := d.trans[:]
		#no_bounds_check for i < end {
			next := tbl[cur + int(h[i])]
			if next < 0 { break }
			cur = int(next)
			i += 1
		}
		if i >= end { break }
		b := int(h[i])
		next := d.trans[cur + b]
		if next == DFA_UNKNOWN {
			sid := i32(cur / DFA_STRIDE)
			d.at = i
			to, reset := compute(d, sid, b)
			next = encode(d, to)
			// after a reset of the cache the state at cur is gone
			if !reset {
				d.trans[cur + b] = next
				if to == sid && !d.states[sid].accel_checked {
					check_accel(d, sid)
					next = d.trans[cur + b]
				}
			}
		}
		switch {
		case next == DFA_MATCH: return i, .Match
		case next == DFA_QUIT: return i, .Quit
		case next <= DFA_TAG:
			v := int(DFA_TAG - next)
			cur = v >> 2
			i += 1
			if v & 3 == 0 {
				if i < end && !prefilter_skip(d, h, &i, &cur, end) { return 0, .No_Match }
			} else if i < end {
				i = accel_skip(d, h, i, cur, end)
			}
		case:
			cur = int(next)
			i += 1
		}
	}
	// the end: a match that needs to see it
	sid := i32(cur / DFA_STRIDE)
	eoi_byte := 256
	if end < len(h) { eoi_byte = int(h[end]) }
	t: i32 = d.trans[cur + 256] if eoi_byte == 256 else DFA_UNKNOWN
	if t == DFA_UNKNOWN {
		reset: bool
		t, reset = compute(d, sid, eoi_byte)
		if eoi_byte == 256 && !reset { d.trans[cur + 256] = t }
	}
	switch t {
	case DFA_MATCH: return end, .Match
	case DFA_QUIT: return end, .Quit
	}
	return 0, .No_Match
}

// ---------------------------------------------------------------------------------------------
// Leftmost-first and All (util/determinize's next with MatchKind::LeftmostFirst and All)

// The transition of state sid on next for the ordered modes. The NFA states of a set keep
// their priority order (a depth-first closure, the first occurrence kept); the unanchored
// prefix, a lazy `(?s-u:.)*?`, comes last. A match in the closure makes the next state a
// match state and, leftmost-first, cuts every thread after it, the unanchored prefix too.
@(private="file")
compute_ordered :: proc(d: ^Lazy_Dfa, sid: i32, next: int) -> (to: i32, reset: bool) {
	n := d.nfa
	st := &d.states[sid]
	ctx := st.ctx
	unanchored := st.unanchored
	d.gen += 1
	if d.gen == 0 { slice.fill(d.mark, 0); d.gen = 1 }
	clear(&d.closure)
	clear(&d.stack)
	if unanchored { append(&d.stack, n.start) }
	#reverse for s in st.seeds { append(&d.stack, s) }
	for len(d.stack) > 0 {
		id := pop(&d.stack)
		if d.mark[id] == d.gen { continue }
		d.mark[id] = d.gen
		s := &n.states[id]
		switch s.kind {
		case .Union:
			#reverse for a in s.alts { append(&d.stack, a) }
		case .Look:
			ok, quit := dfa_look(s.look, ctx, next, d.rev)
			if quit { return DFA_QUIT, false }
			if ok { append(&d.stack, s.next) }
		case .Capture:
			append(&d.stack, s.next)
		case .Fail:
		case .Match, .Range, .Sparse:
			append(&d.closure, id)
		}
	}
	leftmost := d.mode == .Leftmost_First
	if next == 256 {
		for id in d.closure {
			if n.states[id].kind == .Match { return DFA_MATCH, false }
		}
		return DFA_NO_EOI, false
	}
	b := u8(next)
	clear(&d.next)
	matched := false
	scan: for id in d.closure {
		s := &n.states[id]
		#partial switch s.kind {
		case .Match:
			matched = true
			if leftmost { break scan }
		case .Range:
			if s.lo <= b && b <= s.hi { append(&d.next, s.next) }
		case .Sparse:
			for t in s.trans {
				if t.lo <= b && b <= t.hi { append(&d.next, t.next); break }
			}
		}
	}
	// the unanchored prefix's own byte state, last in the set, loops on every byte
	next_unanchored := unanchored && !matched
	seeds: []i32
	if leftmost {
		// the first occurrence of each target keeps its place
		d.gen += 1
		if d.gen == 0 { slice.fill(d.mark, 0); d.gen = 1 }
		k := 0
		for t in d.next {
			if d.mark[t] == d.gen { continue }
			d.mark[t] = d.gen
			d.next[k] = t
			k += 1
		}
		seeds = d.next[:k]
	} else {
		// All: the order of the threads cannot change the answer
		slice.sort(d.next[:])
		seeds = slice.unique(d.next[:])
	}
	if len(seeds) == 0 && !next_unanchored && !matched { return DFA_DEAD, false }
	if d.mem + state_cost(len(seeds)) > d.capacity {
		if gives_up(d) { return DFA_QUIT, true }
		ctx_next := d.ctx_of[b]
		kept := slice.clone(seeds, context.temp_allocator)
		dfa_reset(d)
		return state_for(d, ctx_next, kept, next_unanchored, matched), true
	}
	return state_for(d, d.ctx_of[b], seeds, next_unanchored, matched), false
}

// the encoded transition of the state at cur on next, computed when unknown
@(private="file")
transition :: #force_inline proc(d: ^Lazy_Dfa, cur: ^int, next: int, accel: bool) -> i32 {
	t := d.trans[cur^ + next]
	if t != DFA_UNKNOWN { return t }
	sid := i32(cur^ / DFA_STRIDE)
	to, reset := compute(d, sid, next)
	t = encode(d, to)
	if !reset {
		d.trans[cur^ + next] = t
		if accel && to == sid && !d.states[sid].accel_checked {
			check_accel(d, sid)
			t = d.trans[cur^ + next]
		}
	}
	return t
}

// hybrid::search::find_fwd, leftmost-first: the end of the leftmost-first match in
// h[start:end); look-behind sees h[start-1], and h[end] (or the end of h) is the look-ahead
// at the end. Anchored, the match must start at start (no prefilter then); earliest, the
// first match state ends the search (Input::earliest). With no match, stop gets where the
// search ended: the byte that led to the dead state, or end (meta::stopat)
dfa_find_fwd :: proc(d: ^Lazy_Dfa, h: []u8, start, end: int, anchored := false, earliest := false, stop: ^int = nil) -> (at: int, r: Dfa_Result) {
	ctx := d.start_ctx
	if start > 0 { ctx = d.ctx_of[h[start - 1]] }
	i := start
	d.progress_start = i
	defer d.searched += abs(i - d.progress_start)
	mat := -1
	cur := int(start_state(d, ctx, anchored)) * DFA_STRIDE
	if d.pre != nil && !anchored && i < end && !prefilter_skip(d, h, &i, &cur, end) { return 0, .No_Match }
	for i < end {
		tbl := d.trans[:]
		#no_bounds_check for i < end {
			next := tbl[cur + int(h[i])]
			if next < 0 { break }
			cur = int(next)
			i += 1
		}
		if i >= end { break }
		d.at = i
		next := transition(d, &cur, int(h[i]), true)
		switch {
		case next == DFA_DEAD:
			if stop != nil { stop^ = i }
			return mat, .Match if mat >= 0 else .No_Match
		case next == DFA_QUIT: return i, .Quit
		case next <= DFA_TAG:
			v := int(DFA_TAG - next)
			cur = v >> 2
			kind := v & 3
			if kind == 2 {
				mat = i
				if earliest { return mat, .Match }
			}
			i += 1
			if kind == 0 {
				if i < end && !prefilter_skip(d, h, &i, &cur, end) {
					return mat, .Match if mat >= 0 else .No_Match
				}
			} else if kind == 1 && i < end {
				i = accel_skip(d, h, i, cur, end)
			}
		case:
			cur = int(next)
			i += 1
		}
	}
	// eoi_fwd: the byte after the end, or the end of the input
	t: i32
	if end < len(h) {
		t = transition(d, &cur, int(h[end]), false)
		if t <= DFA_TAG && int(DFA_TAG - t) & 3 == 2 { mat = end }
	} else {
		t = transition(d, &cur, 256, false)
		if t == DFA_MATCH { mat = end }
	}
	if t == DFA_QUIT { return end, .Quit }
	if stop != nil { stop^ = end }
	return mat, .Match if mat >= 0 else .No_Match
}

// hybrid::search::find_rev with an anchored input: the start of the longest match of the
// reverse NFA ending at end and starting at or after start (MatchKind::All keeps the last
// match found going backwards); look-behind sees h[end], look-ahead h[start-1]
dfa_find_rev :: proc(d: ^Lazy_Dfa, h: []u8, start, end: int) -> (at: int, r: Dfa_Result) {
	ctx := d.start_ctx
	if end < len(h) { ctx = d.ctx_of[h[end]] }
	i := end
	d.progress_start = i
	defer d.searched += abs(i - d.progress_start)
	mat := -1
	cur := int(start_state(d, ctx)) * DFA_STRIDE
	for i > start {
		tbl := d.trans[:]
		#no_bounds_check for i > start {
			next := tbl[cur + int(h[i - 1])]
			if next < 0 { break }
			cur = int(next)
			i -= 1
		}
		if i <= start { break }
		d.at = i - 1
		next := transition(d, &cur, int(h[i - 1]), false)
		switch {
		case next == DFA_DEAD: return mat, .Match if mat >= 0 else .No_Match
		case next == DFA_QUIT: return i, .Quit
		case next <= DFA_TAG:
			// only match states are tagged here: no prefilter, no acceleration
			cur = int(DFA_TAG - next) >> 2
			mat = i
			i -= 1
		case:
			cur = int(next)
			i -= 1
		}
	}
	// eoi_rev: the byte before the start, or the start of the input
	t: i32
	if start > 0 {
		t = transition(d, &cur, int(h[start - 1]), false)
		if t <= DFA_TAG { mat = start }
	} else {
		t = transition(d, &cur, 256, false)
		if t == DFA_MATCH { mat = start }
	}
	if t == DFA_QUIT { return start, .Quit }
	return mat, .Match if mat >= 0 else .No_Match
}

// meta::limited::hybrid_try_search_half_rev: dfa_find_rev, given up (quadratic) when it
// would read a byte below min_start, the end of the previous literal match, past the first
// byte; and when it reaches start without dying with a match that starts later, since a
// longer match might still begin before start ("avoid potential false positive match")
dfa_find_rev_limited :: proc(d: ^Lazy_Dfa, h: []u8, start, end, min_start: int) -> (at: int, r: Dfa_Result, quadratic: bool) {
	ctx := d.start_ctx
	if end < len(h) { ctx = d.ctx_of[h[end]] }
	i := end
	d.progress_start = i
	defer d.searched += abs(i - d.progress_start)
	mat := -1
	cur := int(start_state(d, ctx)) * DFA_STRIDE
	lim := max(start, min_start)
	for i > start {
		if i != end && i <= min_start { return 0, .No_Match, true }
		tbl := d.trans[:]
		#no_bounds_check for i > lim {
			next := tbl[cur + int(h[i - 1])]
			if next < 0 { break }
			cur = int(next)
			i -= 1
		}
		if i <= start { break }
		if i != end && i <= min_start { return 0, .No_Match, true }
		d.at = i - 1
		next := transition(d, &cur, int(h[i - 1]), false)
		switch {
		case next == DFA_DEAD: return mat, .Match if mat >= 0 else .No_Match, false
		case next == DFA_QUIT: return i, .Quit, false
		case next <= DFA_TAG:
			cur = int(DFA_TAG - next) >> 2
			mat = i
			i -= 1
		case:
			cur = int(next)
			i -= 1
		}
	}
	t: i32
	if start > 0 {
		t = transition(d, &cur, int(h[start - 1]), false)
		if t <= DFA_TAG { mat = start }
	} else {
		t = transition(d, &cur, 256, false)
		if t == DFA_MATCH { mat = start }
	}
	if t == DFA_QUIT { return start, .Quit, false }
	if mat > start { return 0, .No_Match, true }
	return mat, .Match if mat >= 0 else .No_Match, false
}
