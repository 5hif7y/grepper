// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"

// aho-corasick's noncontiguous NFA (1.1.5, nfa/noncontiguous.rs) with leftmost-first match
// semantics, as regex-automata builds it for a large alternation of literals
// (Pre::from_alternation_literals, 3000 literals or more) and as the prefilter choice's
// fallback when Teddy refuses a set (util/prefilter/aho_corasick.rs). No SIMD: the literal
// kernels it would use as its own prefilter are off there too (prefilter(false)).
//
// The build, as upstream:
// - a trie of the patterns in order; with leftmost-first, a pattern is not added past the
//   point where an earlier pattern already matched on its path (it can never win);
// - the unanchored start state loops to itself on every byte it has no transition for;
// - failure transitions, breadth first; with leftmost semantics a match state's failure is
//   the dead state (a match is never given up for a later one);
// - when the start state itself matches (an empty pattern), its self loops go to the dead
//   state.
// States of depth below AC_DENSE_DEPTH get a dense row of 256 transitions (densify).

AC_DEAD :: i32(0)
AC_FAIL :: i32(1)
AC_START :: i32(2)
AC_DENSE_DEPTH :: 2

Ac_Trans :: struct {
	b:    u8,
	next: i32,
}

Ac_State :: struct {
	sparse: [dynamic]Ac_Trans,   // sorted by byte
	dense:  i32,                 // index of its row in Aho.dense, or -1
	fail:   i32,
	depth:  int,
	pid:    i32,                 // the first (highest priority) pattern it matches, or -1
}

Aho :: struct {
	states:   [dynamic]Ac_State,
	dense:    [dynamic]i32,      // rows of 256
	lens:     []int,             // each pattern's length
	min_len:  int,
	// AhoCorasickKind::DFA, which regex-automata picks up to 500 patterns: every state's
	// 256 transitions resolved through the failure transitions, one lookup per byte. An
	// entry is the target's row offset (premultiplied); a match state's is negative,
	// -(offset + 1), and the dead state is AC_DFA_DEAD, so the hot loop tests one sign
	dfa:      []i32,             // nil: search the NFA
	dfa_pid:  []i32,             // the first pattern each state matches, or -1
}

AC_DFA_DEAD :: min(i32)

AC_DFA_MAX_PATTERNS :: 500

@(private="file")
ac_follow :: #force_inline proc(a: ^Aho, sid: i32, b: u8) -> i32 {
	st := &a.states[sid]
	if st.dense >= 0 { return a.dense[int(st.dense) + int(b)] }
	for t in st.sparse {
		if t.b >= b { return t.next if t.b == b else AC_FAIL }
	}
	return AC_FAIL
}

@(private="file")
ac_alloc :: proc(a: ^Aho, depth: int) -> i32 {
	append(&a.states, Ac_State{dense = -1, fail = AC_START, depth = depth, pid = -1})
	return i32(len(a.states) - 1)
}

@(private="file")
ac_add_trans :: proc(a: ^Aho, from: i32, b: u8, to: i32) {
	st := &a.states[from]
	i, found := slice.binary_search_by(st.sparse[:], b, proc(t: Ac_Trans, x: u8) -> slice.Ordering {
		return slice.cmp(t.b, x)
	})
	if found { st.sparse[i].next = to; return }
	inject_at(&st.sparse, i, Ac_Trans{b, to})
}

// leftmost-first; not ok when there are no patterns
aho_build :: proc(patterns: [][]u8) -> (a: ^Aho, ok: bool) {
	if len(patterns) == 0 { return }
	a = new(Aho)
	// the dead state loops to itself; the fail sentinel; the unanchored start state
	append(&a.states, Ac_State{dense = -1, fail = AC_DEAD, pid = -1})
	append(&a.states, Ac_State{dense = -1, fail = AC_DEAD, pid = -1})
	ac_alloc(a, 0)
	a.lens = make([]int, len(patterns))
	a.min_len = max(int)
	patterns_loop: for pat, pid in patterns {
		a.lens[pid] = len(pat)
		a.min_len = min(a.min_len, len(pat))
		prev := AC_START
		saw_match := false
		for b, depth in pat {
			saw_match = saw_match || a.states[prev].pid >= 0
			if saw_match { continue patterns_loop }
			next := ac_follow(a, prev, b)
			if next != AC_FAIL {
				prev = next
			} else {
				nxt := ac_alloc(a, depth + 1)
				ac_add_trans(a, prev, b, nxt)
				prev = nxt
			}
		}
		if a.states[prev].pid < 0 { a.states[prev].pid = i32(pid) }
	}
	// the start state's missing transitions loop back to it
	for b in 0 ..< 256 {
		if ac_follow(a, AC_START, u8(b)) == AC_FAIL { ac_add_trans(a, AC_START, u8(b), AC_START) }
	}
	// add_dead_state_loop: the dead state goes to itself on every byte. A match state can
	// have children (pattern `abc` before `ab`), and their failure search starts from its
	// failure, the dead state, which must not be a dead end of the failure walk
	{
		row := len(a.dense)
		resize(&a.dense, row + 256)
		for k in row ..< row + 256 { a.dense[k] = AC_DEAD }
		a.states[AC_DEAD].dense = i32(row)
	}
	// densify: rows for the shallow states (the start state is always one)
	for &st, sid in a.states {
		if sid < int(AC_START) || st.depth >= AC_DENSE_DEPTH { continue }
		row := len(a.dense)
		// doubling, not one row at a time (Odin's resize sets the capacity to the length)
		if row + 256 > cap(a.dense) { reserve(&a.dense, max(row + 256, 2 * cap(a.dense))) }
		resize(&a.dense, row + 256)
		for k in row ..< row + 256 { a.dense[k] = AC_FAIL }
		for t in st.sparse { a.dense[row + int(t.b)] = t.next }
		st.dense = i32(row)
	}
	// failure transitions, breadth first from the start state's children
	queue: [dynamic]i32
	defer delete(queue)
	seen := make([]bool, len(a.states))
	defer delete(seen)
	for t in a.states[AC_START].sparse {
		if t.next == AC_START || seen[t.next] { continue }
		append(&queue, t.next)
		seen[t.next] = true
		if a.states[t.next].pid >= 0 { a.states[t.next].fail = AC_DEAD }
	}
	for head := 0; head < len(queue); head += 1 {
		id := queue[head]
		for t in a.states[id].sparse {
			if seen[t.next] { continue }
			append(&queue, t.next)
			seen[t.next] = true
			if a.states[t.next].pid >= 0 {
				a.states[t.next].fail = AC_DEAD
				continue
			}
			fail := a.states[id].fail
			for ac_follow(a, fail, t.b) == AC_FAIL { fail = a.states[fail].fail }
			fail = ac_follow(a, fail, t.b)
			a.states[t.next].fail = fail
			// copy_matches: with leftmost semantics the state has none of its own here, and
			// only its first match is ever reported
			if a.states[t.next].pid < 0 { a.states[t.next].pid = a.states[fail].pid }
		}
	}
	// close_start_state_loop_for_leftmost
	if a.states[AC_START].pid >= 0 {
		st := &a.states[AC_START]
		for &t in st.sparse {
			if t.next == AC_START {
				t.next = AC_DEAD
				a.dense[int(st.dense) + int(t.b)] = AC_DEAD
			}
		}
	}
	if len(patterns) <= AC_DFA_MAX_PATTERNS { ac_build_dfa(a, queue[:]) }
	return a, true
}

// the DFA's rows in breadth-first order (the dead state, the start state, then the order the
// failure transitions were filled in): a transition the NFA lacks is the one its failure
// state's row, computed before it, has for the byte (dfa.rs's nfa_next_state_memoized)
@(private="file")
ac_build_dfa :: proc(a: ^Aho, bfs: []i32) {
	n := len(a.states)
	a.dfa = make([]i32, n * 256)
	a.dfa_pid = make([]i32, n)
	for st, i in a.states { a.dfa_pid[i] = st.pid }
	for b in 0 ..< 256 {
		a.dfa[int(AC_DEAD) * 256 + b] = AC_DEAD
		a.dfa[int(AC_FAIL) * 256 + b] = AC_DEAD
		a.dfa[int(AC_START) * 256 + b] = ac_follow(a, AC_START, u8(b))
	}
	for sid in bfs {
		row := int(sid) * 256
		frow := int(a.states[sid].fail) * 256
		for b in 0 ..< 256 {
			next := ac_follow(a, sid, u8(b))
			a.dfa[row + b] = next if next != AC_FAIL else a.dfa[frow + b]
		}
	}
	// encode the targets
	for &t in a.dfa {
		switch {
		case t == AC_DEAD: t = AC_DFA_DEAD
		case a.dfa_pid[t] >= 0: t = -(t * 256) - 1
		case: t = t * 256
		}
	}
}

// try_find_fwd, unanchored, leftmost-first: the first match in h[start:end)
aho_find :: proc(a: ^Aho, h: []u8, start, end: int) -> (r: Range, ok: bool) {
	sid := AC_START
	mat := Range{-1, -1}
	if a.states[sid].pid >= 0 { mat = {start, start} }
	if a.dfa != nil {
		dfa := a.dfa
		cur := int(AC_START) * 256
		#no_bounds_check for at := start; at < end; at += 1 {
			next := dfa[cur + int(h[at])]
			if next >= 0 { cur = int(next); continue }
			if next == AC_DFA_DEAD { break }
			cur = int(-next - 1)
			pid := a.dfa_pid[cur / 256]
			mat = {at + 1 - a.lens[pid], at + 1}
		}
		if mat.start < 0 { return }
		return mat, true
	}
	#no_bounds_check for at := start; at < end; at += 1 {
		b := h[at]
		for {
			next := ac_follow(a, sid, b)
			if next != AC_FAIL { sid = next; break }
			sid = a.states[sid].fail
		}
		if sid == AC_DEAD { break }
		if pid := a.states[sid].pid; pid >= 0 {
			mat = {at + 1 - a.lens[pid], at + 1}
		}
	}
	if mat.start < 0 { return }
	return mat, true
}
