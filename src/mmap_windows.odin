// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build windows
package grepper

import "core:os"
import win32 "core:sys/windows"

// A read-only view of an open file (memmap2's Mmap::map, which ripgrep's MmapChoice::open
// uses): CreateFileMappingW and MapViewOfFile over the file's own handle.
Mapping :: struct {
	data:    []u8,
	view:    rawptr,
	section: win32.HANDLE,
}

// not ok when the file cannot be mapped (an empty one cannot be); the caller then reads it
map_file :: proc(f: ^os.File) -> (m: Mapping, ok: bool) {
	h := win32.HANDLE(os.fd(f))
	size: win32.LARGE_INTEGER
	if !win32.GetFileSizeEx(h, &size) || size <= 0 { return }
	section := win32.CreateFileMappingW(h, nil, win32.PAGE_READONLY, 0, 0, nil)
	if section == nil { return }
	view := win32.MapViewOfFile(section, win32.FILE_MAP_READ, 0, 0, 0)
	if view == nil {
		win32.CloseHandle(section)
		return
	}
	return {data = ([^]u8)(view)[:int(size)], view = view, section = section}, true
}

unmap_file :: proc(m: ^Mapping) {
	win32.UnmapViewOfFile(m.view)
	win32.CloseHandle(m.section)
}
