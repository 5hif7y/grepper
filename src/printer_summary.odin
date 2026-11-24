// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:time"

// grep-printer's summary printer (crates/printer/src/summary.rs, ripgrep 14.1.1): -c,
// --count-matches, -l, --files-without-match and -q.

// Quiet is two kinds, as in ripgrep 15.0.0 (#3108): 14.1.1 had one, which reported a match
// as -l does even under --files-without-match, so `-q --files-without-match` exited 0 when
// every file matched and 1 when one did not.
Summary_Kind :: enum { Count, Count_Matches, Path_With_Match, Path_Without_Match, Quiet_With_Match, Quiet_Without_Match }

Summary_Config :: struct {
	kind:            Summary_Kind,
	colors:          Color_Specs,
	exclude_zero:    bool,
	max_matches:     Maybe(u64),
	path:            bool,
	path_terminator: Maybe(u8),
	separator_field: string,
	separator_path:  Maybe(u8),
	stats:           bool,
}

Summary_Printer :: struct {
	config: Summary_Config,
	out:    Out,
}

Summary_Sink :: struct {
	p:                  ^Summary_Printer,
	m:                  ^Matcher,
	path:               Maybe([]u8),
	match_count:        u64,
	binary_byte_offset: Maybe(int),
	has_stats:          bool,
	stats:              Stats,
	start:              time.Tick,
}

summary_sink_with_path :: proc(p: ^Summary_Printer, m: ^Matcher, path: string) -> (s: Summary_Sink) {
	s.p = p
	s.m = m
	requires_path := p.config.kind == .Path_With_Match || p.config.kind == .Path_Without_Match
	s.has_stats = p.config.stats || p.config.kind == .Count_Matches
	if !p.config.path && !requires_path { return }
	s.path = printer_path(path, p.config.separator_path)
	return
}

summary_has_match :: proc(s: ^Summary_Sink) -> bool {
	if s.p.config.kind == .Path_Without_Match || s.p.config.kind == .Quiet_Without_Match { return s.match_count == 0 }
	return s.match_count > 0
}

summary_matched :: proc(s: ^Summary_Sink, searcher: ^Searcher, mat: ^Sink_Match) -> bool {
	sink_match_count: u64 = 1
	is_multi_line := multi_line_with_matcher(searcher, s.m)
	if s.has_stats || is_multi_line {
		ms: [dynamic]Range
		ms.allocator = context.temp_allocator
		find_iter_at_in_context(searcher, s.m, mat.buffer, mat.range_in_buffer, &ms, 0)
		sink_match_count = u64(len(ms))
	}
	// a multi line match counts each match in it (for --count-matches)
	s.match_count += sink_match_count if is_multi_line else 1
	if s.has_stats {
		s.stats.matches += sink_match_count
		s.stats.matched_lines += u64(count_lines_of(mat.bytes, searcher.line_term))
	} else if s.p.config.kind == .Path_With_Match || s.p.config.kind == .Quiet_With_Match {
		return false
	}
	limit, ok := s.p.config.max_matches.?
	return !(ok && s.match_count >= limit)
}

summary_begin :: proc(s: ^Summary_Sink, searcher: ^Searcher) -> bool {
	out_reset_count(&s.p.out)
	s.start = time.tick_now()
	s.match_count = 0
	s.binary_byte_offset = nil
	if limit, ok := s.p.config.max_matches.?; ok && limit == 0 { return false }
	return true
}

summary_finish :: proc(s: ^Summary_Sink, searcher: ^Searcher, byte_count: int, binary_byte_offset: Maybe(int)) {
	s.binary_byte_offset = binary_byte_offset
	if s.has_stats {
		s.stats.elapsed_ns += i64(time.tick_since(s.start))
		s.stats.searches += 1
		if s.match_count > 0 { s.stats.searches_with_match += 1 }
		s.stats.bytes_searched += u64(byte_count)
		s.stats.bytes_printed += u64(out_count(&s.p.out))
	}
	// binary data with Quit: no result at all, whatever was found before it
	if s.binary_byte_offset != nil && searcher.binary.kind == .Quit {
		s.match_count = 0
		return
	}
	out := &s.p.out
	show_count := !s.p.config.exclude_zero || s.match_count > 0
	write_path :: proc(s: ^Summary_Sink) {
		if path, ok := s.path.?; ok {
			out_spec(&s.p.out, s.p.config.colors.path, path)
		}
	}
	write_line_term :: proc(s: ^Summary_Sink, searcher: ^Searcher) {
		if searcher.crlf {
			out_str(&s.p.out, "\r\n")
		} else {
			out_write(&s.p.out, []u8{searcher.line_term})
		}
	}
	write_path_field :: proc(s: ^Summary_Sink) {
		if s.path == nil { return }
		write_path(s)
		if t, ok := s.p.config.path_terminator.?; ok {
			out_write(&s.p.out, []u8{t})
		} else {
			out_str(&s.p.out, s.p.config.separator_field)
		}
	}
	write_path_line :: proc(s: ^Summary_Sink, searcher: ^Searcher) {
		if s.path == nil { return }
		write_path(s)
		if t, ok := s.p.config.path_terminator.?; ok {
			out_write(&s.p.out, []u8{t})
		} else {
			write_line_term(s, searcher)
		}
	}
	switch s.p.config.kind {
	case .Count:
		if show_count {
			write_path_field(s)
			out_decimal(out, s.match_count)
			write_line_term(s, searcher)
		}
	case .Count_Matches:
		if show_count {
			write_path_field(s)
			out_decimal(out, s.stats.matches)
			write_line_term(s, searcher)
		}
	case .Path_With_Match:
		if s.match_count > 0 { write_path_line(s, searcher) }
	case .Path_Without_Match:
		if s.match_count == 0 { write_path_line(s, searcher) }
	case .Quiet_With_Match, .Quiet_Without_Match:
	}
}
