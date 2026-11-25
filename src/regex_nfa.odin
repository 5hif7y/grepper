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
	pre:         ^Prefilter,       // where a match may start, from the regex's prefixes (nil: none)
	reverse:     bool,             // compiled to match backwards, without capture states
	prog:        Pike_Prog,        // the PikeVM's compact copy of states (rx_finish)
}

// the states as the PikeVM reads them: 20 bytes each instead of Rx_State's 104, the sparse
// transitions and the union alternatives in two flat pools (a state's run: [a, a + count))
Pike_Op :: struct {
	kind:   Rx_State_Kind,
	lo, hi: u8,
	look:   Look,
	next:   i32,       // Range, Look, Capture
	a:      i32,       // Sparse, Union: the run's start in the pool; Capture: the slot
	count:  i32,
}

Pike_Prog :: struct {
	ops:   []Pike_Op,
	trans: []Rx_Trans,
	alts:  []i32,
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

// the compiler with reverse(true) and which_captures(None), as the meta engine builds the NFA
// of its reverse lazy DFA: concatenations and literals in reverse order, the UTF-8 sequences of
// classes reversed, look-around mirrored, no capture states (group 0 included)
rx_compile_reverse :: proc(h: ^Hir) -> (n: Rx_NFA) {
	n.reverse = true
	ref := c(&n, h)
	m := add_state(&n, {kind = .Match})
	patch(&n, ref.end, m)
	n.start = ref.start
	rx_finish(&n)
	return
}

// Look::reversed
look_reversed :: proc(l: Look) -> Look {
	#partial switch l {
	case .Start: return .End
	case .End: return .Start
	case .Start_LF: return .End_LF
	case .End_LF: return .Start_LF
	case .Start_CRLF: return .End_CRLF
	case .End_CRLF: return .Start_CRLF
	case .Word_Start_Ascii: return .Word_End_Ascii
	case .Word_End_Ascii: return .Word_Start_Ascii
	case .Word_Start_Unicode: return .Word_End_Unicode
	case .Word_End_Unicode: return .Word_Start_Unicode
	case .Word_Start_Half_Ascii: return .Word_End_Half_Ascii
	case .Word_End_Half_Ascii: return .Word_Start_Half_Ascii
	case .Word_Start_Half_Unicode: return .Word_End_Half_Unicode
	case .Word_End_Half_Unicode: return .Word_Start_Half_Unicode
	}
	return l
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
		for k in 0 ..< len(h.lit) {
			b := h.lit[len(h.lit) - 1 - k] if n.reverse else h.lit[k]
			id := add_state(n, {kind = .Range, lo = b, hi = b})
			if first.start < 0 { first.start = id } else { patch(n, first.end, id) }
			first.end = id
		}
		return first
	case .Class:
		return c_class(n, h.class)
	case .Look:
		id := add_state(n, {kind = .Look, look = look_reversed(h.look) if n.reverse else h.look})
		return {id, id}
	case .Repetition:
		return c_repetition(n, h)
	case .Capture:
		if n.reverse { return c(n, h.sub) }
		return c_cap(n, h.index, h.sub)
	case .Concat:
		// c_concat: the last expression first in reverse
		count := len(h.subs)
		sub_at :: proc(n: ^Rx_NFA, h: ^Hir, k: int) -> ^Hir {
			return h.subs[len(h.subs) - 1 - k] if n.reverse else h.subs[k]
		}
		r := c(n, sub_at(n, h, 0))
		for k in 1 ..< count {
			x := c(n, sub_at(n, h, k))
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
	// a Unicode class: its UTF-8 sequences, compressed as regex-automata compiles them. The
	// naive alternation of every sequence made Unicode \w ~3000 states, one Union whose
	// closure walks them all at each position (upstream measures 283 states compressed, and
	// a PikeVM search 45 s -> 1.4 s)
	seqs: [dynamic]Utf8_Sequence
	defer delete(seqs)
	for r in cls.ranges { utf8_sequences(r.lo, r.hi, &seqs) }
	// (the `end` made above, for the ASCII path, stays unreachable here)
	if n.reverse { return c_class_reverse(n, seqs[:]) }
	return utf8_compile(n, seqs[:])
}

// Utf8BoundedMap and Utf8SuffixMap: a fixed number of entries, hashed with FNV-1a, a new
// entry replacing whatever collided with it, all dropped at once by bumping the version
UTF8_FNV_PRIME :: u64(1099511628211)
UTF8_FNV_INIT :: u64(14695981039346656037)

@(private="file")
Utf8_Bounded_Entry :: struct {
	version: u16,
	key:     [dynamic]Rx_Trans,
	val:     i32,
}

@(private="file")
Utf8_Suffix_Entry :: struct {
	version:     u16,
	from:        i32,
	lo, hi:      u8,
	val:         i32,
}

// one per thread: compiling an NFA builds no state shared with another thread
@(private="file", thread_local) utf8_compiled: [dynamic]Utf8_Bounded_Entry
@(private="file", thread_local) utf8_compiled_version: u16
@(private="file", thread_local) utf8_suffix: [dynamic]Utf8_Suffix_Entry
@(private="file", thread_local) utf8_suffix_version: u16

@(private="file")
Utf8_Node :: struct {
	trans:    [dynamic]Rx_Trans,
	has_last: bool,
	last:     Utf8_Range,
}

// regex-automata's Utf8Compiler: Daciuk's incremental construction of a (near) minimal
// automaton from sequences in lexicographic order, as Utf8Sequences gives them. A stack of
// uncompiled nodes holds the current sequence's path; when the next sequence leaves it, the
// nodes past the shared prefix are frozen bottom-up into Sparse states, an equal state
// compiled before (the bounded map) reused instead of added
@(private="file")
utf8_compile :: proc(n: ^Rx_NFA, seqs: []Utf8_Sequence) -> Rx_Ref {
	if len(utf8_compiled) == 0 {
		resize(&utf8_compiled, 10_000)
	} else {
		utf8_compiled_version += 1
		if utf8_compiled_version == 0 {
			for &e in utf8_compiled { e.version = 0 }
			utf8_compiled_version = 1
		}
	}
	target := add_empty(n)
	uncompiled: [dynamic]Utf8_Node
	defer {
		for &u in uncompiled { delete(u.trans) }
		delete(uncompiled)
	}
	append(&uncompiled, Utf8_Node{})
	compile :: proc(n: ^Rx_NFA, trans: [dynamic]Rx_Trans) -> i32 {
		h := UTF8_FNV_INIT
		for t in trans {
			h = (h ~ u64(t.lo)) * UTF8_FNV_PRIME
			h = (h ~ u64(t.hi)) * UTF8_FNV_PRIME
			h = (h ~ u64(u32(t.next))) * UTF8_FNV_PRIME
		}
		e := &utf8_compiled[h % u64(len(utf8_compiled))]
		if e.version == utf8_compiled_version && slice_equal_trans(e.key[:], trans[:]) {
			delete(trans)
			return e.val
		}
		id := add_state(n, {kind = .Sparse, trans = slice_clone_dyn(trans[:])})
		delete(e.key)
		e^ = {version = utf8_compiled_version, key = trans, val = id}
		return id
	}
	// the node's pending last transition, frozen to point at next
	freeze :: proc(u: ^Utf8_Node, next: i32) {
		if u.has_last {
			append(&u.trans, Rx_Trans{u.last.lo, u.last.hi, next})
			u.has_last = false
		}
	}
	compile_from :: proc(n: ^Rx_NFA, uncompiled: ^[dynamic]Utf8_Node, target: i32, from: int) {
		next := target
		for from + 1 < len(uncompiled) {
			u := pop(uncompiled)
			freeze(&u, next)
			next = compile(n, u.trans)
		}
		freeze(&uncompiled[len(uncompiled) - 1], next)
	}
	for &seq in seqs {
		ranges := seq.ranges[:seq.n]
		prefix := 0
		for prefix < len(ranges) && prefix < len(uncompiled) {
			u := &uncompiled[prefix]
			if !u.has_last || u.last != ranges[prefix] { break }
			prefix += 1
		}
		assert(prefix < len(ranges), "UTF-8 sequences must be sorted and distinct")
		compile_from(n, &uncompiled, target, prefix)
		// add_suffix: the part of the sequence past the shared prefix
		suffix := ranges[prefix:]
		last := &uncompiled[len(uncompiled) - 1]
		assert(!last.has_last)
		last.has_last, last.last = true, suffix[0]
		for r in suffix[1:] { append(&uncompiled, Utf8_Node{has_last = true, last = r}) }
	}
	compile_from(n, &uncompiled, target, 0)
	assert(len(uncompiled) == 1 && !uncompiled[0].has_last)
	root := uncompiled[0].trans
	uncompiled[0].trans = {}
	return {compile(n, root), target}
}

// c_unicode_class_reverse_with_suffix (the meta engine builds its reverse NFAs with
// shrink(false)): each sequence read backwards, as a chain of Range states into one end, a
// chain step already built for the same (next, range) reused (Utf8SuffixMap, 1000 entries)
@(private="file")
c_class_reverse :: proc(n: ^Rx_NFA, seqs: []Utf8_Sequence) -> Rx_Ref {
	if len(utf8_suffix) == 0 {
		resize(&utf8_suffix, 1000)
	} else {
		utf8_suffix_version += 1
		if utf8_suffix_version == 0 {
			for &e in utf8_suffix { e.version = 0 }
			utf8_suffix_version = 1
		}
	}
	u := add_state(n, {kind = .Union})
	alt_end := add_empty(n)
	for &seq in seqs {
		end := alt_end
		for r in seq.ranges[:seq.n] {
			h := UTF8_FNV_INIT
			h = (h ~ u64(u32(end))) * UTF8_FNV_PRIME
			h = (h ~ u64(r.lo)) * UTF8_FNV_PRIME
			h = (h ~ u64(r.hi)) * UTF8_FNV_PRIME
			e := &utf8_suffix[h % u64(len(utf8_suffix))]
			if e.version == utf8_suffix_version && e.from == end && e.lo == r.lo && e.hi == r.hi {
				end = e.val
				continue
			}
			id := add_state(n, {kind = .Range, lo = r.lo, hi = r.hi, next = end})
			e^ = {version = utf8_suffix_version, from = end, lo = r.lo, hi = r.hi, val = id}
			end = id
		}
		patch(n, u, end)
	}
	return {u, alt_end}
}

@(private="file")
slice_equal_trans :: proc(a, b: []Rx_Trans) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a {
		if x != b[i] { return false }
	}
	return true
}

@(private="file")
slice_clone_dyn :: proc(a: []Rx_Trans) -> (d: [dynamic]Rx_Trans) {
	append(&d, ..a)
	return
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
		// the PikeVM stops a sparse scan at the first range past the byte
		if s.kind == .Sparse {
			slice.sort_by(s.trans[:], proc(a, b: Rx_Trans) -> bool { return a.lo < b.lo })
		}
	}
	nt, na := 0, 0
	for s in n.states { nt += len(s.trans); na += len(s.alts) }
	p := &n.prog
	p.ops = make([]Pike_Op, len(n.states))
	p.trans = make([]Rx_Trans, nt)
	p.alts = make([]i32, na)
	nt, na = 0, 0
	for s, i in n.states {
		op := Pike_Op{kind = s.kind, lo = s.lo, hi = s.hi, look = s.look, next = s.next}
		#partial switch s.kind {
		case .Sparse:
			op.a, op.count = i32(nt), i32(len(s.trans))
			copy(p.trans[nt:], s.trans[:])
			nt += len(s.trans)
		case .Union:
			op.a, op.count = i32(na), i32(len(s.alts))
			copy(p.alts[na:], s.alts[:])
			na += len(s.alts)
		case .Capture:
			op.a = s.slot
		}
		p.ops[i] = op
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
	pre:    ^Prefilter,            // the NFA's prefilter, this cache's own copy
	curr, next: Pike_List,
	mark:   []u32,
	gen:    u32,
	stack:  [dynamic]Pike_Frame,
	scratch: []int,
}

// ActiveStates: the threads in priority order, and the slot table, n.slots values per NFA
// state (a state is at most once in a list, so its slots live at its own row)
Pike_List :: struct {
	ids:   []i32,
	len:   int,
	slots: []int,
}

// FollowEpsilon: explore state `op`, or (op < 0) put val back into slot -op - 1. Two words,
// written and read whole: with an i32 pair in the first word, Odin stores them apart and
// loads them as one, and the load waits for the stores to retire (no store forwarding)
Pike_Frame :: struct {
	op:  int,
	val: int,
}

pike_cache_new :: proc(n: ^Rx_NFA) -> (c: Pike_Cache) {
	c.pre = prefilter_clone(n.pre)
	c.mark = make([]u32, len(n.states))
	c.scratch = make([]int, n.slots)
	return
}

// the lists are made on the first search: most caches never run the PikeVM
@(private="file")
pike_lists :: proc(n: ^Rx_NFA, c: ^Pike_Cache) {
	if c.curr.ids != nil { return }
	ns := len(n.states)
	for l in ([]^Pike_List{&c.curr, &c.next}) {
		l.ids = make([]i32, ns)
		l.slots = make([]int, ns * n.slots)
	}
}

// follow epsilon transitions from sid at position `at`, adding the threads reached to list
// in priority order (a depth-first walk with the capture slots set and restored on the way,
// so slots is as it was on return)
@(private="file")
epsilon_closure :: proc(n: ^Rx_NFA, c: ^Pike_Cache, list: ^Pike_List, sid: i32, slots_ptr: [^]int, ns: int, h_ptr: [^]u8, h_len: int, at: int) {
	// the slots and the haystack come as pointers and lengths: a slice argument is built in
	// two stores and copied in one load, the same stall as the frames'
	slots := slots_ptr[:ns]
	h := h_ptr[:h_len]
	prog := &n.prog
	base := len(c.stack)
	// the first state is explored without a trip through the stack
	id := sid
	#no_bounds_check for {
		for {
			if c.mark[id] == c.gen { break }
			c.mark[id] = c.gen
			s := &prog.ops[id]
			#partial switch s.kind {
			case .Union:
				if s.count == 0 { break }
				alts := prog.alts[s.a:][:s.count]
				#reverse for alt in alts[1:] { append(&c.stack, Pike_Frame{op = int(alt)}) }
				id = alts[0]
				continue
			case .Look:
				if !look_matches(s.look, h, at) { break }
				id = s.next
				continue
			case .Capture:
				if int(s.a) < ns {
					append(&c.stack, Pike_Frame{op = -int(s.a) - 1, val = slots[s.a]})
					slots[s.a] = at
				}
				id = s.next
				continue
			case .Fail:
				break
			case:
				list.ids[list.len] = id
				list.len += 1
				if ns > 0 { copy(list.slots[int(id) * ns:][:ns], slots) }
			}
			break
		}
		// the next frame: restore the slots it passes, until a state to explore
		for {
			if len(c.stack) == base { return }
			f := pop(&c.stack)
			if f.op >= 0 { id = i32(f.op); break }
			slots[-f.op - 1] = f.val
		}
	}
}

// the leftmost-first match in h[start:end) (look-around sees all of h); slots get the
// capture positions (slots[0], slots[1] the match). earliest: stop at the first match state
// reached (Input::earliest), whose end is all the caller needs
pike_search :: proc(n: ^Rx_NFA, c: ^Pike_Cache, h: []u8, start, end: int, anchored: bool, slots: []int, earliest := false) -> bool {
	pike_lists(n, c)
	ns := n.slots
	prog := &n.prog
	assert(len(prog.ops) == len(n.states), "rx_finish builds the PikeVM's program")
	c.curr.len = 0
	matched := false
	for &x in slots { x = -1 }
	for at := start; at <= end; at += 1 {
		// no thread alive and no match yet: skip to where the prefilter says a match may
		// start, as regex-automata's PikeVM does
		if c.curr.len == 0 && !matched && !anchored && c.pre != nil {
			r, ok := prefilter_find(c.pre, h, at, end)
			if !ok { break }
			at = r.start
		}
		// a new thread at the lowest priority, until a match is found
		if !matched && (!anchored || at == start) {
			c.gen += 1
			if c.gen == 0 { slice.fill(c.mark, 0); c.gen = 1 }
			// threads already in the list keep their marks from this generation
			for sid in c.curr.ids[:c.curr.len] { c.mark[sid] = c.gen }
			for &x in c.scratch { x = -1 }
			epsilon_closure(n, c, &c.curr, n.start, raw_data(c.scratch), ns, raw_data(h), len(h), at)
		}
		if c.curr.len == 0 {
			if matched || anchored { break }
			continue
		}
		c.gen += 1
		if c.gen == 0 { slice.fill(c.mark, 0); c.gen = 1 }
		c.next.len = 0
		#no_bounds_check for sid in c.curr.ids[:c.curr.len] {
			s := &prog.ops[sid]
			tslots := c.curr.slots[int(sid) * ns:][:ns]
			tptr := raw_data(c.curr.slots)[int(sid) * ns:]
			next: i32 = -1
			#partial switch s.kind {
			case .Match:
				matched = true
				copy(slots, tslots)
			case .Range:
				if at < end && s.lo <= h[at] && h[at] <= s.hi { next = s.next }
			case .Sparse:
				if at < end {
					// SparseTransitions::matches_byte: the ranges are sorted, so the scan
					// stops at the first one past the byte
					b := h[at]
					for t in prog.trans[s.a:][:s.count] {
						if t.lo > b { break }
						if b <= t.hi { next = t.next; break }
					}
				}
			}
			if s.kind == .Match { break }      // lower priority threads are cut
			if next >= 0 { epsilon_closure(n, c, &c.next, next, tptr, ns, raw_data(h), len(h), at + 1) }
		}
		if earliest && matched { break }
		c.curr, c.next = c.next, c.curr
		if c.curr.len == 0 && matched { break }
	}
	return matched
}
