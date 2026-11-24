// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"

// ripgrep's SearchWorker (crates/core/search.rs): one file (or stdin) searched with the
// binary detection its origin calls for (explicit: convert; walked: quit), through the
// printer the mode calls for.

Haystack :: struct {
	path:     string,
	explicit: bool,
	is_stdin: bool,
}

Printer_Kind :: enum { Standard, Summary, JSON }

Worker :: struct {
	h:        ^Hi_Args,
	m:        Matcher,
	searcher: Searcher,
	kind:     Printer_Kind,
	std:      Standard_Printer,
	sum:      Summary_Printer,
	json:     JSON_Printer,
	stats:    Stats,
}

worker_out :: proc(w: ^Worker) -> ^Out {
	switch w.kind {
	case .Standard: return &w.std.out
	case .Summary: return &w.sum.out
	case .JSON: return &w.json.out
	}
	return nil
}

worker_new :: proc(h: ^Hi_Args, m: ^Matcher) -> (w: Worker) {
	w.h = h
	w.m = matcher_clone(m^)
	w.searcher = Searcher{
		line_term = 0 if h.null_data else '\n',
		crlf = h.crlf,
		invert_match = h.invert_match,
		line_number = h.line_number,
		multi_line = h.multiline,
		passthru = h.passthru,
		stop_on_nonmatch = h.stop_on_nonmatch,
		mmap = h.mmap,
	}
	if !h.passthru {
		w.searcher.before_context = h.before_context
		w.searcher.after_context = h.after_context
	}
	summary_kind: Summary_Kind
	is_summary := true
	if h.quiet {
		summary_kind = .Quiet_Without_Match if h.mode.search == .Files_Without_Match else .Quiet_With_Match
	} else {
		switch h.mode.search {
		case .Files_With_Matches: summary_kind = .Path_With_Match
		case .Files_Without_Match: summary_kind = .Path_Without_Match
		case .Count: summary_kind = .Count
		case .Count_Matches: summary_kind = .Count_Matches
		case .Standard: is_summary = false
		case .JSON:
			w.kind = .JSON
			w.json.max_matches = h.max_count
			return
		}
	}
	if is_summary {
		w.kind = .Summary
		w.sum.config = Summary_Config{
			kind = summary_kind,
			colors = h.colors,
			exclude_zero = !h.include_zero,
			max_matches = h.max_count,
			path = h.with_filename,
			path_terminator = h.path_terminator,
			separator_field = ":",
			separator_path = h.path_separator,
			stats = h.stats,
		}
		w.sum.out.color = h.color
	} else {
		w.kind = .Standard
		w.std.config = Standard_Config{
			colors = h.colors,
			heading = h.heading,
			path = h.with_filename,
			only_matching = h.only_matching,
			per_match = h.vimgrep,
			per_match_one_line = true,
			replacement = h.replace,
			max_columns = h.max_columns,
			max_columns_preview = h.max_columns_preview,
			max_matches = h.max_count,
			column = h.column,
			byte_offset = h.byte_offset,
			trim_ascii = h.trim,
			separator_context = h.context_separator,
			separator_field_match = h.field_match_separator,
			separator_field_context = h.field_context_separator,
			separator_path = h.path_separator,
			path_terminator = h.path_terminator,
			stats = h.stats,
		}
		// with one thread the printer writes the file separator; with several, the buffer
		// writer does (it alone knows what was printed)
		if h.threads == 1 { w.std.config.separator_search = h.file_separator }
		w.std.out.color = h.color
	}
	return
}

// the search of one haystack; has_match decides the exit code
worker_search :: proc(w: ^Worker, hay: Haystack) -> (has_match: bool, err: Maybe(string)) {
	w.searcher.binary = w.h.binary_explicit if hay.explicit else w.h.binary_implicit
	std_sink: Standard_Sink
	sum_sink: Summary_Sink
	json_sink: JSON_Sink
	sink: Sink
	switch w.kind {
	case .Standard:
		std_sink = standard_sink_with_path(&w.std, &w.m, hay.path)
		sink = &std_sink
	case .Summary:
		sum_sink = summary_sink_with_path(&w.sum, &w.m, hay.path)
		sink = &sum_sink
	case .JSON:
		json_sink = json_sink_with_path(&w.json, &w.m, hay.path)
		sink = &json_sink
	}
	if hay.is_stdin {
		lb := Line_Buffer{handle = os.stdin, binary = w.searcher.binary, lineterm = w.searcher.line_term}
		lb.buf = make([dynamic]u8, DEFAULT_BUFFER_CAPACITY)
		defer delete(lb.buf)
		if e := read_by_line(&w.searcher, &w.m, &lb, &sink); e != nil {
			return false, os_error_message(e)
		}
	} else {
		data, e := os.read_entire_file(hay.path, context.allocator)
		if e != nil { return false, os_error_message(e) }
		defer delete(data)
		if w.searcher.mmap {
			slice_by_line(&w.searcher, &w.m, data, &sink)
		} else {
			lb := Line_Buffer{mem = data, cap = DEFAULT_BUFFER_CAPACITY, binary = w.searcher.binary, lineterm = w.searcher.line_term}
			read_by_line(&w.searcher, &w.m, &lb, &sink)
		}
	}
	switch w.kind {
	case .Standard:
		stats_add(&w.stats, std_sink.stats)
		return standard_has_match(&std_sink), nil
	case .Summary:
		stats_add(&w.stats, sum_sink.stats)
		return summary_has_match(&sum_sink), nil
	case .JSON:
		stats_add(&w.stats, json_sink.stats)
		return json_has_match(&json_sink), nil
	}
	return false, nil
}

// a message close to Rust's io::Error display for what Odin's os reports
os_error_message :: proc(e: os.Error) -> string {
	#partial switch v in e {
	case os.General_Error:
		#partial switch v {
		case .Not_Exist: return "The system cannot find the file specified. (os error 2)" when ODIN_OS == .Windows else "No such file or directory (os error 2)"
		}
	}
	return os.error_string(e)
}
