// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strings"

// The ignore crate's Gitignore (crates/ignore/src/gitignore.rs, ripgrep 14.1.1): each line
// turned into a globset glob the way ripgrep does it, and a path matched against them after
// stripping the file's directory; the last glob that matches decides.

Verdict :: enum { None, Ignore, Whitelist }

Gitignore_Glob :: struct {
	m:            Glob_Matcher,
	original:     string,
	is_whitelist: bool,
	is_only_dir:  bool,
}

Gitignore :: struct {
	root:             string,
	globs:            [dynamic]Gitignore_Glob,
	num_ignores:      int,
	num_whitelists:   int,
	case_insensitive: bool,
}

gitignore_new :: proc(root: string, case_insensitive := false) -> ^Gitignore {
	g := new(Gitignore)
	g.root = root
	if strings.has_prefix(root, "./") || (ODIN_OS == .Windows && strings.has_prefix(root, ".\\")) {
		g.root = root[2:]
	}
	g.case_insensitive = case_insensitive
	return g
}

gitignore_is_empty :: proc(g: ^Gitignore) -> bool { return g == nil || len(g.globs) == 0 }

// Rust's str::trim_end: trailing Unicode white space
@(private="file")
trim_end_unicode :: proc(s: string) -> string {
	return strings.trim_right_proc(s, proc(r: rune) -> bool {
		switch r {
		case '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0x85, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
			return true
		}
		return false
	})
}

// GitignoreBuilder::add_line; an error is the glob's, as ripgrep reports it
// Trailing spaces are dropped unless escaped, as git does: `foo\   ` keeps `foo\ `. Fix over
// 14.1.1 (ripgrep 16.0.0's #3477), which trimmed all trailing whitespace unless the line
// ended in exactly `\ `, turning `foo\   ` into `foo\` and a parse error.
@(private="file")
trim_trailing_unescaped_spaces :: proc(line: string) -> string {
	last_space := -1
	i := 0
	for i < len(line) {
		switch line[i] {
		case '\\':
			if i + 1 >= len(line) { return line }
			i += 2
			last_space = -1
		case ' ':
			if last_space < 0 { last_space = i }
			i += 1
		case:
			last_space = -1
			i += 1
		}
	}
	return line[:last_space] if last_space >= 0 else line
}

gitignore_add_line :: proc(g: ^Gitignore, line_in: string) -> (err: Maybe(string)) {
	line := line_in
	if strings.has_prefix(line, "#") { return nil }
	line = trim_trailing_unescaped_spaces(line)
	if len(line) == 0 { return nil }
	glob := Gitignore_Glob{original = line}
	is_absolute := false
	if strings.has_prefix(line, "\\!") || strings.has_prefix(line, "\\#") {
		line = line[1:]
		is_absolute = line[0] == '/'
	} else {
		if strings.has_prefix(line, "!") {
			glob.is_whitelist = true
			line = line[1:]
		}
		if strings.has_prefix(line, "/") {
			line = line[1:]
			is_absolute = true
		}
	}
	// a `!` or `/` with nothing after it is no pattern, and git skips the line; ripgrep
	// 14.1.1 compiled a lone `!` to a whitelist of everything (fix: 16.0.0's #3527)
	if len(line) == 0 { return nil }
	if len(line) > 0 && line[len(line) - 1] == '/' {
		glob.is_only_dir = true
		line = line[:len(line) - 1]
		if len(line) > 0 && line[len(line) - 1] == '\\' {
			line = line[:len(line) - 1]
		}
	}
	actual := line
	if !is_absolute && strings.index_byte(line, '/') < 0 {
		// has_doublestar_prefix: "**/" or "**"
		if !(strings.has_prefix(actual, "**/") || actual == "**") {
			actual = strings.concatenate({"**/", actual})
		}
	}
	if strings.has_suffix(actual, "/**") {
		actual = strings.concatenate({actual, "/*"})
	}
	opts := Glob_Options{literal_separator = true, case_insensitive = g.case_insensitive, backslash_escape = true}
	m, gerr, lo, hi := glob_compile(actual, opts)
	if gerr != .None {
		return strings.concatenate({"error parsing glob '", glob.original, "': ", glob_error_string(gerr, lo, hi)})
	}
	glob.m = m
	append(&g.globs, glob)
	if glob.is_whitelist { g.num_whitelists += 1 } else { g.num_ignores += 1 }
	return nil
}

// GitignoreBuilder::add: every line of the file (BufRead::lines: split on \n, a trailing \r
// dropped); returns whether the file could be read
gitignore_add_file :: proc(g: ^Gitignore, path: string) -> (read: bool, errs: [dynamic]string) {
	data, e := os.read_entire_file(path, context.allocator)
	if e != nil { return false, nil }
	rest := string(data)
	lineno := 0
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		lineno += 1
		if strings.has_suffix(line, "\r") { line = line[:len(line) - 1] }
		// a UTF-8 byte order mark before the first line is not part of it, as in git (fix
		// over 14.1.1, ripgrep 15.0.0's #2177; trim_start_matches drops any number of them)
		if lineno == 1 {
			for strings.has_prefix(line, "\xef\xbb\xbf") { line = line[3:] }
		}
		if msg, bad := gitignore_add_line(g, line).?; bad {
			append(&errs, msg)
		}
	}
	return true, errs
}

// Path::strip_prefix: whole components on Windows, raw bytes on Unix (as ripgrep's pathutil)
strip_path_prefix :: proc(prefix, path: string) -> (rest: string, ok: bool) {
	when ODIN_OS == .Windows {
		// walk both component by component; '.' components are skipped except a leading one
		a, b := Comp_Iter{s = prefix}, Comp_Iter{s = path}
		for {
			ca, more_a := comp_next(&a)
			if !more_a { break }
			cb, more_b := comp_next(&b)
			if !more_b { return }
			is_root := (ca == "/" || ca == "\\") && (cb == "/" || cb == "\\")
			if ca != cb && !is_root { return }
		}
		pos := b.i
		for pos < len(path) && (path[pos] == '/' || path[pos] == '\\') { pos += 1 }
		return path[pos:], true
	} else {
		if !strings.has_prefix(path, prefix) { return }
		return path[len(prefix):], true
	}
}

Comp_Iter :: struct {
	s:     string,
	i:     int,
	count: int,
}

// the next component of a Windows path: a leading separator is the root component, '.'
// components are skipped unless first
comp_next :: proc(it: ^Comp_Iter) -> (c: string, ok: bool) {
	for {
		if it.i < len(it.s) && (it.s[it.i] == '/' || it.s[it.i] == '\\') {
			if it.count == 0 && it.i == 0 {
				it.i += 1
				it.count += 1
				for it.i < len(it.s) && (it.s[it.i] == '/' || it.s[it.i] == '\\') { it.i += 1 }
				return it.s[0:1], true
			}
			for it.i < len(it.s) && (it.s[it.i] == '/' || it.s[it.i] == '\\') { it.i += 1 }
		}
		if it.i >= len(it.s) { return "", false }
		j := it.i
		for j < len(it.s) && it.s[j] != '/' && it.s[j] != '\\' { j += 1 }
		c = it.s[it.i:j]
		first := it.count == 0
		it.i = j
		if c == "." && !first { continue }
		it.count += 1
		return c, true
	}
}

// Windows path components, with '.' dropped except a leading one (std::path's rules)
path_components :: proc(p: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	first := true
	for i < len(p) {
		for i < len(p) && (p[i] == '/' || p[i] == '\\') {
			if first { append(&out, p[i:i + 1]); first = false }
			i += 1
		}
		if i >= len(p) { break }
		j := i
		for j < len(p) && p[j] != '/' && p[j] != '\\' { j += 1 }
		c := p[i:j]
		if c != "." || (first && len(out) == 0) { append(&out, c) }
		first = false
		i = j
	}
	return out[:]
}

// the byte offset just past the nth component of p
component_end :: proc(p: string, n: int) -> int {
	count := 0
	i := 0
	first := true
	for i < len(p) {
		for i < len(p) && (p[i] == '/' || p[i] == '\\') {
			if first { count += 1; first = false; if count == n { return i + 1 } }
			i += 1
		}
		if i >= len(p) { break }
		j := i
		for j < len(p) && p[j] != '/' && p[j] != '\\' { j += 1 }
		c := p[i:j]
		if c != "." || (first && count == 0) {
			count += 1
		}
		first = false
		i = j
		if count == n { return i }
	}
	return len(p)
}

// a single component: Path::parent is "" (Windows) / no '/' in it (Unix)
is_file_name :: proc(p: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.index_any(p, "/\\") < 0 && len(p) > 0
	} else {
		return strings.index_byte(p, '/') < 0
	}
}

strip_dot_slash :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		if r, ok := strip_path_prefix("./", p); ok && (strings.has_prefix(p, "./") || strings.has_prefix(p, ".\\")) { return r }
		return p
	} else {
		if strings.has_prefix(p, "./") { return p[2:] }
		return p
	}
}

gitignore_strip :: proc(g: ^Gitignore, path: string) -> string {
	p := strip_dot_slash(path)
	if g.root != "." && !is_file_name(p) {
		if r, ok := strip_path_prefix(g.root, p); ok {
			p = r
			if strings.has_prefix(p, "/") { p = p[1:] }
		}
	}
	return p
}

// globset's Candidate path: '\' made '/' on Windows
candidate_bytes :: proc(p: string) -> []u8 {
	when ODIN_OS == .Windows {
		if strings.index_byte(p, '\\') < 0 { return transmute([]u8)p }
		b := make([]u8, len(p), context.temp_allocator)
		for c, i in transmute([]u8)p { b[i] = '/' if c == '\\' else c }
		return b
	} else {
		return transmute([]u8)p
	}
}

gitignore_matched :: proc(g: ^Gitignore, path: string, is_dir: bool) -> Verdict {
	if gitignore_is_empty(g) { return .None }
	// the root itself strips to nothing; it is matched whole, so that an unanchored `dir/`
	// can match it (fix over 14.1.1, ripgrep 16.0.0's #3581: -g '!dir/' run from inside dir
	// on a path above it kept dir)
	stripped := gitignore_strip(g, path)
	if stripped == "" { stripped = path }
	return gitignore_matched_stripped(g, stripped, is_dir)
}

gitignore_matched_stripped :: proc(g: ^Gitignore, path: string, is_dir: bool) -> Verdict {
	if gitignore_is_empty(g) { return .None }
	cand := candidate_bytes(path)
	#reverse for &glob in g.globs {
		if glob.is_only_dir && !is_dir { continue }
		if glob_is_match(&glob.m, cand) {
			return .Whitelist if glob.is_whitelist else .Ignore
		}
	}
	return .None
}

// gitconfig's core.excludesFile: ~/.gitconfig, then $XDG_CONFIG_HOME/git/config (or
// ~/.config/git/config), else $XDG_CONFIG_HOME/git/ignore (or ~/.config/git/ignore)
gitconfig_excludes_path :: proc() -> (path: string, ok: bool) {
	home := home_dir()
	if home != "" {
		if data, e := os.read_entire_file(strings.concatenate({home, SEP, ".gitconfig"}), context.allocator); e == nil {
			if p, found := parse_excludes_file(string(data), home); found { return p, true }
		}
	}
	xdg := os.get_env("XDG_CONFIG_HOME", context.allocator)
	if xdg == "" && home != "" { xdg = strings.concatenate({home, SEP, ".config"}) }
	if xdg != "" {
		if data, e := os.read_entire_file(strings.concatenate({xdg, SEP, "git/config"}), context.allocator); e == nil {
			if p, found := parse_excludes_file(string(data), home); found { return p, true }
		}
		return strings.concatenate({xdg, SEP, "git/ignore"}), true
	}
	return "", false
}

// (?im-u)^\s*excludesfile\s*=\s*"?\s*(\S+?)\s*"?\s*$ : the first line that matches, with ~
// replaced by the home directory
parse_excludes_file :: proc(data, home: string) -> (path: string, ok: bool) {
	rest := data
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		is_ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\r' || c == 0x0B || c == 0x0C }
		s := line
		for len(s) > 0 && is_ws(s[0]) { s = s[1:] }
		key :: "excludesfile"
		if len(s) < len(key) || !strings.equal_fold(s[:len(key)], key) { continue }
		s = s[len(key):]
		for len(s) > 0 && is_ws(s[0]) { s = s[1:] }
		if len(s) == 0 || s[0] != '=' { continue }
		s = s[1:]
		for len(s) > 0 && is_ws(s[0]) { s = s[1:] }
		if len(s) > 0 && s[0] == '"' { s = s[1:] }
		for len(s) > 0 && is_ws(s[0]) { s = s[1:] }
		for len(s) > 0 && is_ws(s[len(s) - 1]) { s = s[:len(s) - 1] }
		if len(s) > 0 && s[len(s) - 1] == '"' { s = s[:len(s) - 1] }
		for len(s) > 0 && is_ws(s[len(s) - 1]) { s = s[:len(s) - 1] }
		if len(s) == 0 { continue }
		bad := false
		for c in transmute([]u8)s { if is_ws(c) { bad = true } }
		if bad { continue }
		if home != "" {
			s, _ = strings.replace_all(s, "~", home)
		}
		return s, true
	}
	return "", false
}

home_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		if h := os.get_env("HOME", context.allocator); h != "" { return h }
		return os.get_env("USERPROFILE", context.allocator)
	} else {
		return os.get_env("HOME", context.allocator)
	}
}
