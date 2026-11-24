// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strings"

// gitignore rules (gitignore(5)), as ripgrep's `ignore` crate applies them:
// - a blank line or one starting with `#` is nothing; `\#` and `\!` escape the first byte;
//   trailing spaces are dropped unless escaped;
// - `!` negates: a later match un-ignores;
// - a trailing `/` matches directories only;
// - a pattern with a `/` before its end is anchored to the file's directory; one without
//   matches the name at any depth;
// - `*` and `?` never match `/`; `**/` matches zero or more directories, `/**` everything
//   inside, `[...]` a class (`!` or `^` negates it, ranges allowed).
// Within a directory .gitignore, then .ignore, then .rgignore (the later wins, as ripgrep);
// a deeper directory's rules after its parents'.
Rule :: struct {
	glob:     string,
	negate:   bool,
	dir_only: bool,
	anchored: bool,      // matched against the path from the rules' directory, else the name
}

Rules :: struct {
	dir:   string,        // the directory the patterns are relative to ("" = the search root)
	rules: [dynamic]Rule,
}

parse_rules :: proc(dir, text: string) -> (r: Rules) {
	r.dir = dir
	rest := text
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		line = strings.trim_right(line, "\r")
		// trailing spaces, unless the last is escaped
		for len(line) > 0 && line[len(line) - 1] == ' ' && !(len(line) >= 2 && line[len(line) - 2] == '\\') {
			line = line[:len(line) - 1]
		}
		if len(line) == 0 || line[0] == '#' { continue }
		rule: Rule
		if line[0] == '!' {
			rule.negate = true
			line = line[1:]
		} else if len(line) >= 2 && line[0] == '\\' && (line[1] == '#' || line[1] == '!') {
			line = line[1:]
		}
		if len(line) > 0 && line[len(line) - 1] == '/' {
			rule.dir_only = true
			line = line[:len(line) - 1]
		}
		if len(line) == 0 { continue }
		if strings.index_byte(line, '/') >= 0 {
			rule.anchored = true
			line = strings.trim_left(line, "/")
		}
		rule.glob = line
		append(&r.rules, rule)
	}
	return
}

// gitignore's glob over a '/'-separated path
glob_match :: proc(p, s: string) -> bool {
	p, s := p, s
	for len(p) > 0 {
		if len(p) >= 2 && p[0] == '*' && p[1] == '*' && (len(p) == 2 || p[2] == '/') {
			if len(p) == 2 { return true }          // a trailing `**`: everything below
			rest := p[3:]                           // `**/`: zero or more directories
			for i := 0; i <= len(s); i += 1 {
				if (i == 0 || s[i - 1] == '/') && glob_match(rest, s[i:]) { return true }
			}
			return false
		}
		switch p[0] {
		case '*':
			for len(p) > 0 && p[0] == '*' { p = p[1:] }
			for i := 0; i <= len(s); i += 1 {
				if glob_match(p, s[i:]) { return true }
				if i < len(s) && s[i] == '/' { break }
			}
			return false
		case '?':
			if len(s) == 0 || s[0] == '/' { return false }
			p, s = p[1:], s[1:]
		case '[':
			if len(s) == 0 || s[0] == '/' { return false }
			ok, n := class_match(p, s[0])
			if n == 0 {                             // no closing bracket: a literal `[`
				if s[0] != '[' { return false }
				p, s = p[1:], s[1:]
				continue
			}
			if !ok { return false }
			p, s = p[n:], s[1:]
		case '\\':
			if len(p) < 2 { return len(s) == 1 && s[0] == '\\' }
			if len(s) == 0 || s[0] != p[1] { return false }
			p, s = p[2:], s[1:]
		case:
			if len(s) == 0 || s[0] != p[0] { return false }
			p, s = p[1:], s[1:]
		}
	}
	return len(s) == 0
}

// p starts with '['; returns whether c is in the class and the class's length (0 if unclosed)
class_match :: proc(p: string, c: u8) -> (ok: bool, n: int) {
	i := 1
	neg := false
	if i < len(p) && (p[i] == '!' || p[i] == '^') { neg = true; i += 1 }
	first := true
	for i < len(p) {
		if p[i] == ']' && !first {
			return ok != neg, i + 1
		}
		first = false
		lo := p[i]
		if lo == '\\' && i + 1 < len(p) { i += 1; lo = p[i] }
		i += 1
		hi := lo
		if i + 1 < len(p) && p[i] == '-' && p[i + 1] != ']' {
			hi = p[i + 1]
			if hi == '\\' && i + 2 < len(p) { i += 1; hi = p[i + 1] }
			i += 2
		}
		if lo <= c && c <= hi { ok = true }
	}
	return false, 0
}

Verdict :: enum { None, Ignore, Whitelist }

// the last rule matching rel (the path from the rules' directory, '/'-separated) decides
rules_verdict :: proc(r: ^Rules, rel, name: string, is_dir: bool) -> Verdict {
	#reverse for &rule in r.rules {
		if rule.dir_only && !is_dir { continue }
		if glob_match(rule.glob, rel if rule.anchored else name) {
			return .Whitelist if rule.negate else .Ignore
		}
	}
	return .None
}

// the deepest rules with a verdict decide; rel_from_root is the path from the search root, and
// each Rules' dir is a prefix of it
stack_verdict :: proc(stack: []^Rules, rel_from_root, name: string, is_dir: bool) -> Verdict {
	#reverse for r in stack {
		rel := rel_from_root
		if len(r.dir) > 0 {
			rel = rel_from_root[len(r.dir) + 1:]
		}
		if v := rules_verdict(r, rel, name, is_dir); v != .None {
			return v
		}
	}
	return .None
}

// the rules a directory adds: .gitignore (inside a git repository only, as ripgrep), then
// .ignore, then .rgignore; and .git/info/exclude at a repository's root, below them
load_dir_rules :: proc(fs_dir, rel_dir: string, in_git: bool, out: ^[dynamic]^Rules) -> (added: int) {
	files := [?]string{".git/info/exclude", ".gitignore", ".ignore", ".rgignore"}
	for f, k in files {
		if k <= 1 && !in_git { continue }
		path := strings.concatenate({fs_dir, "/", f})
		data, err := os.read_entire_file(path, context.allocator)
		delete(path)
		if err != nil { continue }
		r := new(Rules)
		r^ = parse_rules(rel_dir, string(data))
		if len(r.rules) == 0 { free(r); continue }
		append(out, r)
		added += 1
	}
	return
}
