// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import nvol "nvol:odin"

// ripgrep's binary detection when searching (its default `--binary` heuristic for files found
// by the walk): a NUL byte in the first 8 KiB means the file is skipped
BINARY_PROBE :: 8192

is_binary :: proc(buf: []u8) -> bool {
	_, found := nvol.memchr(0, buf[:min(len(buf), BINARY_PROBE)])
	return found
}

Mode :: enum { Lines, Count, Files }

// Search one file's bytes as ripgrep's searcher does on a whole buffer: find the next match
// anywhere ahead, then the bounds of its line (memrchr back, memchr forward), and count the
// newlines skipped only when line numbers are printed. Returns the number of matching lines.
search_buffer :: proc(m: ^Matcher, buf: []u8, path: string, p: ^Printer, mode: Mode) -> int {
	matched := 0
	pos := 0                    // always the start of a line
	line_no := 1
	counted := 0                // line_no is the number of the line starting at `counted`
	for pos < len(buf) || (pos == 0 && len(buf) == 0 && m.kind == .Empty) {
		s, _, ok := find(m, buf, pos, len(buf))
		if !ok { break }
		ls := pos
		if back, found := nvol.memrchr('\n', buf[pos:s]); found {
			ls = pos + back + 1
		}
		le := len(buf)
		if fwd, found := nvol.memchr('\n', buf[s:]); found {
			le = s + fwd
		}
		matched += 1
		if mode == .Files {
			print_path(p, path)
			return matched
		}
		if mode == .Lines {
			if matched == 1 { begin_file(p, path) }
			if p.line_number {
				line_no += nvol.count('\n', buf[counted:ls])
				counted = ls
			}
			print_line(p, path, line_no, buf[ls:le], m)
		}
		pos = le + 1
		if len(buf) == 0 { break }
	}
	if mode == .Count && matched > 0 {
		print_count(p, path, matched)
	}
	return matched
}
