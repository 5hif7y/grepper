// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strconv"

// ripgrep's default colours (its --colors defaults): path magenta, line number green, match
// bold red; each span reset before and after, as ripgrep writes them
COLOR_PATH  :: "\x1b[0m\x1b[35m"
COLOR_LINE  :: "\x1b[0m\x1b[32m"
COLOR_MATCH :: "\x1b[0m\x1b[1m\x1b[31m"
COLOR_RESET :: "\x1b[0m"

FLUSH_AT :: 1 << 16

Printer :: struct {
	buf:           [dynamic]u8,
	color:         bool,
	line_number:   bool,
	with_filename: bool,
	heading:       bool,
	printed_files: int,       // for the blank line between files in heading mode
}

put :: proc(p: ^Printer, s: string) {
	append(&p.buf, s)
}

put_bytes :: proc(p: ^Printer, b: []u8) {
	append(&p.buf, ..b)
}

put_int :: proc(p: ^Printer, n: int) {
	tmp: [32]u8
	put(p, strconv.write_int(tmp[:], i64(n), 10))
}

flush :: proc(p: ^Printer) {
	if len(p.buf) > 0 {
		os.write(os.stdout, p.buf[:])
		clear(&p.buf)
	}
}

maybe_flush :: proc(p: ^Printer) {
	if len(p.buf) >= FLUSH_AT { flush(p) }
}

put_path :: proc(p: ^Printer, path: string) {
	if p.color { put(p, COLOR_PATH) }
	put(p, path)
	if p.color { put(p, COLOR_RESET) }
}

// before a file's first line in heading mode: a blank line after the previous file, the path
begin_file :: proc(p: ^Printer, path: string) {
	if !p.heading || !p.with_filename { return }
	if p.printed_files > 0 { put(p, "\n") }
	put_path(p, path)
	put(p, "\n")
	p.printed_files += 1
}

// one matching line, its matches highlighted: [path:][line:]text\n
print_line :: proc(p: ^Printer, path: string, line_no: int, line: []u8, m: ^Matcher) {
	if p.with_filename && !p.heading {
		put_path(p, path)
		put(p, ":")
	}
	if p.line_number {
		if p.color { put(p, COLOR_LINE) }
		put_int(p, line_no)
		if p.color { put(p, COLOR_RESET) }
		put(p, ":")
	}
	if p.color && m.kind != .Empty {
		at := 0
		for at < len(line) {
			s, e, ok := find(m, line, at, len(line))
			if !ok || e == s { break }
			put_bytes(p, line[at:s])
			put(p, COLOR_MATCH)
			put_bytes(p, line[s:e])
			put(p, COLOR_RESET)
			at = e
		}
		put_bytes(p, line[at:])
	} else {
		put_bytes(p, line)
	}
	put(p, "\n")
	maybe_flush(p)
}

print_count :: proc(p: ^Printer, path: string, n: int) {
	if p.with_filename {
		put_path(p, path)
		put(p, ":")
	}
	put_int(p, n)
	put(p, "\n")
	maybe_flush(p)
}

print_path :: proc(p: ^Printer, path: string) {
	put_path(p, path)
	put(p, "\n")
	maybe_flush(p)
}
