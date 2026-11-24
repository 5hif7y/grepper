// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// -r/--replace: grep-printer's Replacer (crates/printer/src/util.rs) and grep-matcher's
// interpolate (crates/matcher/src/interpolate.rs), ripgrep 14.1.1, with ripgrep 15.0.0's
// #3100: the line terminator trimmed before matching is put back after the replacement
// (14.1.1 dropped it, and the printer then added the searcher's own, so with --crlf a line
// ending in a bare \n came out ending in \r\n).

Replacer :: struct {
	dst:     [dynamic]u8,
	matches: [dynamic]Range,      // each replacement's place in dst
}

replacer_clear :: proc(r: ^Replacer) {
	clear(&r.dst)
	clear(&r.matches)
}

// the replaced bytes and their match ranges; none when nothing was replaced
replacer_result :: proc(r: ^Replacer) -> (dst: []u8, matches: []Range, ok: bool) {
	if len(r.matches) == 0 { return }
	return r.dst[:], r.matches[:], true
}

// Replacer::replace_all over bytes[range] (one line or one context line, multi line mode
// aside): every match starting before range.end replaced by the interpolated replacement
replacer_replace_all :: proc(r: ^Replacer, searcher: ^Searcher, m: ^Matcher, bytes: []u8, range: Range, replacement: string) {
	replacer_clear(r)
	// the line terminator, trimmed so look-around cannot see it, then put back
	end := range.end
	if end > 0 && bytes[end - 1] == searcher.line_term {
		end -= 1
		if searcher.crlf && end > 0 && bytes[end - 1] == '\r' { end -= 1 }
	}
	term := bytes[end:range.end]
	hay := bytes[:end]
	// replace_with_captures_in_context over captures_iter_at
	last := range.start
	last_end := range.start
	last_match := -1
	for last_end <= len(hay) {
		if !matcher_captures_at(m, hay, last_end) { break }
		g0, _ := matcher_group(m, 0)
		if g0.start == g0.end {
			last_end = g0.end + 1
			if g0.end == last_match { continue }
		} else {
			last_end = g0.end
		}
		last_match = g0.end
		if g0.start >= range.end { break }
		append(&r.dst, ..hay[last:g0.start])
		last = g0.end
		start := len(r.dst)
		interpolate(r, m, hay, replacement)
		append(&r.matches, Range{start, len(r.dst)})
	}
	append(&r.dst, ..hay[last:min(len(hay), range.end)])
	append(&r.dst, ..term)
}

// Captures::interpolate: `$$` is `$`; `$N`, `$name` and `${...}` are a capture group's text
// (nothing when the group did not take part or does not exist); a `$` not followed by a
// capture reference is itself. Names are runs of [0-9A-Za-z_]; one that parses as a u32 is
// a group number, so `$1a` is the group named "1a".
@(private="file")
interpolate :: proc(r: ^Replacer, m: ^Matcher, hay: []u8, replacement: string) {
	rep := transmute([]u8)replacement
	for len(rep) > 0 {
		i := index_byte(rep, '$')
		if i < 0 { break }
		append(&r.dst, ..rep[:i])
		rep = rep[i:]
		if len(rep) > 1 && rep[1] == '$' {
			append(&r.dst, '$')
			rep = rep[2:]
			continue
		}
		name, ref_end, ok := find_cap_ref(rep)
		if !ok {
			append(&r.dst, '$')
			rep = rep[1:]
			continue
		}
		rep = rep[ref_end:]
		if idx, found := capture_index(m, name); found {
			if g, took_part := matcher_group(m, idx); took_part {
				append(&r.dst, ..hay[g.start:g.end])
			}
		}
	}
	append(&r.dst, ..rep)
}

@(private="file")
index_byte :: proc(s: []u8, b: u8) -> int {
	for c, i in s { if c == b { return i } }
	return -1
}

@(private="file")
find_cap_ref :: proc(rep: []u8) -> (name: string, end: int, ok: bool) {
	if len(rep) <= 1 || rep[0] != '$' { return }
	i := 1
	brace := false
	if rep[i] == '{' {
		brace = true
		i += 1
	}
	cap_end := i
	for cap_end < len(rep) && is_valid_cap_letter(rep[cap_end]) { cap_end += 1 }
	if cap_end == i { return }
	name = string(rep[i:cap_end])
	if brace {
		if cap_end >= len(rep) || rep[cap_end] != '}' { return }
		cap_end += 1
	}
	return name, cap_end, true
}

@(private="file")
is_valid_cap_letter :: proc(b: u8) -> bool {
	switch b {
	case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '_': return true
	}
	return false
}

// a reference's group index: a name that parses as a u32 is a number (it may name no
// group); any other is looked up among the regex's group names
@(private="file")
capture_index :: proc(m: ^Matcher, name: string) -> (idx: int, ok: bool) {
	n: u64 = 0
	numeric := true
	for c in transmute([]u8)name {
		if c < '0' || c > '9' { numeric = false; break }
		n = n * 10 + u64(c - '0')
		if n > u64(max(u32)) { numeric = false; break }
	}
	if numeric { return int(n), true }
	if m.kind != .Pike { return }
	for g, i in m.nfa.group_names {
		if gn, has := g.?; has && gn == name { return i, true }
	}
	return
}
