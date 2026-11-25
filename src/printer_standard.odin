// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:time"

// grep-printer's standard printer (crates/printer/src/standard.rs, ripgrep 14.1.1): matching
// and context lines with their prelude (path, line number, column, byte offset), colours,
// -o, --vimgrep, -M, --trim, context and file separators, and the binary data messages.
// Multi line output (-U) and hyperlinks are not ported yet.

Standard_Config :: struct {
	colors:                  Color_Specs,
	heading:                 bool,
	path:                    bool,
	only_matching:           bool,
	per_match:               bool,
	per_match_one_line:      bool,
	replacement:             Maybe(string),
	max_columns:             Maybe(u64),
	max_columns_preview:     bool,
	max_matches:             Maybe(u64),
	column:                  bool,
	byte_offset:             bool,
	trim_ascii:              bool,
	separator_search:        Maybe(string),
	separator_context:       Maybe(string),
	separator_field_match:   string,
	separator_field_context: string,
	separator_path:          Maybe(u8),
	path_terminator:         Maybe(u8),
	stats:                   bool,
}

Standard_Printer :: struct {
	config:   Standard_Config,
	out:      Out,
	matches:  [dynamic]Range,
	replacer: Replacer,
}

Standard_Sink :: struct {
	p:                       ^Standard_Printer,
	m:                       ^Matcher,
	path:                    Maybe([]u8),
	match_count:             u64,
	after_context_remaining: u64,
	binary_byte_offset:      Maybe(int),
	stats:                   Stats,
	start:                   time.Tick,
	needs_match_granularity: bool,
}

standard_needs_match_granularity :: proc(p: ^Standard_Printer) -> bool {
	match_colored := !color_spec_is_none(p.config.colors.matched)
	return (p.out.color && match_colored) || p.config.column || p.config.replacement != nil ||
		p.config.per_match || p.config.only_matching || p.config.stats
}

standard_sink_with_path :: proc(p: ^Standard_Printer, m: ^Matcher, path: string) -> (s: Standard_Sink) {
	s.p = p
	s.m = m
	if p.config.path { s.path = printer_path(path, p.config.separator_path) }
	s.needs_match_granularity = standard_needs_match_granularity(p)
	return
}

standard_has_match :: proc(s: ^Standard_Sink) -> bool { return s.match_count > 0 }

// every match in bytes[range] (the line terminator excluded), as find_iter_at_in_context
record_matches :: proc(s: ^Standard_Sink, searcher: ^Searcher, bytes: []u8, r: Range) {
	clear(&s.p.matches)
	if !s.needs_match_granularity { return }
	find_iter_at_in_context(searcher, s.m, bytes, r, &s.p.matches, r.start)
	ms := s.p.matches[:]
	// ripgrep compares the stored (relative) start with the absolute end
	if len(ms) > 0 && range_empty(ms[len(ms) - 1]) && ms[len(ms) - 1].start >= r.end {
		pop(&s.p.matches)
	}
}

// grep-matcher's find_iter_at: each match starting before limit, ranges stored relative to
// rel; an empty match moves the search one byte on and is skipped right after a match
find_iter_at :: proc(m: ^Matcher, hay: []u8, at, limit: int, out: ^[dynamic]Range, rel: int) {
	last_end := at
	last_match := -1
	for last_end <= len(hay) {
		mt, ok := matcher_find_at(m, hay, last_end)
		if !ok { return }
		if mt.start == mt.end {
			last_end = mt.end + 1
			if mt.end == last_match { continue }
		} else {
			last_end = mt.end
		}
		last_match = mt.end
		if mt.start >= limit { return }
		append(out, Range{mt.start - rel, mt.end - rel})
	}
}

// StandardSink::replace: the replacement of bytes[r] when -r is given
standard_replace :: proc(s: ^Standard_Sink, searcher: ^Searcher, bytes: []u8, r: Range) {
	replacer_clear(&s.p.replacer)
	rep, ok := s.p.config.replacement.?
	if !ok { return }
	replacer_replace_all(&s.p.replacer, searcher, s.m, bytes, r, rep)
}

standard_should_quit :: proc(s: ^Standard_Sink) -> bool {
	limit, ok := s.p.config.max_matches.?
	if !ok || s.match_count < limit { return false }
	return s.after_context_remaining == 0
}

standard_match_more_than_limit :: proc(s: ^Standard_Sink) -> bool {
	limit, ok := s.p.config.max_matches.?
	return ok && s.match_count > limit
}

standard_matched :: proc(s: ^Standard_Sink, searcher: ^Searcher, mat: ^Sink_Match) -> bool {
	s.match_count += 1
	if standard_match_more_than_limit(s) {
		if s.after_context_remaining > 0 { s.after_context_remaining -= 1 }
	} else {
		s.after_context_remaining = u64(searcher.after_context)
	}
	record_matches(s, searcher, mat.buffer, mat.range_in_buffer)
	standard_replace(s, searcher, mat.buffer, mat.range_in_buffer)
	if s.p.config.stats {
		s.stats.matches += u64(len(s.p.matches))
		s.stats.matched_lines += u64(count_lines_of(mat.bytes, searcher.line_term))
	}
	if searcher.binary.kind == .Convert && s.binary_byte_offset != nil {
		return false
	}
	impl := Std_Impl{
		s = s, searcher = searcher,
		bytes = mat.bytes,
		absolute_byte_offset = mat.absolute_byte_offset,
		line_number = mat.line_number,
		matches = s.p.matches[:],
		multi_line = multi_line_with_matcher(searcher, s.m),
	}
	if dst, ms, ok := replacer_result(&s.p.replacer); ok { impl.bytes, impl.matches = dst, ms }
	std_sink(&impl)
	return !standard_should_quit(s)
}

// lines in bytes, as grep-searcher's LineIter counts them (a last line without terminator
// counts)
count_lines_of :: proc(bytes: []u8, term: u8) -> int {
	n := count_lines_in(bytes, term)
	if len(bytes) > 0 && bytes[len(bytes) - 1] != term { n += 1 }
	return n
}

standard_context :: proc(s: ^Standard_Sink, searcher: ^Searcher, ctx: ^Sink_Context) -> bool {
	clear(&s.p.matches)
	replacer_clear(&s.p.replacer)
	if ctx.kind == .After && s.after_context_remaining > 0 {
		s.after_context_remaining -= 1
	}
	if searcher.invert_match {
		record_matches(s, searcher, ctx.bytes, {0, len(ctx.bytes)})
		standard_replace(s, searcher, ctx.bytes, {0, len(ctx.bytes)})
	}
	if searcher.binary.kind == .Convert && s.binary_byte_offset != nil {
		return false
	}
	impl := Std_Impl{
		s = s, searcher = searcher,
		bytes = ctx.bytes,
		absolute_byte_offset = ctx.absolute_byte_offset,
		line_number = ctx.line_number,
		is_context = true,
		matches = s.p.matches[:],
		multi_line = multi_line_with_matcher(searcher, s.m),
	}
	if dst, ms, ok := replacer_result(&s.p.replacer); ok { impl.bytes, impl.matches = dst, ms }
	std_sink(&impl)
	return !standard_should_quit(s)
}

standard_context_break :: proc(s: ^Standard_Sink, searcher: ^Searcher) -> bool {
	impl := Std_Impl{s = s, searcher = searcher}
	std_write_context_separator(&impl)
	return true
}

standard_begin :: proc(s: ^Standard_Sink, searcher: ^Searcher) -> bool {
	out_reset_count(&s.p.out)
	// the clock only for --stats: one clock_gettime per file otherwise (8,903 on /usr/include)
	if s.p.config.stats { s.start = time.tick_now() }
	s.match_count = 0
	s.after_context_remaining = 0
	s.binary_byte_offset = nil
	if limit, ok := s.p.config.max_matches.?; ok && limit == 0 { return false }
	return true
}

standard_finish :: proc(s: ^Standard_Sink, searcher: ^Searcher, byte_count: int) {
	if offset, ok := s.binary_byte_offset.?; ok {
		impl := Std_Impl{s = s, searcher = searcher}
		std_write_binary_message(&impl, offset)
	}
	if s.p.config.stats {
		s.stats.elapsed_ns += i64(time.tick_since(s.start))
		s.stats.searches += 1
		if s.match_count > 0 { s.stats.searches_with_match += 1 }
		s.stats.bytes_searched += u64(byte_count)
		s.stats.bytes_printed += u64(out_count(&s.p.out))
	}
}

// StandardImpl: one matching or context line being printed
Std_Impl :: struct {
	s:                    ^Standard_Sink,
	searcher:             ^Searcher,
	bytes:                []u8,
	absolute_byte_offset: int,
	line_number:          Maybe(int),
	is_context:           bool,
	matches:              []Range,
	in_color_match:       bool,
	multi_line:           bool,     // StandardImpl::multi_line: the matcher may span lines
}

@(private="file")
cfg :: #force_inline proc(i: ^Std_Impl) -> ^Standard_Config { return &i.s.p.config }

@(private="file")
w :: #force_inline proc(i: ^Std_Impl, b: []u8) { out_write(&i.s.p.out, b) }

@(private="file")
ws :: #force_inline proc(i: ^Std_Impl, b: string) { out_str(&i.s.p.out, b) }

std_sink :: proc(i: ^Std_Impl) {
	std_write_search_prelude(i)
	if len(i.matches) == 0 {
		if i.multi_line && !i.is_context { std_sink_fast_multi_line(i) } else { std_sink_fast(i) }
	} else {
		if i.multi_line && !i.is_context { std_sink_slow_multi_line(i) } else { std_sink_slow(i) }
	}
}

// a multi line match with no match ranges: each of its lines with its own prelude
std_sink_fast_multi_line :: proc(i: ^Std_Impl) {
	offset := i.absolute_byte_offset
	st := Line_Step{i.searcher.line_term, 0, len(i.bytes)}
	k := 0
	for {
		line := line_step_next(&st, i.bytes) or_break
		ln: Maybe(int)
		if n, ok := i.line_number.?; ok { ln = n + k }
		std_write_prelude(i, offset, ln, nil)
		offset += line.end - line.start
		std_write_line(i, i.bytes[line.start:line.end])
		k += 1
	}
}

std_sink_slow_multi_line :: proc(i: ^Std_Impl) {
	if cfg(i).only_matching {
		std_sink_slow_multi_line_only_matching(i)
		return
	} else if cfg(i).per_match {
		std_sink_slow_multi_per_match(i)
		return
	}
	bytes, matches := i.bytes, i.matches
	midx := 0
	count := 0
	st := Line_Step{i.searcher.line_term, 0, len(bytes)}
	for {
		line := line_step_next(&st, bytes) or_break
		ln: Maybe(int)
		if n, ok := i.line_number.?; ok { ln = n + count }
		std_write_prelude(i, i.absolute_byte_offset + line.start, ln, matches[0].start + 1)
		count += 1
		line = std_trim_ascii_prefix(i, bytes, line)
		if std_exceeds_max_columns(i, bytes[line.start:line.end]) {
			std_write_exceeded_line(i, bytes, line, matches, &midx)
		} else {
			std_write_colored_matches(i, bytes, line, matches, &midx)
			std_write_line_term(i)
		}
	}
}

std_sink_slow_multi_line_only_matching :: proc(i: ^Std_Impl) {
	spec := cfg(i).colors.matched
	bytes, matches := i.bytes, i.matches
	midx := 0
	count := 0
	st := Line_Step{i.searcher.line_term, 0, len(bytes)}
	for {
		line := line_step_next(&st, bytes) or_break
		line = trim_line_terminator(i.searcher, bytes, line)
		line = std_trim_ascii_prefix(i, bytes, line)
		for !range_empty(line) {
			if matches[midx].end <= line.start {
				if midx + 1 < len(matches) {
					midx += 1
					continue
				}
				break
			}
			m := matches[midx]
			if line.start < m.start {
				line.start = min(line.end, m.start)
			} else {
				upto := min(line.end, m.end)
				ln: Maybe(int)
				if n, ok := i.line_number.?; ok { ln = n + count }
				std_write_prelude(i, i.absolute_byte_offset + m.start, ln, m.start + 1)
				this_line := Range{line.start, upto}
				line.start = upto
				if std_exceeds_max_columns(i, bytes[this_line.start:this_line.end]) {
					std_write_exceeded_line(i, bytes, this_line, matches, &midx)
				} else {
					out_spec(&i.s.p.out, spec, bytes[this_line.start:this_line.end])
					std_write_line_term(i)
				}
			}
		}
		count += 1
	}
}

std_sink_slow_multi_per_match :: proc(i: ^Std_Impl) {
	spec := cfg(i).colors.matched
	bytes := i.bytes
	for m in i.matches {
		count := 0
		st := Line_Step{i.searcher.line_term, 0, len(bytes)}
		for {
			line := line_step_next(&st, bytes) or_break
			if line.start >= m.end { break }
			if line.end <= m.start {
				count += 1
				continue
			}
			ln: Maybe(int)
			if n, ok := i.line_number.?; ok { ln = n + count }
			std_write_prelude(i, i.absolute_byte_offset + line.start, ln, max(m.start - line.start, 0) + 1)
			count += 1
			line = trim_line_terminator(i.searcher, bytes, line)
			line = std_trim_ascii_prefix(i, bytes, line)
			if std_exceeds_max_columns(i, bytes[line.start:line.end]) {
				zero := 0
				std_write_exceeded_line(i, bytes, line, []Range{m}, &zero)
				continue
			}
			for !range_empty(line) {
				if m.end <= line.start {
					w(i, bytes[line.start:line.end])
					line.start = line.end
				} else if line.start < m.start {
					upto := min(line.end, m.start)
					w(i, bytes[line.start:upto])
					line.start = upto
				} else {
					upto := min(line.end, m.end)
					out_spec(&i.s.p.out, spec, bytes[line.start:upto])
					line.start = upto
				}
			}
			std_write_line_term(i)
			if cfg(i).per_match_one_line { break }
		}
	}
}

std_sink_fast :: proc(i: ^Std_Impl) {
	std_write_prelude(i, i.absolute_byte_offset, i.line_number, nil)
	std_write_line(i, i.bytes)
}

std_sink_slow :: proc(i: ^Std_Impl) {
	if cfg(i).only_matching {
		for m in i.matches {
			std_write_prelude(i, i.absolute_byte_offset + m.start, i.line_number, m.start + 1)
			buf := i.bytes[m.start:m.end]
			std_write_colored_line(i, []Range{{0, len(buf)}}, buf)
		}
	} else if cfg(i).per_match {
		for m in i.matches {
			std_write_prelude(i, i.absolute_byte_offset + m.start, i.line_number, m.start + 1)
			std_write_colored_line(i, []Range{m}, i.bytes)
		}
	} else {
		std_write_prelude(i, i.absolute_byte_offset, i.line_number, i.matches[0].start + 1)
		std_write_colored_line(i, i.matches, i.bytes)
	}
}

std_write_prelude :: proc(i: ^Std_Impl, absolute_byte_offset: int, line_number: Maybe(int), column: Maybe(int)) {
	sep := cfg(i).separator_field_context if i.is_context else cfg(i).separator_field_match
	Next :: enum { None, Field, Path_Term }
	next := Next.None
	write_sep :: proc(i: ^Std_Impl, next: ^Next, sep: string) {
		switch next^ {
		case .None:
		case .Field: ws(i, sep)
		case .Path_Term:
			if t, ok := cfg(i).path_terminator.?; ok { w(i, []u8{t}) }
		}
		next^ = .None
	}
	out := &i.s.p.out
	if !cfg(i).heading {
		if path, ok := i.s.path.?; ok {
			write_sep(i, &next, sep)
			out_spec(out, cfg(i).colors.path, path)
			next = .Path_Term if cfg(i).path_terminator != nil else .Field
		}
	}
	if n, ok := line_number.?; ok {
		write_sep(i, &next, sep)
		out_set_color(out, cfg(i).colors.line)
		out_decimal(out, u64(n))
		out_reset(out)
		next = .Field
	}
	if cfg(i).column {
		if col, ok := column.?; ok {
			write_sep(i, &next, sep)
			out_set_color(out, cfg(i).colors.column)
			out_decimal(out, u64(col))
			out_reset(out)
			next = .Field
		}
	}
	if cfg(i).byte_offset {
		write_sep(i, &next, sep)
		out_set_color(out, cfg(i).colors.column)
		out_decimal(out, u64(absolute_byte_offset))
		out_reset(out)
		next = .Field
	}
	write_sep(i, &next, sep)
}

std_write_line :: proc(i: ^Std_Impl, line: []u8) {
	line := line
	if cfg(i).trim_ascii {
		r := trim_ascii_prefix(i.searcher, line, {0, len(line)})
		line = line[r.start:r.end]
	}
	if std_exceeds_max_columns(i, line) {
		midx := 0
		std_write_exceeded_line(i, line, {0, len(line)}, i.matches, &midx)
	} else {
		w(i, line)
		if !std_has_line_terminator(i, line) { std_write_line_term(i) }
	}
}

std_write_colored_line :: proc(i: ^Std_Impl, matches: []Range, bytes: []u8) {
	spec := cfg(i).colors.matched
	if !i.s.p.out.color || color_spec_is_none(spec) {
		std_write_line(i, bytes)
		return
	}
	line := Range{0, len(bytes)}
	line = std_trim_ascii_prefix(i, bytes, line)
	midx := 0
	if std_exceeds_max_columns(i, bytes) {
		std_write_exceeded_line(i, bytes, line, matches, &midx)
	} else {
		std_write_colored_matches(i, bytes, line, matches, &midx)
		std_write_line_term(i)
	}
}

std_write_colored_matches :: proc(i: ^Std_Impl, bytes: []u8, line: Range, matches: []Range, midx: ^int) {
	line := trim_line_terminator(i.searcher, bytes, line)
	if len(matches) == 0 {
		w(i, bytes[line.start:line.end])
		return
	}
	for !range_empty(line) {
		if matches[midx^].end <= line.start {
			if midx^ + 1 < len(matches) {
				midx^ += 1
				continue
			}
			std_end_color_match(i)
			w(i, bytes[line.start:line.end])
			break
		}
		m := matches[midx^]
		if line.start < m.start {
			upto := min(line.end, m.start)
			std_end_color_match(i)
			w(i, bytes[line.start:upto])
			line.start = upto
		} else {
			upto := min(line.end, m.end)
			std_start_color_match(i)
			w(i, bytes[line.start:upto])
			line.start = upto
		}
	}
	std_end_color_match(i)
}

std_write_exceeded_line :: proc(i: ^Std_Impl, bytes: []u8, line: Range, matches: []Range, midx: ^int) {
	// --max-columns-preview (grapheme clusters) is refused in hiargs until ported
	if len(i.s.p.matches) == 0 {
		ws(i, "[Omitted long context line]" if i.is_context else "[Omitted long matching line]")
	} else if cfg(i).only_matching {
		ws(i, "[Omitted long context line]" if i.is_context else "[Omitted long matching line]")
	} else {
		ws(i, "[Omitted long line with ")
		out_decimal(&i.s.p.out, u64(len(i.s.p.matches)))
		ws(i, " matches]")
	}
	std_write_line_term(i)
}

std_write_path_line :: proc(i: ^Std_Impl) {
	if path, ok := i.s.path.?; ok {
		out_spec(&i.s.p.out, cfg(i).colors.path, path)
		if t, has := cfg(i).path_terminator.?; has {
			w(i, []u8{t})
		} else {
			std_write_line_term(i)
		}
	}
}

std_write_search_prelude :: proc(i: ^Std_Impl) {
	out := &i.s.p.out
	if out_count(out) > 0 { return }
	if sep, ok := cfg(i).separator_search.?; ok {
		if out_total(out) > 0 {
			ws(i, sep)
			std_write_line_term(i)
		}
	}
	if cfg(i).heading { std_write_path_line(i) }
}

std_write_binary_message :: proc(i: ^Std_Impl, offset: int) {
	if i.s.match_count == 0 { return }
	kind := i.searcher.binary.kind
	if kind == .None { return }
	if path, ok := i.s.path.?; ok {
		out_spec(&i.s.p.out, cfg(i).colors.path, path)
		ws(i, ": ")
	}
	if kind == .Quit {
		ws(i, "WARNING: stopped searching binary file after match (found \"")
	} else {
		ws(i, "binary file matches (found \"")
	}
	write_debug_byte(&i.s.p.out, i.searcher.binary.byte)
	ws(i, "\" byte around offset ")
	out_decimal(&i.s.p.out, u64(offset))
	ws(i, ")\n")
}

// a byte as bstr's Debug writes it inside quotes: \0, \t, \n, \r, \\, \", printable ASCII
// as is, the rest \xNN
write_debug_byte :: proc(o: ^Out, b: u8) {
	switch b {
	case 0: out_str(o, "\\0")
	case '\t': out_str(o, "\\t")
	case '\n': out_str(o, "\\n")
	case '\r': out_str(o, "\\r")
	case '\\': out_str(o, "\\\\")
	case '"': out_str(o, "\\\"")
	case 0x20 ..= 0x7E: out_write(o, []u8{b})
	case:
		hex := "0123456789ABCDEF"
		out_write(o, []u8{'\\', 'x', hex[b >> 4], hex[b & 15]})
	}
}

std_write_context_separator :: proc(i: ^Std_Impl) {
	if sep, ok := cfg(i).separator_context.?; ok {
		ws(i, sep)
		std_write_line_term(i)
	}
}

std_write_line_term :: proc(i: ^Std_Impl) {
	if i.searcher.crlf {
		ws(i, "\r\n")
	} else {
		w(i, []u8{i.searcher.line_term})
	}
}

std_start_color_match :: proc(i: ^Std_Impl) {
	if i.in_color_match { return }
	out_set_color(&i.s.p.out, cfg(i).colors.matched)
	i.in_color_match = true
}

std_end_color_match :: proc(i: ^Std_Impl) {
	if !i.in_color_match { return }
	out_reset(&i.s.p.out)
	i.in_color_match = false
}

std_has_line_terminator :: proc(i: ^Std_Impl, buf: []u8) -> bool {
	// LineTerminator::is_suffix: the last byte only, even for CRLF
	return len(buf) > 0 && buf[len(buf) - 1] == i.searcher.line_term
}

std_exceeds_max_columns :: proc(i: ^Std_Impl, line: []u8) -> bool {
	m, ok := cfg(i).max_columns.?
	return ok && u64(len(line)) > m
}

std_trim_ascii_prefix :: proc(i: ^Std_Impl, slice: []u8, r: Range) -> Range {
	if !cfg(i).trim_ascii { return r }
	return trim_ascii_prefix(i.searcher, slice, r)
}

// leading ASCII whitespace that is not the line terminator
trim_ascii_prefix :: proc(searcher: ^Searcher, slice: []u8, r: Range) -> Range {
	n := 0
	for k in r.start ..< r.end {
		b := slice[k]
		is_space := b == '\t' || b == '\n' || b == 0x0B || b == 0x0C || b == '\r' || b == ' '
		is_term := b == searcher.line_term || (searcher.crlf && b == '\r')
		if !is_space || is_term { break }
		n += 1
	}
	return {r.start + n, r.end}
}

trim_line_terminator :: proc(searcher: ^Searcher, buf: []u8, line: Range) -> Range {
	line := line
	if line.end > line.start && buf[line.end - 1] == searcher.line_term {
		end := line.end - 1
		if searcher.crlf && end > 0 && buf[end - 1] == '\r' { end -= 1 }
		line.end = end
	}
	return line
}
