// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
#+build !windows
package grepper

import "core:os"
import "core:strings"
import "core:sys/posix"

// A file being searched: the descriptor alone. Odin's os.open also allocates a File and
// asks the kernel for the file's name (readlink of /proc/self/fd/N), which grepper never
// uses: on /usr/include (8,903 files) that was one readlink per file that rg does not make.
Hay_File :: posix.FD

hay_stdin :: proc() -> Hay_File { return posix.STDIN_FILENO }

hay_open :: proc(path: string) -> (f: Hay_File, err: os.Error) {
	c := strings.clone_to_cstring(path, context.temp_allocator)
	f = posix.open(c, {.CLOEXEC, .NOCTTY})
	if f < 0 { return f, errno_error() }
	return f, nil
}

hay_close :: proc(f: Hay_File) { posix.close(f) }

// read(2), retried when a signal interrupts it, as std's File::read
hay_read :: proc(f: Hay_File, buf: []u8) -> (n: int, err: os.Error) {
	if len(buf) == 0 { return 0, nil }
	for {
		r := posix.read(f, raw_data(buf), uint(len(buf)))
		if r >= 0 { return int(r), nil }
		if posix.errno() != .EINTR { return 0, errno_error() }
	}
}

// the rest of the file, for multi line mode
hay_read_all :: proc(f: Hay_File, allocator := context.allocator) -> (data: []u8, err: os.Error) {
	out := make([dynamic]u8, 0, 1 << 16, allocator)
	for {
		old := len(out)
		non_zero_resize(&out, old + max(1 << 16, old))
		n, e := hay_read(f, out[old:])
		non_zero_resize(&out, old + n)
		if e != nil {
			delete(out)
			return nil, e
		}
		if n == 0 { break }
	}
	return out[:], nil
}

// errno as os.Error, as Odin's os maps it (core/os/errors_linux.odin), so that messages
// stay the ones os.open and os.read gave
@(private = "file")
errno_error :: proc() -> os.Error {
	e := posix.errno()
	#partial switch e {
	case .NONE:            return nil
	case .EPERM, .EACCES:  return .Permission_Denied
	case .EEXIST:          return .Exist
	case .ENOENT:          return .Not_Exist
	case .ETIMEDOUT:       return .Timeout
	case .EPIPE:           return .Broken_Pipe
	case .EBADF:           return .Invalid_File
	case .ENOMEM:          return .Out_Of_Memory
	case .ENOSYS:          return .Unsupported
	}
	return os.Platform_Error(i32(e))
}

// A read-only private mapping of an open file (memmap2's Mmap::map, which ripgrep's
// MmapChoice::open uses).
Mapping :: struct {
	data: []u8,
}

// not ok when the file cannot be mapped (an empty one is not); the caller then reads it
map_file :: proc(fd: Hay_File) -> (m: Mapping, ok: bool) {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 { return }
	p := posix.mmap(nil, uint(st.st_size), {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED { return }
	return {data = ([^]u8)(p)[:int(st.st_size)]}, true
}

unmap_file :: proc(m: ^Mapping) {
	posix.munmap(raw_data(m.data), uint(len(m.data)))
}
