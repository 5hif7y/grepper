// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import nvol "nvol:odin"

// grep-searcher (crates/searcher): the line buffer, the core that reports matching and
// context lines to a sink, and the three strategies over it (read by line through the roll
// buffer, a whole slice by line, multi line). Ported from ripgrep 14.1.1's line_buffer.rs,
// searcher/core.rs and searcher/glue.rs; the order of every check is theirs, since the output
// (which lines, which binary warning) depends on it.

DEFAULT_BUFFER_CAPACITY :: 64 * 1024

Searcher :: struct {
	line_term:        u8,
	crlf:             bool,
	invert_match:     bool,
	line_number:      bool,
	multi_line:       bool,
	after_context:    int,
	before_context:   int,
	passthru:         bool,
	stop_on_nonmatch: bool,
	binary:           Binary_Detection,
	mmap:             bool,
}

max_context :: proc(s: ^Searcher) -> int { return max(s.before_context, s.after_context) }

// ---------------------------------------------------------------------------------------------
// Line buffer (line_buffer.rs). Two sources: a file already read whole, whose "reads" are views
// of it (each the size a read(2) of the free space would return), or a handle read for real
// (stdin, pipes). Either way the fills, rolls and binary detection are ripgrep's.

Line_Buffer :: struct {
	// virtual mode: the window [base, base + cap) of mem; reader mode: buf
	mem:      []u8,
	base:     int,
	cap:      int,
	buf:      [dynamic]u8,
	handle:   ^os.File,
	eof_seen: bool,

	pos, last_lineterm, end: int,
	absolute_byte_offset: int,
	binary_byte_offset:   Maybe(int),
	binary:   Binary_Detection,
	lineterm: u8,
}

lb_window :: #force_inline proc(lb: ^Line_Buffer) -> []u8 {
	if lb.mem != nil { return lb.mem[lb.base:lb.base + min(lb.cap, len(lb.mem) - lb.base)] }
	return lb.buf[:]
}

lb_buffer :: #force_inline proc(lb: ^Line_Buffer) -> []u8 {
	if lb.mem != nil { return lb.mem[lb.base + lb.pos:lb.base + lb.last_lineterm] }
	return lb.buf[lb.pos:lb.last_lineterm]
}

lb_consume :: proc(lb: ^Line_Buffer, amt: int) {
	lb.pos += amt
	lb.absolute_byte_offset += amt
}

lb_roll :: proc(lb: ^Line_Buffer) {
	if lb.pos == lb.end {
		if lb.mem != nil { lb.base += lb.pos }
		lb.pos, lb.last_lineterm, lb.end = 0, 0, 0
		return
	}
	roll_len := lb.end - lb.pos
	if lb.mem != nil {
		lb.base += lb.pos
	} else {
		copy(lb.buf[:roll_len], lb.buf[lb.pos:lb.end])
	}
	lb.pos = 0
	lb.last_lineterm = roll_len
	lb.end = roll_len
}

// read into the free space after end; returns the number of bytes read
lb_read :: proc(lb: ^Line_Buffer) -> (n: int, err: os.Error) {
	if lb.mem != nil {
		if lb.end == lb.cap {      // ensure_capacity: Eager, len * 2 more
			lb.cap += max(1, lb.cap) * 2
		}
		avail := len(lb.mem) - (lb.base + lb.end)
		return max(0, min(lb.cap - lb.end, avail)), nil
	}
	if lb.end == len(lb.buf) {
		resize(&lb.buf, len(lb.buf) + max(1, len(lb.buf)) * 2)
	}
	if lb.eof_seen { return 0, nil }
	n, err = os.read(lb.handle, lb.buf[lb.end:])
	if err == .EOF || err == .Broken_Pipe { err = nil }
	if n == 0 { lb.eof_seen = true }
	return
}

lb_bytes :: #force_inline proc(lb: ^Line_Buffer, from, to: int) -> []u8 {
	if lb.mem != nil { return lb.mem[lb.base + from:lb.base + to] }
	return lb.buf[from:to]
}

// fill: false at EOF (or, with Quit, once binary data was seen and the buffer is used up)
lb_fill :: proc(lb: ^Line_Buffer) -> (more: bool, err: os.Error) {
	if lb.binary.kind == .Quit && lb.binary_byte_offset != nil {
		return len(lb_buffer(lb)) > 0, nil
	}
	lb_roll(lb)
	for {
		readlen := lb_read(lb) or_return
		if readlen == 0 {
			lb.last_lineterm = lb.end
			return len(lb_buffer(lb)) > 0, nil
		}
		oldend := lb.end
		lb.end += readlen
		newbytes := lb_bytes(lb, oldend, lb.end)
		switch lb.binary.kind {
		case .None:
		case .Quit:
			if i, found := nvol.memchr(lb.binary.byte, newbytes); found {
				lb.end = oldend + i
				lb.last_lineterm = lb.end
				lb.binary_byte_offset = lb.absolute_byte_offset + lb.end
				return lb.pos < lb.end, nil
			}
		case .Convert:
			if i, found := replace_bytes(newbytes, lb.binary.byte, lb.lineterm); found {
				if lb.binary_byte_offset == nil {
					lb.binary_byte_offset = lb.absolute_byte_offset + oldend + i
				}
			}
		}
		if i, found := nvol.memrchr(lb.lineterm, newbytes); found {
			lb.last_lineterm = oldend + i + 1
			return true, nil
		}
	}
}

// every src byte replaced with replacement; the offset of the first
replace_bytes :: proc(bytes: []u8, src, replacement: u8) -> (first: int, found: bool) {
	if src == replacement { return }
	first = nvol.memchr(src, bytes) or_return
	bytes[first] = replacement
	rest := bytes[first + 1:]
	for {
		i := nvol.memchr(src, rest) or_break
		rest[i] = replacement
		rest = rest[i + 1:]
	}
	return first, true
}

// ---------------------------------------------------------------------------------------------
// Core (searcher/core.rs)

Core :: struct {
	s:                    ^Searcher,
	m:                    ^Matcher,
	sink:                 ^Sink,
	binary:               bool,       // check each sunk range for binary data (slices)
	pos:                  int,
	absolute_byte_offset: int,
	binary_byte_offset:   Maybe(int),
	line_number:          Maybe(int),
	last_line_counted:    int,
	last_line_visited:    int,
	after_context_left:   int,
	has_sunk:             bool,
	has_matched:          bool,
}

core_new :: proc(s: ^Searcher, m: ^Matcher, sink: ^Sink, binary: bool) -> (c: Core) {
	c.s, c.m, c.sink, c.binary = s, m, sink, binary
	if s.line_number { c.line_number = 1 }
	return
}

core_roll :: proc(c: ^Core, buf: []u8) -> int {
	consumed := len(buf)
	if max_context(c.s) > 0 {
		context_start := preceding(buf, c.s.line_term, max_context(c.s))
		consumed = max(context_start, c.last_line_visited)
	}
	core_count_lines(c, buf, consumed)
	c.absolute_byte_offset += consumed
	c.last_line_counted = 0
	c.last_line_visited = 0
	c.pos = len(buf) - consumed
	return consumed
}

core_detect_binary :: proc(c: ^Core, buf: []u8, r: Range) -> bool {
	if c.binary_byte_offset != nil {
		return c.s.binary.kind == .Quit
	}
	if c.s.binary.kind == .None { return false }
	if i, found := nvol.memchr(c.s.binary.byte, buf[r.start:r.end]); found {
		offset := r.start + i
		c.binary_byte_offset = offset
		if !sink_binary_data(c.sink, c.s, offset) { return true }
		return c.s.binary.kind == .Quit
	}
	return false
}

core_before_context_by_line :: proc(c: ^Core, buf: []u8, upto: int) -> bool {
	if c.s.before_context == 0 { return true }
	r := Range{c.last_line_visited, upto}
	if range_empty(r) { return true }
	start := r.start + preceding(buf[r.start:r.end], c.s.line_term, c.s.before_context - 1)
	st := Line_Step{c.s.line_term, start, r.end}
	for {
		line := line_step_next(&st, buf) or_break
		if !core_sink_break_context(c, line.start) { return false }
		if !core_sink_before_context(c, buf, line) { return false }
	}
	return true
}

core_after_context_by_line :: proc(c: ^Core, buf: []u8, upto: int) -> bool {
	if c.after_context_left == 0 { return true }
	st := Line_Step{c.s.line_term, c.last_line_visited, upto}
	for {
		line := line_step_next(&st, buf) or_break
		if !core_sink_after_context(c, buf, line) { return false }
		if c.after_context_left == 0 { break }
	}
	return true
}

core_other_context_by_line :: proc(c: ^Core, buf: []u8, upto: int) -> bool {
	st := Line_Step{c.s.line_term, c.last_line_visited, upto}
	for {
		line := line_step_next(&st, buf) or_break
		if !core_sink_other_context(c, buf, line) { return false }
	}
	return true
}

core_match_by_line :: proc(c: ^Core, buf: []u8) -> bool {
	if core_is_line_by_line_fast(c) {
		switch core_match_by_line_fast(c, buf) {
		case .Switch_To_Slow: return core_match_by_line_slow(c, buf)
		case .Continue: return true
		case .Stop: return false
		}
	}
	return core_match_by_line_slow(c, buf)
}

core_match_by_line_slow :: proc(c: ^Core, buf: []u8) -> bool {
	st := Line_Step{c.s.line_term, c.pos, len(buf)}
	for {
		line := line_step_next(&st, buf) or_break
		slice := without_terminator(buf[line.start:line.end], c.s.line_term, c.s.crlf)
		matched := matcher_is_match(c.m, slice)
		c.pos = line.end
		success := matched != c.s.invert_match
		if success {
			c.has_matched = true
			if !core_before_context_by_line(c, buf, line.start) { return false }
			if !core_sink_matched(c, buf, line) { return false }
		} else if c.after_context_left >= 1 {
			if !core_sink_after_context(c, buf, line) { return false }
		} else if c.s.passthru {
			if !core_sink_other_context(c, buf, line) { return false }
		}
		if c.s.stop_on_nonmatch && !success && c.has_matched { return false }
	}
	return true
}

Fast_Result :: enum { Continue, Stop, Switch_To_Slow }

core_match_by_line_fast :: proc(c: ^Core, buf: []u8) -> Fast_Result {
	for c.pos < len(buf) {
		if c.s.stop_on_nonmatch && c.has_matched { return .Switch_To_Slow }
		if c.s.invert_match {
			if !core_match_by_line_fast_invert(c, buf) { return .Stop }
		} else if line, ok := core_find_by_line_fast(c, buf); ok {
			c.has_matched = true
			if max_context(c.s) > 0 {
				if !core_after_context_by_line(c, buf, line.start) { return .Stop }
				if !core_before_context_by_line(c, buf, line.start) { return .Stop }
			}
			c.pos = line.end
			if !core_sink_matched(c, buf, line) { return .Stop }
		} else {
			break
		}
	}
	if !core_after_context_by_line(c, buf, len(buf)) { return .Stop }
	c.pos = len(buf)
	return .Continue
}

core_match_by_line_fast_invert :: proc(c: ^Core, buf: []u8) -> bool {
	invert: Range
	if line, ok := core_find_by_line_fast(c, buf); ok {
		invert = {c.pos, line.start}
		c.pos = line.end
	} else {
		invert = {c.pos, len(buf)}
		c.pos = invert.end
	}
	if range_empty(invert) { return true }
	c.has_matched = true
	if !core_after_context_by_line(c, buf, invert.start) { return false }
	if !core_before_context_by_line(c, buf, invert.start) { return false }
	st := Line_Step{c.s.line_term, invert.start, invert.end}
	for {
		line := line_step_next(&st, buf) or_break
		if !core_sink_matched(c, buf, line) { return false }
	}
	return true
}

core_find_by_line_fast :: proc(c: ^Core, buf: []u8) -> (line: Range, ok: bool) {
	pos := c.pos
	for pos < len(buf) {
		i, confirmed, found := matcher_find_candidate_line(c.m, buf[pos:])
		if !found { return }
		line = locate(buf, c.s.line_term, {pos + i, pos + i})
		if confirmed {
			if line.start == len(buf) {
				pos = len(buf)
				continue
			}
			return line, true
		}
		slice := without_terminator(buf[line.start:line.end], c.s.line_term, c.s.crlf)
		if matcher_is_match(c.m, slice) { return line, true }
		pos = line.end
	}
	return
}

core_sink_matched :: proc(c: ^Core, buf: []u8, r: Range) -> bool {
	if c.binary && core_detect_binary(c, buf, r) { return false }
	if !core_sink_break_context(c, r.start) { return false }
	core_count_lines(c, buf, r.start)
	sm := Sink_Match{
		bytes = buf[r.start:r.end],
		absolute_byte_offset = c.absolute_byte_offset + r.start,
		line_number = c.line_number,
		buffer = buf,
		range_in_buffer = r,
	}
	if !sink_matched(c.sink, c.s, &sm) { return false }
	c.last_line_visited = r.end
	c.after_context_left = c.s.after_context
	c.has_sunk = true
	return true
}

core_sink_context :: proc(c: ^Core, buf: []u8, r: Range, kind: Context_Kind) -> bool {
	if c.binary && core_detect_binary(c, buf, r) { return false }
	core_count_lines(c, buf, r.start)
	sc := Sink_Context{
		bytes = buf[r.start:r.end],
		kind = kind,
		absolute_byte_offset = c.absolute_byte_offset + r.start,
		line_number = c.line_number,
	}
	if !sink_context(c.sink, c.s, &sc) { return false }
	c.last_line_visited = r.end
	c.has_sunk = true
	return true
}

core_sink_before_context :: proc(c: ^Core, buf: []u8, r: Range) -> bool {
	return core_sink_context(c, buf, r, .Before)
}

core_sink_after_context :: proc(c: ^Core, buf: []u8, r: Range) -> bool {
	if !core_sink_context(c, buf, r, .After) { return false }
	c.after_context_left -= 1
	return true
}

core_sink_other_context :: proc(c: ^Core, buf: []u8, r: Range) -> bool {
	return core_sink_context(c, buf, r, .Other)
}

core_sink_break_context :: proc(c: ^Core, start_of_line: int) -> bool {
	is_gap := c.last_line_visited < start_of_line
	any_context := c.s.before_context > 0 || c.s.after_context > 0
	if !any_context || !c.has_sunk || !is_gap { return true }
	return sink_context_break(c.sink, c.s)
}

core_count_lines :: proc(c: ^Core, buf: []u8, upto: int) {
	n, ok := c.line_number.?
	if !ok { return }
	if c.last_line_counted >= upto { return }
	n += count_lines_in(buf[c.last_line_counted:upto], c.s.line_term)
	c.line_number = n
	c.last_line_counted = upto
}

core_is_line_by_line_fast :: proc(c: ^Core) -> bool {
	if c.s.passthru { return false }
	if c.s.stop_on_nonmatch && c.has_matched { return false }
	if !c.m.line_term { return false }
	// the matcher's line terminator: \n (ripgrep sets it outside multi line mode); NUL
	// (--null-data) disables the fast path, as ripgrep's FIXME
	if c.s.line_term == 0 { return false }
	return c.s.line_term == '\n'
}

// ---------------------------------------------------------------------------------------------
// The strategies (glue.rs)

// a reader through the roll buffer
read_by_line :: proc(s: ^Searcher, m: ^Matcher, lb: ^Line_Buffer, sink: ^Sink) -> (err: os.Error) {
	c := core_new(s, m, sink, false)
	if sink_begin(sink, s) {
		for {
			more := rbl_fill(&c, lb) or_return
			if !more { break }
			if !core_match_by_line(&c, lb_buffer(lb)) {
				// the bytes the core got through count as searched when it stops early (fix
				// over 14.1.1, ripgrep 15.0.0's #2944: --no-mmap -m1 --stats said 0 bytes)
				lb_consume(lb, c.pos)
				break
			}
		}
	}
	sink_finish(sink, s, lb.absolute_byte_offset, lb.binary_byte_offset)
	return nil
}

rbl_fill :: proc(c: ^Core, lb: ^Line_Buffer) -> (more: bool, err: os.Error) {
	already_binary := lb.binary_byte_offset != nil
	old_buf_len := len(lb_buffer(lb))
	consumed := core_roll(c, lb_buffer(lb))
	lb_consume(lb, consumed)
	didread := lb_fill(lb) or_return
	if !already_binary {
		if offset, ok := lb.binary_byte_offset.?; ok {
			if !sink_binary_data(c.sink, c.s, offset) { return false, nil }
		}
	}
	if !didread || (lb.binary_byte_offset != nil && c.s.binary.kind == .Quit) {
		return false, nil
	}
	if consumed == 0 && old_buf_len == len(lb_buffer(lb)) {
		lb_consume(lb, old_buf_len)
		return false, nil
	}
	return true, nil
}

// a whole slice (a memory map in ripgrep), binary data looked for in its first 64 KiB and
// in every range sunk
slice_by_line :: proc(s: ^Searcher, m: ^Matcher, slice: []u8, sink: ^Sink) {
	c := core_new(s, m, sink, true)
	if sink_begin(sink, s) {
		binary_upto := min(len(slice), DEFAULT_BUFFER_CAPACITY)
		if !core_detect_binary(&c, slice, {0, binary_upto}) {
			for c.pos < len(slice) && core_match_by_line(&c, slice) {}
		}
	}
	byte_count := c.pos
	if off, ok := c.binary_byte_offset.?; ok && off < c.pos { byte_count = off }
	sink_finish(sink, s, byte_count, c.binary_byte_offset)
}
