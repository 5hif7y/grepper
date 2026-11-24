// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build windows
package grepper

import "core:strings"
import win32 "core:sys/windows"

// A directory's entries from FindFirstFileExW/FindNextFileW alone: name and type, nothing
// opened. Odin's os.read_directory opens every entry (CreateFile, for its file id), which cost
// a 30,000-file walk 5.3 s against ripgrep's 0.9 s; Rust's std::fs::read_dir, which ripgrep
// walks with, does not open them either.
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FindFirstFileExW :: proc(name: win32.LPCWSTR, level: i32, data: rawptr, search: i32,
	                         filter: rawptr, flags: win32.DWORD) -> win32.HANDLE ---
}

FIND_EX_INFO_BASIC :: 1         // no 8.3 short names
FIND_EX_SEARCH_NAME_MATCH :: 0
FIND_FIRST_EX_LARGE_FETCH :: 2

Dir_Entry :: struct {
	name:    string,
	is_dir:  bool,
	is_file: bool,
	is_link: bool,     // a symlink or a junction (Rust's is_symlink on Windows): not followed
	is_hidden: bool,   // FILE_ATTRIBUTE_HIDDEN: hidden to ripgrep on Windows, as a leading '.'
	size:    u64,
	size_ok: bool,     // always true: FindNextFileW gives the size
}

list_dir :: proc(dir: string, allocator := context.allocator) -> (out: [dynamic]Dir_Entry, ok: bool) {
	context.allocator = allocator
	pattern := strings.concatenate({dir, "\\*"}, context.temp_allocator)
	wpattern := win32.utf8_to_wstring(pattern, context.temp_allocator)
	data: win32.WIN32_FIND_DATAW
	h := FindFirstFileExW(wpattern, FIND_EX_INFO_BASIC, &data, FIND_EX_SEARCH_NAME_MATCH, nil, FIND_FIRST_EX_LARGE_FETCH)
	if h == win32.INVALID_HANDLE_VALUE {
		return out, false
	}
	defer win32.FindClose(h)
	for {
		n := 0
		for n < len(data.cFileName) && data.cFileName[n] != 0 { n += 1 }
		name, err := win32.utf16_to_utf8(data.cFileName[:n], allocator)
		if err == nil && name != "." && name != ".." {
			a := data.dwFileAttributes
			link := a & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 &&
			        (data.dwReserved0 == win32.IO_REPARSE_TAG_SYMLINK || data.dwReserved0 == win32.IO_REPARSE_TAG_MOUNT_POINT)
			dir := a & win32.FILE_ATTRIBUTE_DIRECTORY != 0
			append(&out, Dir_Entry{name = name, is_dir = dir && !link, is_file = !dir && !link, is_link = link,
			                       is_hidden = a & win32.FILE_ATTRIBUTE_HIDDEN != 0,
			                       size = u64(data.nFileSizeHigh) << 32 | u64(data.nFileSizeLow), size_ok = true})
		}
		if !win32.FindNextFileW(h, &data) { break }
	}
	return out, true
}
