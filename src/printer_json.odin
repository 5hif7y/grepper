// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:fmt"
import "core:time"
import nvol "nvol:odin"

// grep-printer's JSON Lines printer (crates/printer/src/json.rs and jsont.rs, ripgrep
// 14.1.1): begin, match, context and end messages per file, as serde_json writes them. Text
// that is not valid UTF-8 goes as base64 under "bytes".

JSON_Printer :: struct {
	max_matches: Maybe(u64),
	out:         Out,
	matches:     [dynamic]Range,
}

JSON_Sink :: struct {
	p:                       ^JSON_Printer,
	m:                       ^Matcher,
	path:                    string,
	start:                   time.Tick,
	match_count:             u64,
	after_context_remaining: u64,
	begin_printed:           bool,
	stats:                   Stats,
}

json_sink_with_path :: proc(p: ^JSON_Printer, m: ^Matcher, path: string) -> JSON_Sink {
	return {p = p, m = m, path = path}
}

json_has_match :: proc(s: ^JSON_Sink) -> bool { return s.match_count > 0 }

json_record_matches :: proc(s: ^JSON_Sink, searcher: ^Searcher, bytes: []u8, r: Range) {
	clear(&s.p.matches)
	find_iter_at_in_context(searcher, s.m, bytes, r, &s.p.matches, r.start)
	ms := s.p.matches[:]
	// as ripgrep: the relative start against the length of the whole buffer
	if len(ms) > 0 && range_empty(ms[len(ms) - 1]) && ms[len(ms) - 1].start >= len(bytes) {
		pop(&s.p.matches)
	}
}

json_should_quit :: proc(s: ^JSON_Sink) -> bool {
	limit, ok := s.p.max_matches.?
	if !ok || s.match_count < limit { return false }
	return s.after_context_remaining == 0
}

json_write_begin :: proc(s: ^JSON_Sink) {
	if s.begin_printed { return }
	o := &s.p.out
	out_str(o, `{"type":"begin","data":{"path":`)
	json_data_text(o, s.path)
	out_str(o, "}}\n")
	s.begin_printed = true
}

json_matched :: proc(s: ^JSON_Sink, searcher: ^Searcher, mat: ^Sink_Match) -> bool {
	json_write_begin(s)
	s.match_count += 1
	if limit, ok := s.p.max_matches.?; ok && s.match_count > limit {
		if s.after_context_remaining > 0 { s.after_context_remaining -= 1 }
	} else {
		s.after_context_remaining = u64(searcher.after_context)
	}
	json_record_matches(s, searcher, mat.buffer, mat.range_in_buffer)
	s.stats.matches += u64(len(s.p.matches))
	s.stats.matched_lines += u64(count_lines_of(mat.bytes, searcher.line_term))
	json_write_match_messages(s, searcher, mat)
	return !json_should_quit(s)
}

// One "match" message per run of lines that no submatch crosses: a multi line block of
// several matches is split at the line ends between them, each message with its own lines,
// line number, offset and submatches. Fix over 14.1.1 (ripgrep 16.0.0's #1983/#3364), which
// wrote the whole block as one message. A single line is one message, as before.
json_write_match_messages :: proc(s: ^JSON_Sink, searcher: ^Searcher, mat: ^Sink_Match) {
	all := s.p.matches[:]
	rest := 0           // the first submatch not yet written
	start, end := 0, 0
	line_number := mat.line_number
	st := Line_Step{searcher.line_term, 0, len(mat.bytes)}
	line_index := 0
	for {
		line := line_step_next(&st, mat.bytes) or_break
		end += line.end - line.start
		k := rest
		for k < len(all) && all[k].start < end { k += 1 }
		if k > rest && all[k - 1].end > end {
			// a submatch runs into the next line: keep going
			line_index += 1
			continue
		}
		cur := make([]Range, k - rest, context.temp_allocator)
		for m, j in all[rest:k] { cur[j] = {m.start - start, m.end - start} }
		json_write_lines(s, "match", mat.bytes[start:end], line_number, mat.absolute_byte_offset + start, cur)
		rest = k
		start = end
		if n, ok := mat.line_number.?; ok { line_number = n + line_index + 1 }
		line_index += 1
	}
}

json_context :: proc(s: ^JSON_Sink, searcher: ^Searcher, ctx: ^Sink_Context) -> bool {
	json_write_begin(s)
	clear(&s.p.matches)
	if ctx.kind == .After && s.after_context_remaining > 0 {
		s.after_context_remaining -= 1
	}
	sub: []Range
	if searcher.invert_match {
		json_record_matches(s, searcher, ctx.bytes, {0, len(ctx.bytes)})
		sub = s.p.matches[:]
	}
	json_write_lines(s, "context", ctx.bytes, ctx.line_number, ctx.absolute_byte_offset, sub)
	return !json_should_quit(s)
}

json_write_lines :: proc(s: ^JSON_Sink, kind: string, lines: []u8, line_number: Maybe(int), offset: int, sub: []Range) {
	o := &s.p.out
	out_str(o, `{"type":"`)
	out_str(o, kind)
	out_str(o, `","data":{"path":`)
	json_data_text(o, s.path)
	out_str(o, `,"lines":`)
	json_data(o, lines)
	out_str(o, `,"line_number":`)
	if n, ok := line_number.?; ok { out_decimal(o, u64(n)) } else { out_str(o, "null") }
	out_str(o, `,"absolute_offset":`)
	out_decimal(o, u64(offset))
	out_str(o, `,"submatches":[`)
	for m, i in sub {
		if i > 0 { out_str(o, ",") }
		out_str(o, `{"match":`)
		json_data(o, lines[m.start:m.end])
		out_str(o, `,"start":`)
		out_decimal(o, u64(m.start))
		out_str(o, `,"end":`)
		out_decimal(o, u64(m.end))
		out_str(o, "}")
	}
	out_str(o, "]}}\n")
}

json_begin :: proc(s: ^JSON_Sink, searcher: ^Searcher) -> bool {
	out_reset_count(&s.p.out)
	s.start = time.tick_now()
	s.match_count = 0
	s.after_context_remaining = 0
	if limit, ok := s.p.max_matches.?; ok && limit == 0 { return false }
	return true
}

json_finish :: proc(s: ^JSON_Sink, searcher: ^Searcher, byte_count: int, binary_byte_offset: Maybe(int)) {
	s.stats.elapsed_ns += i64(time.tick_since(s.start))
	s.stats.searches += 1
	if s.match_count > 0 { s.stats.searches_with_match += 1 }
	s.stats.bytes_searched += u64(byte_count)
	s.stats.bytes_printed += u64(out_count(&s.p.out))
	// a search that printed nothing still counts in the summary (fix over 14.1.1, ripgrep
	// 15.0.0's #3178: 14.1.1 returned before tallying it)
	if !s.begin_printed { return }
	o := &s.p.out
	out_str(o, `{"type":"end","data":{"path":`)
	json_data_text(o, s.path)
	out_str(o, `,"binary_offset":`)
	if b, ok := binary_byte_offset.?; ok { out_decimal(o, u64(b)) } else { out_str(o, "null") }
	out_str(o, `,"stats":`)
	json_stats(o, s.stats)
	out_str(o, "}}\n")
}

json_stats :: proc(o: ^Out, st: Stats) {
	out_str(o, `{"elapsed":`)
	json_duration(o, st.elapsed_ns)
	out_str(o, `,"searches":`)
	out_decimal(o, st.searches)
	out_str(o, `,"searches_with_match":`)
	out_decimal(o, st.searches_with_match)
	out_str(o, `,"bytes_searched":`)
	out_decimal(o, st.bytes_searched)
	out_str(o, `,"bytes_printed":`)
	out_decimal(o, st.bytes_printed)
	out_str(o, `,"matched_lines":`)
	out_decimal(o, st.matched_lines)
	out_str(o, `,"matches":`)
	out_decimal(o, st.matches)
	out_str(o, "}")
}

// NiceDuration: {"secs":..,"nanos":..,"human":"0.000000s"}
json_duration :: proc(o: ^Out, ns: i64) {
	out_str(o, `{"secs":`)
	out_decimal(o, u64(ns / 1_000_000_000))
	out_str(o, `,"nanos":`)
	out_decimal(o, u64(ns % 1_000_000_000))
	out_str(o, `,"human":"`)
	write_seconds(o, ns)
	out_str(o, `s"}`)
}

// seconds with six decimals, as Rust's {:0.6}
write_seconds :: proc(o: ^Out, ns: i64) {
	buf: [64]u8
	out_str(o, fmt.bprintf(buf[:], "%.6f", f64(ns) / 1e9))
}

// {"text":"..."} for UTF-8, else {"bytes":"<base64>"}
json_data :: proc(o: ^Out, b: []u8) {
	if utf8_valid(b) {
		out_str(o, `{"text":`)
		json_string(o, b)
		out_str(o, "}")
		return
	}
	out_str(o, `{"bytes":"`)
	base64_standard(o, b)
	out_str(o, `"}`)
}

json_data_text :: proc(o: ^Out, path: string) {
	out_str(o, `{"text":`)
	json_string(o, transmute([]u8)path)
	out_str(o, "}")
}

// serde_json's string escaping: \" \\ \b \f \n \r \t, other controls as \u00xx
json_string :: proc(o: ^Out, b: []u8) {
	hex := "0123456789abcdef"
	out_str(o, `"`)
	start := 0
	for c, i in b {
		esc: string
		switch c {
		case '"': esc = `\"`
		case '\\': esc = `\\`
		case 0x08: esc = `\b`
		case 0x0C: esc = `\f`
		case '\n': esc = `\n`
		case '\r': esc = `\r`
		case '\t': esc = `\t`
		case 0 ..= 0x1F:
		case: continue
		}
		out_write(o, b[start:i])
		if esc != "" {
			out_str(o, esc)
		} else {
			out_write(o, []u8{'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]})
		}
		start = i + 1
	}
	out_write(o, b[start:])
	out_str(o, `"`)
}

base64_standard :: proc(o: ^Out, b: []u8) {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	i := 0
	for ; i + 3 <= len(b); i += 3 {
		g := uint(b[i]) << 16 | uint(b[i + 1]) << 8 | uint(b[i + 2])
		out_write(o, []u8{alphabet[(g >> 18) & 63], alphabet[(g >> 12) & 63], alphabet[(g >> 6) & 63], alphabet[g & 63]})
	}
	switch len(b) - i {
	case 1:
		g := uint(b[i])
		out_write(o, []u8{alphabet[(g >> 2) & 63], alphabet[(g << 4) & 63], '=', '='})
	case 2:
		g := uint(b[i]) << 8 | uint(b[i + 1])
		out_write(o, []u8{alphabet[(g >> 10) & 63], alphabet[(g >> 4) & 63], alphabet[(g << 2) & 63], '='})
	}
}

// Rust's str::from_utf8: NVOL's first_non_ascii skips the ASCII run, the rest is checked
// byte by byte (overlongs, surrogates and code points past U+10FFFF rejected)
utf8_valid :: proc(b: []u8) -> bool {
	i := 0
	for i < len(b) {
		k, found := nvol.first_non_ascii(b[i:])
		if !found { return true }
		i += k
		c := b[i]
		n := 0
		lo, hi: u8 = 0x80, 0xBF
		switch c {
		case 0xC2 ..= 0xDF: n = 1
		case 0xE0: n = 2; lo = 0xA0
		case 0xE1 ..= 0xEC, 0xEE ..= 0xEF: n = 2
		case 0xED: n = 2; hi = 0x9F
		case 0xF0: n = 3; lo = 0x90
		case 0xF1 ..= 0xF3: n = 3
		case 0xF4: n = 3; hi = 0x8F
		case: return false
		}
		if i + n >= len(b) { return false }
		if b[i + 1] < lo || b[i + 1] > hi { return false }
		for k2 in 2 ..= n {
			if b[i + k2] < 0x80 || b[i + k2] > 0xBF { return false }
		}
		i += n + 1
	}
	return true
}
