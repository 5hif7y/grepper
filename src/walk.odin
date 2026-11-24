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

// is there a .git (directory or file, as in a worktree) in dir or above it?
inside_git :: proc(dir: string) -> bool {
	abs, err := os.get_absolute_path(dir, context.allocator)
	if err != nil { return false }
	d := abs
	for {
		g := strings.concatenate({d, "/.git"})
		ok := os.exists(g)
		delete(g)
		if ok { return true }
		parent, _ := os.split_path(d)
		if parent == d || parent == "" { return false }
		d = parent
	}
}

// the haystack's printed path: "./" dropped from walked paths under the implicit root
haystack_path :: proc(sh: ^Shared, path: string) -> string {
	if sh.h.has_implicit_path && strings.has_prefix(path, "./") { return path[2:] }
	return path
}

walk_dir :: proc(sh: ^Shared, shown, rel: string, stack: ^[dynamic]^Rules, in_git: bool) {
	if sync.atomic_load(&sh.quit) { return }
	fs_dir := shown if shown != "" else "."
	entries, ok := list_dir(fs_dir)
	if !ok {
		err_message(sh, haystack_path(sh, fs_dir), ": ", os_error_message(os.General_Error.Not_Exist))
		return
	}
	defer {
		for e in entries { delete(e.name) }
		delete(entries)
	}
	// which ignore files and .git the directory has, from its own listing: nothing probed
	present: Ignore_Files
	for e in entries {
		switch e.name {
		case ".git": present += {.Git}
		case ".gitignore": present += {.Gitignore}
		case ".ignore": present += {.Ignore}
		case ".rgignore": present += {.Rgignore}
		}
	}
	in_git := in_git || .Git in present
	h := sh.h
	use: Ignore_Files
	if !h.no_ignore_vcs && (in_git || h.no_require_git) {
		use += {.Gitignore}
		if !h.no_ignore_exclude { use += {.Git} }
	}
	if !h.no_ignore_dot { use += {.Ignore, .Rgignore} }
	added := load_dir_rules(fs_dir, rel, use & present, stack)
	defer resize(stack, len(stack) - added)
	slice.sort_by(entries[:], proc(a, b: Dir_Entry) -> bool { return a.name < b.name })
	for e in entries {
		if len(e.name) == 0 || e.is_link { continue }
		is_dir := e.is_dir
		if !is_dir && !e.is_file { continue }
		child_rel := e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		// ignore rules first; hidden entries are skipped only when no rule decides (a
		// whitelist such as ripgrep's own `!/.github/` keeps one), as ripgrep's
		// matched_dir_entry
		verdict := stack_verdict(stack[:], child_rel, e.name, is_dir)
		if verdict == .Ignore { continue }
		if verdict == .None && e.name[0] == '.' && !h.hidden { continue }
		child_shown := join(shown, e.name)
		if is_dir {
			walk_dir(sh, child_shown, strings.clone(child_rel), stack, in_git)
			delete(child_shown)
		} else {
			chan.send(sh.jobs, Haystack{path = haystack_path(sh, child_shown)})
		}
	}
}

// search (or list, with --files) every path: files directly, directories walked; returns
// whether anything matched
run_walk :: proc(h: ^Hi_Args, m: ^Matcher, files_mode: bool) -> bool {
	started := time.tick_now()
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
	for path in h.paths {
		if sync.atomic_load(&sh.quit) { break }
		if path == "-" {
			chan.send(sh.jobs, Haystack{path = "<stdin>", explicit = true, is_stdin = true})
			continue
		}
		fi, err := os.stat(path, context.allocator)
		if err != nil {
			err_message(&sh, path, ": ", os_error_message(err))
			continue
		}
		if fi.type == .Directory {
			stack: [dynamic]^Rules
			walk_dir(&sh, path, "", &stack, inside_git(path))
		} else {
			chan.send(sh.jobs, Haystack{path = path, explicit = true})
		}
		os.file_info_delete(fi, context.allocator)
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
