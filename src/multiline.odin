// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// -U/--multiline, ripgrep 14.1.1: grep-searcher's MultiLine strategy (glue.rs) over the whole
// haystack in memory, the decision of when it is needed (Searcher::multi_line_with_matcher),
// and grep-regex's non_matching_bytes, which lets a multi line search whose regex can never
// match a line terminator run line by line instead.

// the bytes no match of h can contain (non_matching.rs); look-around only removes the bytes
// its line anchors look at
non_matching_bytes :: proc(h: ^Hir) -> (set: [256]bool) {
	for &b in set { b = true }
	remove_matching_bytes(h, &set)
	return
}

@(private="file")
remove_matching_bytes :: proc(h: ^Hir, set: ^[256]bool) {
	switch h.kind {
	case .Empty:
	case .Look:
		#partial switch h.look {
		case .Start, .End, .Start_LF, .End_LF:
			set['\n'] = false
		case .Start_CRLF, .End_CRLF:
			set['\r'] = false
			set['\n'] = false
		}
	case .Literal:
		for b in h.lit { set[b] = false }
	case .Class:
		if h.class.unicode {
			seqs: [dynamic]Utf8_Sequence
			seqs.allocator = context.temp_allocator
			for r in h.class.ranges {
				clear(&seqs)
				utf8_sequences(r.lo, r.hi, &seqs)
				for seq in seqs {
					for k in 0 ..< seq.n {
						for b := int(seq.ranges[k].lo); b <= int(seq.ranges[k].hi); b += 1 { set[b] = false }
					}
				}
			}
		} else {
			for r in h.class.ranges {
				for b := r.lo; b <= r.hi; b += 1 { set[b] = false }
			}
		}
	case .Repetition, .Capture:
		remove_matching_bytes(h.sub, set)
	case .Concat, .Alternation:
		for s in h.subs { remove_matching_bytes(s, set) }
	}
}

// Searcher::multi_line_with_matcher: multi line mode, and a matcher that may match across
// the line terminator
multi_line_with_matcher :: proc(s: ^Searcher, m: ^Matcher) -> bool {
	if !s.multi_line { return false }
	if m.line_term { return false }
	if m.non_matching[s.line_term] { return false }
	return true
}

// the most bytes past a match's last line the printers let the regex see when they find the
// matches again inside it (MAX_LOOK_AHEAD in grep-printer)
MAX_LOOK_AHEAD :: 128

// find_iter_at_in_context: every match starting in bytes[r], ranges relative to rel. In
// multi line mode the regex sees up to MAX_LOOK_AHEAD bytes past r; otherwise the line's
// terminator is trimmed, so that look-around cannot see it.
find_iter_at_in_context :: proc(searcher: ^Searcher, m: ^Matcher, bytes: []u8, r: Range, out: ^[dynamic]Range, rel: int) {
	hay := bytes
	if multi_line_with_matcher(searcher, m) {
		if len(bytes) - r.end >= MAX_LOOK_AHEAD { hay = bytes[:r.end + MAX_LOOK_AHEAD] }
	} else {
		end := r.end
		if end > 0 && bytes[end - 1] == searcher.line_term {
			end -= 1
			if searcher.crlf && end > 0 && bytes[end - 1] == '\r' { end -= 1 }
		}
		hay = bytes[:end]
	}
	find_iter_at(m, hay, r.start, r.end, out, rel)
}

// glue.rs's MultiLine: matches found over the whole slice, the lines holding a match joined
// with those of the next match when they touch, then sunk as one match.
//
// -m counts matches here, not sunk blocks: fix over 14.1.1 (ripgrep 15.0.0's #2094/#3076),
// where -m limited the blocks the printer saw, and a block joins every match whose lines
// touch, so `rg -U -m1 '^'` printed the whole file. ripgrep fixed it by moving the limit from
// the printer to the searcher in every mode (a6e0be3), which also changed line mode and
// brought the regressions of PARITY's #3593, R16-1 and R16-2; grepper counts matches only in
// this multi line search and keeps 14.1.1's line mode.
multi_line_search :: proc(s: ^Searcher, m: ^Matcher, slice: []u8, sink: ^Sink) {
	c := core_new(s, m, sink, true)
	c.ml_count = 0
	last_match: Maybe(Range)
	if sink_begin(sink, s) {
		binary_upto := min(len(slice), DEFAULT_BUFFER_CAPACITY)
		if !core_detect_binary(&c, slice, {0, binary_upto}) {
			keepgoing := true
			for c.pos < len(slice) && keepgoing {
				keepgoing = ml_sink(&c, slice, &last_match)
			}
			if keepgoing {
				if lm, ok := last_match.?; ok {
					last_match = nil
					if ml_sink_context(&c, slice, lm) { ml_sink_matched(&c, slice, lm) }
				}
				if s.passthru {
					core_other_context_by_line(&c, slice, len(slice))
				} else {
					core_after_context_by_line(&c, slice, len(slice))
				}
			}
		}
	}
	byte_count := c.pos
	if off, ok := c.binary_byte_offset.?; ok && off < c.pos { byte_count = off }
	sink_finish(sink, s, byte_count, c.binary_byte_offset)
}

@(private="file")
ml_sink :: proc(c: ^Core, slice: []u8, last_match: ^Maybe(Range)) -> bool {
	if c.s.invert_match { return ml_sink_matched_inverted(c, slice) }
	mat, found := ml_find(c, slice)
	if !found {
		c.pos = len(slice)
		return true
	}
	ml_advance(c, slice, mat)
	line := locate(slice, c.s.line_term, mat)
	lm, had := last_match^.?
	if !had {
		last_match^ = line
		return true
	}
	// a match whose lines touch the previous one's (they may overlap, as two matches can
	// share a line) joins it
	if lm.end >= line.start {
		last_match^ = Range{lm.start, line.end}
		return true
	}
	last_match^ = line
	if !ml_sink_context(c, slice, lm) { return false }
	return ml_sink_matched(c, slice, lm)
}

@(private="file")
ml_sink_matched_inverted :: proc(c: ^Core, slice: []u8) -> bool {
	invert: Range
	if mat, found := ml_find(c, slice); found {
		line := locate(slice, c.s.line_term, mat)
		invert = {c.pos, line.start}
		ml_advance(c, slice, line)
	} else {
		invert = {c.pos, len(slice)}
		c.pos = invert.end
	}
	if range_empty(invert) { return true }
	if !ml_sink_context(c, slice, invert) { return false }
	st := Line_Step{c.s.line_term, invert.start, invert.end}
	for {
		line := line_step_next(&st, slice) or_break
		if !ml_sink_matched(c, slice, line) { return false }
	}
	return true
}

@(private="file")
ml_sink_matched :: proc(c: ^Core, slice: []u8, r: Range) -> bool {
	if range_empty(r) { return false }
	return core_sink_matched(c, slice, r)
}

@(private="file")
ml_sink_context :: proc(c: ^Core, slice: []u8, r: Range) -> bool {
	if c.s.passthru {
		return core_other_context_by_line(c, slice, r.start)
	}
	if !core_after_context_by_line(c, slice, r.start) { return false }
	return core_before_context_by_line(c, slice, r.start)
}

// the first match in slice[pos:], as an absolute range; none once -m matches were found
@(private="file")
ml_find :: proc(c: ^Core, slice: []u8) -> (r: Range, ok: bool) {
	if limit, has := c.s.max_matches.?; has && !c.s.invert_match && c.ml_count >= limit { return }
	sub := slice[c.pos:]
	s, e := find(c.m, sub, 0, len(sub)) or_return
	c.ml_count += 1
	return {c.pos + s, c.pos + e}, true
}

@(private="file")
ml_advance :: proc(c: ^Core, slice: []u8, r: Range) {
	c.pos = r.end
	if range_empty(r) && c.pos < len(slice) { c.pos += 1 }
}
