// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:os"
import "core:sys/posix"

// A read-only private mapping of an open file (memmap2's Mmap::map, which ripgrep's
// MmapChoice::open uses).
Mapping :: struct {
	data: []u8,
}

// not ok when the file cannot be mapped (an empty one is not); the caller then reads it
map_file :: proc(f: ^os.File) -> (m: Mapping, ok: bool) {
	fd := posix.FD(os.fd(f))
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 { return }
	p := posix.mmap(nil, uint(st.st_size), {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED { return }
	return {data = ([^]u8)(p)[:int(st.st_size)]}, true
}

unmap_file :: proc(m: ^Mapping) {
	posix.munmap(raw_data(m.data), uint(len(m.data)))
}
