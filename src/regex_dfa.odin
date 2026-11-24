// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"

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
// a transition into a start state when there is a prefilter: DFA_START_TAG - target
DFA_START_TAG :: -16

Dfa_State :: struct {
	is_start: bool,          // no seeds: only the unanchored start's closure is alive
	ctx:   Dfa_Ctx,
	seeds: []i32,
}

Lazy_Dfa :: struct {
	nfa:          ^Rx_NFA,
	pre:          ^Prefilter,     // the NFA's prefilter, this DFA's own copy
	states:       [dynamic]Dfa_State,
	trans:        [dynamic]i32,   // DFA_STRIDE entries per state, encoded as above
	index:        map[string]i32,
	has_uni_word: bool,
	// scratch
	mark:         []u32,
	gen:          u32,
	stack:        [dynamic]i32,
	closure:      [dynamic]i32,
	next:         [dynamic]i32,
	key:          [dynamic]u8,
	budget:       int,        // states before the cache is cleared
	start_ids:    [Dfa_Ctx]i32, // the start state per context once built (-1: not yet)
}

dfa_new :: proc(n: ^Rx_NFA) -> (d: Lazy_Dfa) {
	d.nfa = n
	d.pre = prefilter_clone(n.pre)
	for &x in d.start_ids { x = -1 }
	d.mark = make([]u32, len(n.states))
	d.budget = 4096
	for s in n.states {
		if s.kind == .Look {
			#partial switch s.look {
			case .Word_Unicode, .Word_Unicode_Negate, .Word_Start_Unicode, .Word_End_Unicode, .Word_Start_Half_Unicode, .Word_End_Half_Unicode:
				d.has_uni_word = true
			}
		}
	}
	return
}

dfa_clone :: proc(d: Lazy_Dfa) -> (c: Lazy_Dfa) {
	return dfa_new(d.nfa)
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
// next (256 for the end); quit when it cannot be decided from them
@(private="file")
dfa_look :: proc(l: Look, prev: Dfa_Ctx, next: int) -> (ok: bool, quit: bool) {
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
	case .Start_CRLF: return prev == .Start || prev == .LF || (prev == .CR && (eoi || nb != '\n')), false
	case .End_CRLF: return eoi || nb == '\r' || (nb == '\n' && prev != .CR), false
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
state_for :: proc(d: ^Lazy_Dfa, ctx: Dfa_Ctx, seeds: []i32) -> i32 {
	clear(&d.key)
	append(&d.key, u8(ctx))
	for s in seeds {
		x := u32(s)
		append(&d.key, u8(x), u8(x >> 8), u8(x >> 16), u8(x >> 24))
	}
	if id, ok := d.index[string(d.key[:])]; ok { return id }
	st := Dfa_State{ctx = ctx, seeds = slice.clone(seeds), is_start = len(seeds) == 0}
	append(&d.states, st)
	base := len(d.trans)
	resize(&d.trans, base + DFA_STRIDE)
	for k in base ..< base + DFA_STRIDE { d.trans[k] = DFA_UNKNOWN }
	id := i32(len(d.states) - 1)
	d.index[string(slice.clone(d.key[:]))] = id
	return id
}

@(private="file")
start_state :: #force_inline proc(d: ^Lazy_Dfa, ctx: Dfa_Ctx) -> i32 {
	if id := d.start_ids[ctx]; id >= 0 { return id }
	id := state_for(d, ctx, nil)
	d.start_ids[ctx] = id
	return id
}

@(private="file")
dfa_reset :: proc(d: ^Lazy_Dfa) {
	for &x in d.start_ids { x = -1 }
	for s in d.states { delete(s.seeds) }
	clear(&d.states)
	clear(&d.trans)
	for k in d.index { delete(k) }
	clear(&d.index)
}

// the transition of state sid on next (a byte, or 256 for the end)
@(private="file")
compute :: proc(d: ^Lazy_Dfa, sid: i32, next: int) -> (to: i32, reset: bool) {
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
			ok, quit := dfa_look(s.look, ctx, next)
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
	if len(d.states) >= d.budget {
		// the cache is full: start over, keeping only what the search needs next
		ctx_next := byte_ctx(b)
		seeds := slice.clone(uniq, context.temp_allocator)
		dfa_reset(d)
		return state_for(d, ctx_next, seeds), true
	}
	return state_for(d, byte_ctx(b), uniq), false
}

Dfa_Result :: enum { No_Match, Match, Quit }

// a computed transition as the table holds it
@(private="file")
encode :: #force_inline proc(d: ^Lazy_Dfa, to: i32) -> i32 {
	if to < 0 { return to }
	base := to * DFA_STRIDE
	if d.pre != nil && d.states[to].is_start { return DFA_START_TAG - base }
	return base
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
		cur^ = int(start_state(d, byte_ctx(h[i^ - 1]))) * DFA_STRIDE
	}
	return true
}

// the first position in h[start:end) (end included) where a match ends; look-behind sees
// h[start-1], and the end of h is the end of the input
dfa_find_earliest :: proc(d: ^Lazy_Dfa, h: []u8, start, end: int) -> (at: int, r: Dfa_Result) {
	ctx := Dfa_Ctx.Start
	if start > 0 { ctx = byte_ctx(h[start - 1]) }
	i := start
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
			to, reset := compute(d, i32(cur / DFA_STRIDE), b)
			next = encode(d, to)
			// after a reset of the cache the state at cur is gone
			if !reset { d.trans[cur + b] = next }
		}
		switch {
		case next == DFA_MATCH: return i, .Match
		case next == DFA_QUIT: return i, .Quit
		case next <= DFA_START_TAG:
			cur = int(DFA_START_TAG - next)
			i += 1
			if i < end && !prefilter_skip(d, h, &i, &cur, end) { return 0, .No_Match }
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
