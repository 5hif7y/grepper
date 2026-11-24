// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:os"

Dir_Entry :: struct {
	name:    string,
	is_dir:  bool,
	is_file: bool,
	is_link: bool,
	is_hidden: bool,   // always false: on Unix only the leading '.' hides
	size:    u64,
}

// A directory's entries through Odin's os.read_directory (to be measured against ripgrep on
// Linux as the Windows reader was).
list_dir :: proc(dir: string, allocator := context.allocator) -> (out: [dynamic]Dir_Entry, ok: bool) {
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil { return out, false }
	defer os.file_info_slice_delete(infos, allocator)
	for fi in infos {
		append(&out, Dir_Entry{name = strings_clone(fi.name, allocator), is_dir = fi.type == .Directory,
		                       is_file = fi.type == .Regular, is_link = fi.type == .Symlink, size = u64(max(fi.size, 0))})
	}
	return out, true
}

@(private = "file")
strings_clone :: proc(s: string, allocator := context.allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
