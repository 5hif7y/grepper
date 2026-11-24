// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

// The walk and the searches over it (ripgrep's main.rs search / search_parallel / files /
// files_parallel): one thread walks the directories (gitignore rules, hidden entries,
// symlinks not followed) and sends haystacks to a channel; N workers search them, each into
// its own buffer, written whole under a lock, as ripgrep's BufferWriter (which also writes
// the file separator between non-empty buffers when there are several threads).

Shared :: struct {
	h:         ^Hi_Args,
	m:         ^Matcher,
	jobs:      chan.Chan(Haystack),
	out_lock:  sync.Mutex,
	printed:   bool,        // the buffer writer's: something was written
	matched:   bool,
	searched:  bool,
	quit:      bool,        // -q: a match ends the search
	stats:     Stats,
}

// rg: prefixed messages, which also make the exit code 2
messages_errored: bool

err_message :: proc(sh: ^Shared, parts: ..string) {
	sync.lock(&sh.out_lock)
	defer sync.unlock(&sh.out_lock)
	messages_errored = true
	if sh.h.no_messages { return }
	b: strings.Builder
	strings.write_string(&b, "grepper: ")
	for p in parts { strings.write_string(&b, p) }
	strings.write_byte(&b, '\n')
	os.write(os.stderr, b.buf[:])
	strings.builder_destroy(&b)
}

write_stdout :: proc(b: []u8) {
	if len(b) > 0 { os.write(os.stdout, b) }
}

search_worker_thread :: proc(sh: ^Shared) {
	w := worker_new(sh.h, sh.m)
	out := worker_out(&w)
	reserve(&out.buf, 1 << 16)
	for {
		hay, ok := chan.recv(sh.jobs)
		if !ok { break }
		if sync.atomic_load(&sh.quit) { continue }
		sync.atomic_store(&sh.searched, true)
		out_clear(out)
		has_match, err := worker_search(&w, hay)
		if msg, bad := err.?; bad {
			err_message(sh, hay.path, ": ", msg)
		}
		free_all(context.temp_allocator)
		sync.lock(&sh.out_lock)
		if has_match { sh.matched = true }
		if len(out.buf) > 0 {
			if sep, has := sh.h.file_separator.?; has && sh.h.threads > 1 && sh.printed {
				write_stdout(transmute([]u8)sep)
				write_stdout([]u8{'\n'})
			}
			write_stdout(out.buf[:])
			sh.printed = true
		}
		if sh.matched && sh.h.quit_after_match { sync.atomic_store(&sh.quit, true) }
		stats_add(&sh.stats, w.stats)
		w.stats = {}
		sync.unlock(&sh.out_lock)
	}
}

files_worker_thread :: proc(sh: ^Shared) {
	o: Out
	o.color = sh.h.color
	term := sh.h.path_terminator.? or_else '\n'
	for {
		hay, ok := chan.recv(sh.jobs)
		if !ok { break }
		sync.lock(&sh.out_lock)
		sh.matched = true
		quit := sh.h.quit_after_match
		sync.unlock(&sh.out_lock)
		if quit { sync.atomic_store(&sh.quit, true); continue }
		out_spec(&o, sh.h.colors.path, printer_path(hay.path, sh.h.path_separator))
		out_write(&o, []u8{term})
		free_all(context.temp_allocator)
		if len(o.buf) >= 1 << 16 {
			sync.lock(&sh.out_lock)
			write_stdout(o.buf[:])
			sync.unlock(&sh.out_lock)
			clear(&o.buf)
		}
	}
	sync.lock(&sh.out_lock)
	write_stdout(o.buf[:])
	sync.unlock(&sh.out_lock)
}

// the path to print for an entry under a walked directory
join :: proc(dir, name: string) -> string {
	if dir == "" { return strings.clone(name) }
	if strings.has_suffix(dir, "/") || strings.has_suffix(dir, "\\") {
		return strings.concatenate({dir, name})
	}
	return strings.concatenate({dir, SEP, name})
}
// the haystack's printed path: "./" dropped from walked paths under the implicit root
haystack_path :: proc(sh: ^Shared, path: string) -> string {
	if sh.h.has_implicit_path && strings.has_prefix(path, "./") { return path[2:] }
	return path
}

// The walk proper (the ignore crate's Walk over walkdir): depth-first, each directory's
// entries in the order the OS lists them (by name with --sort path), every entry below the
// root checked against the ignore matcher of its directory.
Walker :: struct {
	sh:      ^Shared,
	cfg:     ^Ignore_Shared,
	root_ig: ^Ignore_Node,
	emit:    proc(w: ^Walker, hay: Haystack),
	sorted:  [dynamic]Haystack,   // --sort/--sortr by time or reverse path: collected first
	collect: bool,
	ancestors: [dynamic]string,   // with -L: the directories being walked, for loop detection
	parents_cache: map[string]^Ignore_Node,   // the previous directory root's ancestors
}

walker_emit :: proc(w: ^Walker, hay: Haystack) {
	if w.collect {
		append(&w.sorted, hay)
	} else {
		chan.send(w.sh.jobs, hay)
	}
}

ignore_message :: proc(msg: string) {
	if global_hi != nil && (global_hi.no_ignore_messages || global_hi.no_messages) { return }
	b: strings.Builder
	strings.write_string(&b, "grepper: ")
	strings.write_string(&b, msg)
	strings.write_byte(&b, '\n')
	os.write(os.stderr, b.buf[:])
	strings.builder_destroy(&b)
}

global_hi: ^Hi_Args

walk_dir :: proc(w: ^Walker, ig: ^Ignore_Node, dir: string, depth: int) {
	sh := w.sh
	h := sh.h
	if sync.atomic_load(&sh.quit) { return }
	if md, ok := h.max_depth.?; ok && depth >= md { return }
	entries, ok := list_dir(dir)
	if !ok {
		err_message(sh, haystack_path(sh, dir), ": ", os_error_message(os.General_Error.Not_Exist))
		return
	}
	defer {
		for e in entries { delete(e.name) }
		delete(entries)
	}
	present: Ignore_Files
	for e in entries {
		switch e.name {
		case ".git": present += {.Git}
		case ".gitignore": present += {.Gitignore}
		case ".ignore": present += {.Ignore}
		case ".rgignore": present += {.Rgignore}
		}
	}
	node := ignore_add_child(ig, dir, present)
	if s, has := h.sort.?; has && s.kind == .Path && !s.reverse {
		slice.sort_by(entries[:], proc(a, b: Dir_Entry) -> bool { return a.name < b.name })
	}
	for e in entries {
		if sync.atomic_load(&sh.quit) { return }
		// the matching's scratch (stripped paths, candidates) lives in the temporary
		// allocator; nothing in it outlives one entry
		free_all(context.temp_allocator)
		if len(e.name) == 0 { continue }
		path := join(dir, e.name)
		is_dir, is_file := e.is_dir, e.is_file
		size := e.size
		if e.is_link {
			if !h.follow {
				delete(path)
				continue        // a symlink not followed is neither a file nor a directory
			}
			fi, err := os.stat(path, context.temp_allocator)
			if err != nil {
				err_message(sh, haystack_path(sh, path), ": ", os_error_message(err))
				delete(path)
				continue
			}
			is_dir, is_file = fi.type == .Directory, fi.type == .Regular
			size = u64(max(fi.size, 0))
		}
		hidden := e.name[0] == '.' || e.is_hidden
		if ignore_matched_entry(node, path, is_dir, hidden) == .Ignore {
			delete(path)
			continue
		}
		if !is_dir && !e.size_ok && !e.is_link && h.max_filesize != nil {
			// a lister that gives no size (readdir): stat only when --max-filesize needs it
			if fi, err := os.stat(path, context.temp_allocator); err == nil { size = u64(max(fi.size, 0)) }
		}
		if !is_dir {
			if mf, has := h.max_filesize.?; has && size > mf {
				delete(path)
				continue
			}
		}
		if is_dir {
			if h.follow && is_loop(w, path) {
				err_message(sh, "File system loop found: ", haystack_path(sh, path), " points to an ancestor ", loop_ancestor)
				delete(path)
				continue
			}
			if h.one_file_system && !same_file_system(w, path) {
				delete(path)
				continue
			}
			if h.follow { append(&w.ancestors, canonical(path)) }
			walk_dir(w, node, path, depth + 1)
			if h.follow { pop(&w.ancestors) }
			delete(path)
		} else if is_file {
			w.emit(w, Haystack{path = haystack_path(sh, path)})
		} else {
			delete(path)
		}
	}
}

loop_ancestor: string

canonical :: proc(p: string) -> string {
	abs, err := os.get_absolute_path(p, context.allocator)
	if err != nil { return p }
	// a followed link resolves to its target; Odin's absolute path does not resolve links,
	// so the link's target is read when there is one
	if t, terr := os.read_link(abs, context.allocator); terr == nil && t != "" {
		if ta, e := os.get_absolute_path(t, context.allocator); e == nil { return ta }
		return t
	}
	return abs
}

is_loop :: proc(w: ^Walker, path: string) -> bool {
	c := canonical(path)
	for a in w.ancestors {
		if a == c {
			loop_ancestor = a
			return true
		}
	}
	return false
}

root_device: u64

same_file_system :: proc(w: ^Walker, path: string) -> bool {
	return device_of(path) == root_device
}

// the walk over every root path; haystacks go to the workers (or to w.sorted first)
walk_roots :: proc(w: ^Walker) {
	sh := w.sh
	h := sh.h
	for path in h.paths {
		if sync.atomic_load(&sh.quit) { break }
		if path == "-" {
			w.emit(w, Haystack{path = "<stdin>", explicit = true, is_stdin = true})
			continue
		}
		fi, err := os.stat(path, context.allocator)
		if err != nil {
			// walkdir's error for the root, with the path ripgrep adds in front
			err_message(sh, path, ": IO error for operation on ", path, ": ", os_error_message(err))
			clear(&w.parents_cache)      // ripgrep drops the previous root's chain here
			continue
		}
		if fi.type == .Directory {
			ig := ignore_add_parents(w.root_ig, path, &w.parents_cache)
			if h.one_file_system { root_device = device_of(path) }
			if h.follow {
				clear(&w.ancestors)
				append(&w.ancestors, canonical(path))
			}
			walk_dir(w, ig, path, 0)
		} else {
			clear(&w.parents_cache)
			w.emit(w, Haystack{path = path, explicit = true})
		}
		os.file_info_delete(fi, context.allocator)
	}
}

// --sort/--sortr other than ascending paths: every haystack collected, then sorted stably
sort_haystacks :: proc(hays: []Haystack, s: Sort_Mode) {
	Keyed :: struct { hay: Haystack, t: i64, ok: bool }
	keyed := make([]Keyed, len(hays), context.temp_allocator)
	for hy, i in hays {
		keyed[i].hay = hy
		if s.kind == .Path { continue }
		fi, err := os.stat(hy.path, context.temp_allocator)
		if err != nil { continue }
		switch s.kind {
		case .Last_Modified: keyed[i].t = time.to_unix_nanoseconds(fi.modification_time)
		case .Last_Accessed: keyed[i].t = time.to_unix_nanoseconds(fi.access_time)
		case .Created: keyed[i].t = time.to_unix_nanoseconds(fi.creation_time)
		case .Path:
		}
		keyed[i].ok = true
	}
	if s.kind == .Path {
		// reverse path order (Path's component-wise comparison)
		slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool { return path_less(b.hay.path, a.hay.path) })
	} else if s.reverse {
		slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool {
			if a.ok && b.ok { return a.t > b.t }
			return !a.ok && b.ok      // errors first when reversed
		})
	} else {
		slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool {
			if a.ok && b.ok { return a.t < b.t }
			return a.ok && !b.ok      // errors last
		})
	}
	for k, i in keyed { hays[i] = k.hay }
}

// std::path::Path's ordering: component by component
path_less :: proc(a, b: string) -> bool {
	ac := path_components(a, context.temp_allocator)
	bc := path_components(b, context.temp_allocator)
	for i in 0 ..< min(len(ac), len(bc)) {
		if ac[i] != bc[i] { return ac[i] < bc[i] }
	}
	return len(ac) < len(bc)
}

walk_config :: proc(h: ^Hi_Args) -> ^Ignore_Shared {
	c := new(Ignore_Shared)
	c.opts = Ignore_Opts{
		hidden = !h.hidden,
		ignore = !h.no_ignore_dot,
		parents = !h.no_ignore_parent,
		git_global = !h.no_ignore_vcs && !h.no_ignore_global,
		git_ignore = !h.no_ignore_vcs,
		git_exclude = !h.no_ignore_vcs && !h.no_ignore_exclude,
		require_git = !h.no_require_git,
		ignore_case_insensitive = h.ignore_file_case_insensitive,
	}
	if !h.no_ignore_dot { c.opts.custom_names = {".rgignore"} }
	c.messages = ignore_message
	c.overrides = h.overrides
	c.types = &h.types
	if !h.no_ignore_files {
		// rooted at the working directory (fix over 14.1.1, ripgrep 15.0.0's #3179)
		cwd, _ := os.get_working_directory(context.allocator)
		for p in h.ignore_file {
			g := gitignore_new(cwd)
			read, errs := gitignore_add_file(g, p)
			if !read {
				ignore_message(strings.concatenate({p, ": ", os_error_message(os.General_Error.Not_Exist)}))
			}
			for e in errs { ignore_message(strings.concatenate({p, ": ", e})) }
			append(&c.explicit, g)
		}
	}
	load_global_gitignore(c)
	return c
}

// search (or list, with --files) every path: files directly, directories walked; returns
// whether anything matched
run_walk :: proc(h: ^Hi_Args, m: ^Matcher, files_mode: bool) -> bool {
	started := time.tick_now()
	global_hi = h
	sh := Shared{h = h, m = m}
	ch, _ := chan.create_buffered(chan.Chan(Haystack), 1024, context.allocator)
	sh.jobs = ch
	n := h.threads
	if files_mode { n = 1 }
	workers := make([]^thread.Thread, n)
	for i in 0 ..< n {
		// each worker with its own context: its own temporary allocator
		if files_mode {
			workers[i] = thread.create_and_start_with_poly_data(&sh, files_worker_thread)
		} else {
			workers[i] = thread.create_and_start_with_poly_data(&sh, search_worker_thread)
		}
	}
	cfg := walk_config(h)
	w := Walker{sh = &sh, cfg = cfg, root_ig = ignore_root(cfg), emit = walker_emit}
	if s, has := h.sort.?; has && !(s.kind == .Path && !s.reverse) {
		w.collect = true
	}
	walk_roots(&w)
	if w.collect {
		sort_haystacks(w.sorted[:], h.sort.?)
		for hay in w.sorted { chan.send(sh.jobs, hay) }
	}
	chan.close(sh.jobs)
	for t in workers {
		thread.join(t)
		thread.destroy(t)
	}
	if h.has_implicit_path && !sh.searched && !files_mode {
		err_message(&sh, "No files were searched, which means ripgrep probably applied a filter you didn't expect.\nRunning with --debug will show why files are being skipped.")
	}
	if h.stats && !files_mode {
		o: Out
		print_stats(&o, h.mode.search, sh.stats, time.tick_since(started))
		// with several threads the buffer writer adds the file separator before it
		if sep, has := h.file_separator.?; has && h.threads > 1 && sh.printed && len(o.buf) > 0 {
			write_stdout(transmute([]u8)sep)
			write_stdout([]u8{'\n'})
		}
		write_stdout(o.buf[:])
	}
	return sh.matched
}

device_of :: proc(p: string) -> u64 {
	fi, err := os.stat(p, context.temp_allocator)
	if err != nil { return 0 }
	return fi.device
}
// main.rs's print_stats: a JSON summary message, or the text block
print_stats :: proc(o: ^Out, mode: Search_Mode, st: Stats, elapsed: time.Duration) {
	if mode == .JSON {
		out_str(o, `{"data":{"elapsed_total":{"human":"`)
		write_seconds(o, i64(elapsed))
		out_str(o, `s","nanos":`)
		out_decimal(o, u64(i64(elapsed) % 1_000_000_000))
		out_str(o, `,"secs":`)
		out_decimal(o, u64(i64(elapsed) / 1_000_000_000))
		out_str(o, `},"stats":{"bytes_printed":`)
		out_decimal(o, st.bytes_printed)
		out_str(o, `,"bytes_searched":`)
		out_decimal(o, st.bytes_searched)
		out_str(o, `,"elapsed":{"human":"`)
		write_seconds(o, st.elapsed_ns)
		out_str(o, `s","nanos":`)
		out_decimal(o, u64(st.elapsed_ns % 1_000_000_000))
		out_str(o, `,"secs":`)
		out_decimal(o, u64(st.elapsed_ns / 1_000_000_000))
		out_str(o, `},"matched_lines":`)
		out_decimal(o, st.matched_lines)
		out_str(o, `,"matches":`)
		out_decimal(o, st.matches)
		out_str(o, `,"searches":`)
		out_decimal(o, st.searches)
		out_str(o, `,"searches_with_match":`)
		out_decimal(o, st.searches_with_match)
		out_str(o, "}},\"type\":\"summary\"}\n")
		return
	}
	line :: proc(o: ^Out, n: u64, what: string) {
		out_decimal(o, n)
		out_str(o, what)
	}
	out_str(o, "\n")
	line(o, st.matches, " matches\n")
	line(o, st.matched_lines, " matched lines\n")
	line(o, st.searches_with_match, " files contained matches\n")
	line(o, st.searches, " files searched\n")
	line(o, st.bytes_printed, " bytes printed\n")
	line(o, st.bytes_searched, " bytes searched\n")
	write_seconds(o, st.elapsed_ns)
	out_str(o, " seconds spent searching\n")
	write_seconds(o, i64(elapsed))
	out_str(o, " seconds\n")
}
