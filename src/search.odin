// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strconv"
import nvol "nvol:odin"

Mode :: enum { Lines, Count, Files }

// The state of one file's search across the ranges it is searched in.
Search :: struct {
	m:       ^Matcher,
	p:       ^Printer,
	path:    string,
	mode:    Mode,
	matched: int,      // matching lines so far
	line_no: int,      // the number of the line starting at `counted`
	counted: int,
	done:    bool,     // -l: the file is listed, nothing more to find
}

// Search buf[from:to) (from a line start, to a line end or the buffer's end) as ripgrep's
// searcher does: find the next match anywhere ahead, then the bounds of its line (memrchr back,
// memchr forward), and count the newlines skipped only when line numbers are printed.
search_range :: proc(st: ^Search, buf: []u8, from, to: int) {
	pos := from
	for pos < to && !st.done {
		s, _, ok := find(st.m, buf, pos, to)
		if !ok { break }
		ls := pos
		if back, found := nvol.memrchr('\n', buf[pos:s]); found { ls = pos + back + 1 }
		le := to
		if fwd, found := nvol.memchr('\n', buf[s:to]); found { le = s + fwd }
		st.matched += 1
		switch st.mode {
		case .Files:
			print_path(st.p, st.path)
			st.done = true
		case .Lines:
			if st.matched == 1 { begin_file(st.p, st.path) }
			if st.p.line_number {
				st.line_no += nvol.count('\n', buf[st.counted:ls])
				st.counted = ls
			}
			print_line(st.p, st.path, st.line_no, buf[ls:le], st.m)
		case .Count:
		}
		pos = le + 1
	}
}

finish :: proc(st: ^Search) -> int {
	if st.mode == .Count && st.matched > 0 {
		print_count(st.p, st.path, st.matched)
	}
	return st.matched
}

// A file searched whole: one given on the command line without a NUL, or any file without one.
search_buffer :: proc(m: ^Matcher, buf: []u8, path: string, p: ^Printer, mode: Mode) -> int {
	st := Search{m = m, p = p, path = path, mode = mode, line_no = 1}
	search_range(&st, buf, 0, len(buf))
	return finish(&st)
}

first_nul :: proc(buf: []u8) -> (at: int, found: bool) {
	return nvol.memchr(0, buf)
}

put_offset_note :: proc(p: ^Printer, path, text: string, offset: int) {
	if p.with_filename {
		put_path(p, path)
		put(p, ": ")
	}
	put(p, text)
	put(p, " (found \"\\0\" byte around offset ")
	tmp: [32]u8
	put(p, strconv.write_int(tmp[:], i64(offset), 10))
	put(p, ")\n")
}

// ripgrep reads a walked file through a 64 KiB line buffer (its searcher's default capacity):
// each fill holds the line cut at the previous fill's end plus the bytes after it, up to the
// capacity; the part up to its last newline is searched, the rest carried over. Before a fill is
// searched, a NUL anywhere in it stops the file (binary detection "quit"): fills before it are
// searched as usual, and if they printed lines, a warning follows them.
RG_BUFFER :: 64 * 1024

search_walked_binary :: proc(m: ^Matcher, buf: []u8, path: string, p: ^Printer, mode: Mode) -> int {
	st := Search{m = m, p = p, path = path, mode = mode, line_no = 1}
	start := 0
	for start < len(buf) && !st.done {
		end := min(start + RG_BUFFER, len(buf))
		stop := end
		if end < len(buf) {
			if nl, found := nvol.memrchr('\n', buf[start:end]); found {
				stop = start + nl + 1
			} else if nl2, found2 := nvol.memchr('\n', buf[end:]); found2 {
				stop = end + nl2 + 1    // a line longer than the buffer: it grows to hold it
				end = stop
			} else {
				stop, end = len(buf), len(buf)
			}
		}
		if nul, found := nvol.memchr(0, buf[start:end]); found {
			if mode == .Lines && st.matched > 0 {
				put_offset_note(p, path, "WARNING: stopped searching binary file after match", start + nul)
			}
			if mode == .Count {         // ripgrep prints no count for a file it stopped
				return st.matched
			}
			break
		}
		search_range(&st, buf, start, stop)
		start = stop
	}
	return finish(&st)
}

// A file given on the command line with a NUL: searched; where lines would be printed, one
// line stands for them all, with the first NUL's offset (-c and -l as any other file).
search_explicit_binary :: proc(m: ^Matcher, buf: []u8, nul: int, path: string, p: ^Printer, mode: Mode) -> int {
	if mode != .Lines {
		return search_buffer(m, buf, path, p, mode)
	}
	if _, _, ok := find(m, buf, 0, len(buf)); !ok {
		return 0
	}
	put_offset_note(p, path, "binary file matches", nul)
	return 1
}
