// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:strings"
import "core:sys/posix"

Dir_Entry :: struct {
	name:      string,
	is_dir:    bool,
	is_file:   bool,
	is_link:   bool,
	is_hidden: bool,   // always false: on Unix only the leading '.' hides
	size:      u64,
	size_ok:   bool,   // false: not read (the walk stats the file when it needs the size)
}

// A directory's entries from opendir/readdir alone, as walkdir reads them: the name and the
// type readdir gives (d_type), with no stat per entry; only when the file system leaves the
// type unknown is the entry lstat'ed. Odin's os.read_directory stats every entry, which made
// a walk of /usr/share (26,398 files) take 352 ms where rg -j1 takes 72.
list_dir :: proc(dir: string, allocator := context.allocator) -> (out: [dynamic]Dir_Entry, ok: bool) {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	d := posix.opendir(cdir)
	if d == nil { return out, false }
	defer posix.closedir(d)
	out = make([dynamic]Dir_Entry, allocator)
	for {
		e := posix.readdir(d)
		if e == nil { break }
		name := string(cstring(raw_data(e.d_name[:])))
		if name == "." || name == ".." { continue }
		ent := Dir_Entry{name = strings.clone(name, allocator)}
		t := e.d_type
		if t == .UNKNOWN {
			path := strings.clone_to_cstring(path_join_tmp(dir, name), context.temp_allocator)
			st: posix.stat_t
			if posix.lstat(path, &st) == .OK {
				switch {
				case posix.S_ISDIR(st.st_mode): t = .DIR
				case posix.S_ISREG(st.st_mode): t = .REG
				case posix.S_ISLNK(st.st_mode): t = .LNK
				}
				ent.size, ent.size_ok = u64(max(st.st_size, 0)), true
			}
		}
		ent.is_dir, ent.is_file, ent.is_link = t == .DIR, t == .REG, t == .LNK
		append(&out, ent)
	}
	return out, true
}

@(private = "file")
path_join_tmp :: proc(dir, name: string) -> string {
	if len(dir) > 0 && dir[len(dir) - 1] == '/' { return strings.concatenate({dir, name}, context.temp_allocator) }
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}
