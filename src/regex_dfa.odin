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

DFA_UNKNOWN :: -1
DFA_MATCH   :: -2      // a match ends where the byte would be read
DFA_QUIT    :: -3
DFA_NO_EOI  :: -4      // at the end: no match

Dfa_State :: struct {
	ctx:   Dfa_Ctx,
	seeds: []i32,
	trans: [257]i32,     // per byte, and EOI at 256
}

Lazy_Dfa :: struct {
	nfa:          ^Rx_NFA,
	states:       [dynamic]Dfa_State,
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
}

dfa_new :: proc(n: ^Rx_NFA) -> (d: Lazy_Dfa) {
	d.nfa = n
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
	st := Dfa_State{ctx = ctx, seeds = slice.clone(seeds)}
	for &t in st.trans { t = DFA_UNKNOWN }
	append(&d.states, st)
	id := i32(len(d.states) - 1)
	d.index[string(slice.clone(d.key[:]))] = id
	return id
}

@(private="file")
dfa_reset :: proc(d: ^Lazy_Dfa) {
	for s in d.states { delete(s.seeds) }
	clear(&d.states)
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

// the first position in h[start:end) (end included) where a match ends; look-behind sees
// h[start-1], and the end of h is the end of the input
dfa_find_earliest :: proc(d: ^Lazy_Dfa, h: []u8, start, end: int) -> (at: int, r: Dfa_Result) {
	ctx := Dfa_Ctx.Start
	if start > 0 { ctx = byte_ctx(h[start - 1]) }
	sid := state_for(d, ctx, nil)
	for i := start; i < end; i += 1 {
		b := h[i]
		next := d.states[sid].trans[b]
		if next == DFA_UNKNOWN {
			reset: bool
			next, reset = compute(d, sid, int(b))
			// after a reset of the cache sid is gone
			if !reset { d.states[sid].trans[b] = next }
		}
		switch next {
		case DFA_MATCH: return i, .Match
		case DFA_QUIT: return i, .Quit
		}
		sid = next
	}
	// the end: a match that needs to see it
	eoi_byte := 256
	if end < len(h) { eoi_byte = int(h[end]) }
	t := d.states[sid].trans[256] if eoi_byte == 256 else DFA_UNKNOWN
	if t == DFA_UNKNOWN {
		reset: bool
		t, reset = compute(d, sid, eoi_byte)
		if eoi_byte == 256 && !reset { d.states[sid].trans[256] = t }
	}
	switch t {
	case DFA_MATCH: return end, .Match
	case DFA_QUIT: return end, .Quit
	}
	return 0, .No_Match
}
