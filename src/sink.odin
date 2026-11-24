// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// grep-searcher's Sink: what the searcher reports, and the printer that receives it (the
// standard printer, or the summary one for -c, --count-matches, -l, --files-without-match
// and -q). A tagged union in place of ripgrep's trait.

Context_Kind :: enum { Before, After, Other }

Sink_Match :: struct {
	bytes:                []u8,
	absolute_byte_offset: int,
	line_number:          Maybe(int),
	buffer:               []u8,
	range_in_buffer:      Range,
}

Sink_Context :: struct {
	bytes:                []u8,
	kind:                 Context_Kind,
	absolute_byte_offset: int,
	line_number:          Maybe(int),
}

Sink :: union {
	^Standard_Sink,
	^Summary_Sink,
	^JSON_Sink,
}

sink_matched :: proc(sink: ^Sink, s: ^Searcher, m: ^Sink_Match) -> bool {
	switch k in sink^ {
	case ^Standard_Sink: return standard_matched(k, s, m)
	case ^Summary_Sink: return summary_matched(k, s, m)
	case ^JSON_Sink: return json_matched(k, s, m)
	}
	return false
}

sink_context :: proc(sink: ^Sink, s: ^Searcher, c: ^Sink_Context) -> bool {
	switch k in sink^ {
	case ^Standard_Sink: return standard_context(k, s, c)
	case ^Summary_Sink: return true
	case ^JSON_Sink: return json_context(k, s, c)
	}
	return false
}

sink_context_break :: proc(sink: ^Sink, s: ^Searcher) -> bool {
	switch k in sink^ {
	case ^Standard_Sink: return standard_context_break(k, s)
	case ^Summary_Sink, ^JSON_Sink: return true
	}
	return false
}

sink_binary_data :: proc(sink: ^Sink, s: ^Searcher, offset: int) -> bool {
	switch k in sink^ {
	case ^Standard_Sink:
		k.binary_byte_offset = offset
		return true
	case ^Summary_Sink, ^JSON_Sink:
		return true
	}
	return false
}

sink_begin :: proc(sink: ^Sink, s: ^Searcher) -> bool {
	switch k in sink^ {
	case ^Standard_Sink: return standard_begin(k, s)
	case ^Summary_Sink: return summary_begin(k, s)
	case ^JSON_Sink: return json_begin(k, s)
	}
	return false
}

sink_finish :: proc(sink: ^Sink, s: ^Searcher, byte_count: int, binary_byte_offset: Maybe(int)) {
	switch k in sink^ {
	case ^Standard_Sink: standard_finish(k, s, byte_count)
	case ^Summary_Sink: summary_finish(k, s, byte_count, binary_byte_offset)
	case ^JSON_Sink: json_finish(k, s, byte_count, binary_byte_offset)
	}
}

// grep-printer's Stats
Stats :: struct {
	elapsed_ns:          i64,
	searches:            u64,
	searches_with_match: u64,
	bytes_searched:      u64,
	bytes_printed:       u64,
	matched_lines:       u64,
	matches:             u64,
}

stats_add :: proc(a: ^Stats, b: Stats) {
	a.elapsed_ns += b.elapsed_ns
	a.searches += b.searches
	a.searches_with_match += b.searches_with_match
	a.bytes_searched += b.bytes_searched
	a.bytes_printed += b.bytes_printed
	a.matched_lines += b.matched_lines
	a.matches += b.matches
}

// ripgrep's CounterWriter around termcolor: the bytes written since the last reset and in
// total, and whether colour is written at all
Out :: struct {
	buf:           [dynamic]u8,
	count_from:    int,          // len(buf) at reset_count
	total:         int,          // bytes written before the buffer was last cleared
	color:         bool,
	// stdout written as the buffer fills, not per file: ripgrep searching on one thread
	// prints through a block-buffered stdout. Holding a whole file's output instead cost a
	// 524 MiB file with 901,441 matching lines 116,228 page faults and 11 mremaps (rg: 971)
	stream:        bool,
}

OUT_STREAM_AT :: 1 << 16

// the buffer to stdout, as if it were still held: count_from goes back by what left, so
// out_count still measures from reset_count (it can then be negative), and total grows
out_flush :: proc(o: ^Out) {
	write_stdout(o.buf[:])
	o.total += len(o.buf)
	o.count_from -= len(o.buf)
	clear(&o.buf)
}

out_count :: #force_inline proc(o: ^Out) -> int { return len(o.buf) - o.count_from }
out_total :: #force_inline proc(o: ^Out) -> int { return o.total + len(o.buf) }
out_reset_count :: #force_inline proc(o: ^Out) { o.count_from = len(o.buf) }

out_clear :: proc(o: ^Out) {
	o.total += len(o.buf)
	clear(&o.buf)
	o.count_from = 0
}

out_write :: #force_inline proc(o: ^Out, b: []u8) {
	append(&o.buf, ..b)
	if o.stream && len(o.buf) >= OUT_STREAM_AT { out_flush(o) }
}
out_str :: #force_inline proc(o: ^Out, s: string) {
	append(&o.buf, s)
	if o.stream && len(o.buf) >= OUT_STREAM_AT { out_flush(o) }
}

out_set_color :: proc(o: ^Out, spec: Color_Spec) {
	if o.color { write_set_color(&o.buf, spec) }
}

out_reset :: proc(o: ^Out) {
	if o.color { write_reset(&o.buf) }
}

out_spec :: proc(o: ^Out, spec: Color_Spec, b: []u8) {
	out_set_color(o, spec)
	out_write(o, b)
	out_reset(o)
}

out_decimal :: proc(o: ^Out, n: u64) {
	tmp: [20]u8
	i := len(tmp)
	n := n
	for {
		i -= 1
		tmp[i] = '0' + u8(n % 10)
		n /= 10
		if n == 0 { break }
	}
	out_write(o, tmp[i:])
}

// the path as printed: '/' (and '\' on Windows) replaced by --path-separator
printer_path :: proc(path: string, sep: Maybe(u8)) -> []u8 {
	b := transmute([]u8)path
	s, ok := sep.?
	if !ok { return b }
	c := make([]u8, len(b), context.temp_allocator)
	for x, i in b {
		c[i] = s if (x == '/' || (ODIN_OS == .Windows && x == '\\')) else x
	}
	return c
}
