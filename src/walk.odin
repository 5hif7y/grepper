// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

// One thread walks the directories (gitignore rules, hidden entries, symlinks not followed,
// as ripgrep's defaults) and sends the files to a channel; N workers search them, each into
// its own buffer, written whole under a lock so files never interleave.
Job :: struct {
	path:     string,      // as printed
	explicit: bool,        // given on the command line (searched even if hidden or ignored)
}

Shared :: struct {
	o:        ^Options,
	m:        ^Matcher,
	proto:    Printer,     // the settings every worker's printer copies
	mode:     Mode,
	jobs:     chan.Chan(Job),
	out_lock: sync.Mutex,
	files_out: int,        // blocks written, for the blank line between files in heading mode
	found:    bool,
	failed:   bool,
}

worker :: proc(sh: ^Shared) {
	m := matcher_clone(sh.m^)
	p := sh.proto
	p.buf = make([dynamic]u8, 0, 1 << 16)
	p.no_flush = true
	for {
		job, ok := chan.recv(sh.jobs)
		if !ok { break }
		data, err := os.read_entire_file(job.path, context.allocator)
		if err != nil {
			sync.lock(&sh.out_lock)
			eprint_error(job.path, err)
			sh.failed = true
			sync.unlock(&sh.out_lock)
			continue
		}
		n := 0
		if nul, binary := first_nul(data); !binary {
			n = search_buffer(&m, data, job.path, &p, sh.mode)
		} else if job.explicit {
			n = search_explicit_binary(&m, data, nul, job.path, &p, sh.mode)
		} else {
			n = search_walked_binary(&m, data, job.path, &p, sh.mode)
		}
		delete(data)
		free_all(context.temp_allocator)    // the regex VM's per-match allocations
		if n > 0 || len(p.buf) > 0 {
			sync.lock(&sh.out_lock)
			if n > 0 { sh.found = true }
			if len(p.buf) > 0 {
				if p.heading && p.with_filename && sh.mode == .Lines && sh.files_out > 0 {
					os.write(os.stdout, transmute([]u8)string("\n"))
				}
				os.write(os.stdout, p.buf[:])
				sh.files_out += 1
			}
			sync.unlock(&sh.out_lock)
			clear(&p.buf)
		}
	}
	delete(p.buf)
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

walk_dir :: proc(sh: ^Shared, shown, rel: string, stack: ^[dynamic]^Rules, in_git: bool) {
	fs_dir := shown if shown != "" else "."
	in_git := in_git
	if !in_git && os.exists(strings.concatenate({fs_dir, "/.git"}, context.temp_allocator)) {
		in_git = true
	}
	added := 0
	if !sh.o.no_ignore {
		added = load_dir_rules(fs_dir, rel, in_git, stack)
	}
	defer resize(stack, len(stack) - added)
	entries, err := os.read_all_directory_by_path(fs_dir, context.allocator)
	if err != nil {
		sync.lock(&sh.out_lock)
		eprint_error(fs_dir, err)
		sh.failed = true
		sync.unlock(&sh.out_lock)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		if len(e.name) == 0 { continue }
		if e.type == .Symlink { continue }
		is_dir := e.type == .Directory
		if !is_dir && e.type != .Regular { continue }
		child_rel := e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		// ignore rules first; hidden entries are skipped only when no rule decides (a
		// whitelist such as ripgrep's own `!/.github/` keeps one), as ripgrep's
		// matched_dir_entry
		verdict := Verdict.None
		if !sh.o.no_ignore { verdict = stack_verdict(stack[:], child_rel, e.name, is_dir) }
		if verdict == .Ignore { continue }
		if verdict == .None && e.name[0] == '.' && !sh.o.hidden { continue }
		child_shown := join(shown, e.name)
		if is_dir {
			walk_dir(sh, child_shown, strings.clone(child_rel), stack, in_git)
			delete(child_shown)
		} else {
			chan.send(sh.jobs, Job{child_shown, false})
		}
	}
}

// search every path: files directly, directories walked; returns the exit code
search_paths :: proc(o: ^Options, m: ^Matcher, proto: Printer, mode: Mode, paths: []string) -> int {
	sh := Shared{o = o, m = m, proto = proto, mode = mode}
	ch, _ := chan.create_buffered(chan.Chan(Job), 1024, context.allocator)
	sh.jobs = ch
	n := o.threads if o.threads > 0 else max(1, min(os.get_processor_core_count(), 12))
	workers := make([]^thread.Thread, n)
	for i in 0 ..< n {
		// each worker with its own context: its own temporary allocator
		workers[i] = thread.create_and_start_with_poly_data(&sh, worker)
	}
	for path in paths {
		fi, err := os.stat(path if path != "" else ".", context.allocator)
		if err != nil {
			sync.lock(&sh.out_lock)
			eprint_error(path, err)
			sh.failed = true
			sync.unlock(&sh.out_lock)
			continue
		}
		if fi.type == .Directory {
			stack: [dynamic]^Rules
			walk_dir(&sh, path, "", &stack, inside_git(path if path != "" else "."))
		} else {
			chan.send(sh.jobs, Job{path, true})
		}
		os.file_info_delete(fi, context.allocator)
	}
	chan.close(sh.jobs)
	for t in workers {
		thread.join(t)
		thread.destroy(t)
	}
	return 2 if sh.failed else (0 if sh.found else 1)
}
