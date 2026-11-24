// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import nvol "nvol:odin"

// grep-searcher's lines.rs: line stepping and location over a buffer, with NVOL's memchr,
// memrchr and count in place of the memchr crate.

Range :: struct {
	start, end: int,
}

range_empty :: #force_inline proc(r: Range) -> bool { return r.start >= r.end }

Line_Step :: struct {
	term: u8,
	pos:  int,
	end:  int,
}

// the next line in bytes[pos:end), its terminator included; the last line may lack one
line_step_next :: proc(s: ^Line_Step, bytes: []u8) -> (r: Range, ok: bool) {
	b := bytes[:s.end]
	if i, found := nvol.memchr(s.term, b[s.pos:]); found {
		r = {s.pos, s.pos + i + 1}
		s.pos = r.end
		return r, true
	}
	if s.pos < len(b) {
		r = {s.pos, len(b)}
		s.pos = r.end
		return r, true
	}
	return
}

count_lines_in :: #force_inline proc(bytes: []u8, term: u8) -> int {
	return nvol.count(term, bytes)
}

// the line without its terminator (CRLF: "\r\n" when crlf, else "\n")
without_terminator :: proc(bytes: []u8, term: u8, crlf: bool) -> []u8 {
	if crlf {
		if len(bytes) >= 2 && bytes[len(bytes) - 2] == '\r' && bytes[len(bytes) - 1] == '\n' {
			return bytes[:len(bytes) - 2]
		}
		return bytes
	}
	if len(bytes) >= 1 && bytes[len(bytes) - 1] == term {
		return bytes[:len(bytes) - 1]
	}
	return bytes
}

// the whole lines containing r
locate :: proc(bytes: []u8, term: u8, r: Range) -> Range {
	line_start := 0
	if i, found := nvol.memrchr(term, bytes[:r.start]); found { line_start = i + 1 }
	line_end: int
	if r.end > line_start && bytes[r.end - 1] == term {
		line_end = r.end
	} else if i, found := nvol.memchr(term, bytes[r.end:]); found {
		line_end = r.end + i + 1
	} else {
		line_end = len(bytes)
	}
	return {line_start, line_end}
}

// the start of the line `count` lines before the last one in bytes (lines::preceding)
preceding :: proc(bytes: []u8, term: u8, count: int) -> int {
	pos := len(bytes)
	count := count
	if pos == 0 { return 0 }
	if bytes[pos - 1] == term { pos -= 1 }
	for {
		i, found := nvol.memrchr(term, bytes[:pos])
		if !found { return 0 }
		if count == 0 { return i + 1 }
		if i == 0 { return 0 }
		count -= 1
		pos = i
	}
}
