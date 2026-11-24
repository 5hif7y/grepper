// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:os"
import "core:strings"

// The ignore crate's directory matcher (crates/ignore/src/dir.rs, ripgrep 14.1.1): one node
// per directory, chained to its parent, holding the directory's .rgignore, .ignore,
// .gitignore and .git/info/exclude. The nodes above the search root (its absolute
// ancestors) are "absolute parents". A path is decided by, in order: the --glob overrides;
// the ignore files, each kind looked up from the deepest directory upwards and the kinds
// ranked .rgignore > .ignore > .gitignore > exclude > global gitignore > --ignore-file; the
// file types; and, when nothing decided, whether it is hidden.

Ignore_Opts :: struct {
	hidden:                  bool,   // skip hidden entries
	ignore:                  bool,   // .ignore
	parents:                 bool,
	git_global:              bool,
	git_ignore:              bool,
	git_exclude:             bool,
	require_git:             bool,
	ignore_case_insensitive: bool,
	custom_names:            []string,   // [".rgignore"] unless --no-ignore-dot
}

Ignore_Shared :: struct {
	opts:      Ignore_Opts,
	overrides: ^Gitignore,           // --glob/--iglob, as an Override (verdicts inverted)
	types:     ^Types,
	explicit:  [dynamic]^Gitignore,  // --ignore-file
	global:    ^Gitignore,
	messages:  proc(msg: string),
}

Ignore_Node :: struct {
	sh:                 ^Ignore_Shared,
	dir:                string,
	parent:             ^Ignore_Node,
	is_absolute_parent: bool,
	absolute_base:      string,
	custom:             ^Gitignore,
	ignore:             ^Gitignore,
	gitignore:          ^Gitignore,
	exclude:            ^Gitignore,
	has_git:            bool,
}

ignore_root :: proc(sh: ^Ignore_Shared) -> ^Ignore_Node {
	n := new(Ignore_Node)
	n.sh = sh
	n.is_absolute_parent = true
	return n
}

// the global gitignore, unless --no-ignore-vcs or --no-ignore-global
load_global_gitignore :: proc(sh: ^Ignore_Shared) {
	if !sh.opts.git_global { return }
	path, ok := gitconfig_excludes_path()
	if !ok || !os.is_file(path) { return }
	g := gitignore_new("", sh.opts.ignore_case_insensitive)
	_, errs := gitignore_add_file(g, path)
	for e in errs { if sh.messages != nil { sh.messages(strings.concatenate({path, ": ", e})) } }
	sh.global = g
}

// create_gitignore: the named files in dir_for_file, rooted at dir. `present` tells which
// exist when the directory was listed; otherwise each is tried.
@(private="file")
create_gitignore :: proc(sh: ^Ignore_Shared, dir, dir_for_file: string, names: []string, present: ^Ignore_Files, which: Ignore_File) -> ^Gitignore {
	g := gitignore_new(dir, sh.opts.ignore_case_insensitive)
	if present != nil && which not_in present^ { return g }
	for name in names {
		path := path_join(dir_for_file, name)
		read, errs := gitignore_add_file(g, path)
		_ = read
		for e in errs {
			if sh.messages != nil { sh.messages(strings.concatenate({path, ": ", e})) }
		}
	}
	return g
}

Ignore_File :: enum { Git, Gitignore, Ignore, Rgignore }
Ignore_Files :: bit_set[Ignore_File]

// Path::join: the separator is added unless dir already ends with one
path_join :: proc(dir, name: string) -> string {
	if dir == "" { return strings.clone(name) }
	last := dir[len(dir) - 1]
	if last == '/' || (ODIN_OS == .Windows && last == '\\') {
		return strings.concatenate({dir, name})
	}
	return strings.concatenate({dir, SEP, name})
}

// add_child_path; `present` is the directory's own listing (nil: probe the files)
ignore_add_child :: proc(parent: ^Ignore_Node, dir: string, present: Maybe(Ignore_Files)) -> ^Ignore_Node {
	sh := parent.sh
	o := sh.opts
	n := new(Ignore_Node)
	n.sh = sh
	n.dir = dir
	n.parent = parent
	n.absolute_base = parent.absolute_base
	git_is_file := false
	if o.require_git && (o.git_ignore || o.git_exclude) {
		if p, ok := present.?; ok {
			n.has_git = .Git in p
			if n.has_git { git_is_file = os.is_file(path_join(dir, ".git")) }
		} else {
			g := path_join(dir, ".git")
			n.has_git = os.exists(g)
			git_is_file = n.has_git && os.is_file(g)
		}
	}
	pres: ^Ignore_Files
	p_local: Ignore_Files
	if p, ok := present.?; ok { p_local = p; pres = &p_local }
	if len(o.custom_names) > 0 { n.custom = create_gitignore(sh, dir, dir, o.custom_names, pres, .Rgignore) }
	if o.ignore { n.ignore = create_gitignore(sh, dir, dir, {".ignore"}, pres, .Ignore) }
	if o.git_ignore { n.gitignore = create_gitignore(sh, dir, dir, {".gitignore"}, pres, .Gitignore) }
	if o.git_exclude {
		// resolve_git_commondir: .git itself, or a worktree's common directory
		if git_dir, ok := resolve_git_commondir(dir, git_is_file); ok {
			n.exclude = create_gitignore(sh, dir, git_dir, {"info/exclude"}, nil, .Git)
		}
	}
	return n
}

resolve_git_commondir :: proc(dir: string, git_is_file: bool) -> (git_dir: string, ok: bool) {
	gd := path_join(dir, ".git")
	if !git_is_file { return gd, true }
	data, e := os.read_entire_file(gd, context.temp_allocator)
	if e != nil { return }
	line := string(data)
	if i := strings.index_byte(line, '\n'); i >= 0 { line = line[:i] }
	line = strings.trim_suffix(line, "\r")
	if !strings.has_prefix(line, "gitdir: ") { return }
	real := line[len("gitdir: "):]
	cd, e2 := os.read_entire_file(path_join(real, "commondir"), context.temp_allocator)
	if e2 != nil { return }
	c := string(cd)
	if i := strings.index_byte(c, '\n'); i >= 0 { c = c[:i] }
	c = strings.trim_suffix(c, "\r")
	if strings.has_prefix(c, ".") { return path_join(real, c), true }
	return strings.clone(c), true
}

// add_parents: the root's absolute ancestors, top down, each an absolute parent. ripgrep
// caches these nodes by path for as long as they are alive; walking one thread, the nodes
// alive are those of the previous directory root, so an ancestor shared with it is reused,
// absolute_base and all (`cache`, replaced by this root's chain).
ignore_add_parents :: proc(root: ^Ignore_Node, path: string, cache: ^map[string]^Ignore_Node) -> ^Ignore_Node {
	o := root.sh.opts
	if !o.parents && !o.git_ignore && !o.git_exclude && !o.git_global { return root }
	abs, err := os.get_absolute_path(path, context.allocator)
	if err != nil { return root }
	abs = strings.trim_right(abs, "/\\") if len(abs) > 3 else abs
	ancestors: [dynamic]string
	defer delete(ancestors)
	p := abs
	for {
		parent, ok := path_parent(p)
		if !ok { break }
		append(&ancestors, parent)
		p = parent
	}
	chain := make(map[string]^Ignore_Node)
	ig := root
	#reverse for a in ancestors {
		if prebuilt, ok := cache[a]; ok {
			ig = prebuilt
			chain[a] = prebuilt
			continue
		}
		n := ignore_add_child(ig, a, nil)
		n.is_absolute_parent = true
		n.absolute_base = abs
		n.has_git = o.require_git && o.git_ignore && os.exists(path_join(a, ".git"))
		ig = n
		chain[a] = n
	}
	delete(cache^)
	cache^ = chain
	return ig
}

// Path::parent for an absolute path; false at the root
path_parent :: proc(p: string) -> (parent: string, ok: bool) {
	i := len(p)
	for i > 0 && p[i - 1] != '/' && p[i - 1] != '\\' { i -= 1 }
	if i == 0 { return }
	// "C:\" or "/" itself has no parent
	if i == len(p) { return }
	parent = p[:i]
	if len(parent) > 1 && !(len(parent) == 3 && parent[1] == ':') {
		parent = parent[:len(parent) - 1]
	}
	if parent == p { return }
	return parent, true
}

has_any_ignore_rules :: proc(n: ^Ignore_Node) -> bool {
	o := n.sh.opts
	return o.ignore || o.git_global || o.git_ignore || o.git_exclude || len(o.custom_names) > 0 || len(n.sh.explicit) > 0
}

// matched_dir_entry
ignore_matched_entry :: proc(n: ^Ignore_Node, path: string, is_dir, hidden: bool) -> Verdict {
	m := ignore_matched(n, path, is_dir)
	if m == .None && n.sh.opts.hidden && hidden { return .Ignore }
	return m
}

ignore_matched :: proc(n: ^Ignore_Node, path_in: string, is_dir: bool) -> Verdict {
	path := strip_dot_slash(path_in)
	sh := n.sh
	if !gitignore_is_empty(sh.overrides) {
		if v := override_matched(sh.overrides, path, is_dir); v != .None { return v }
	}
	whitelisted := Verdict.None
	if has_any_ignore_rules(n) {
		v := ignore_matched_ignore(n, path, is_dir)
		if v == .Ignore { return v }
		if v == .Whitelist { whitelisted = v }
	}
	if sh.types != nil && !sh.types.empty {
		v := types_matched(sh.types, path, is_dir)
		if v == .Ignore { return v }
		if v == .Whitelist { whitelisted = v }
	}
	return whitelisted
}

// Override::matched: the gitignore verdict inverted; with any positive glob, a file no glob
// matches is ignored
override_matched :: proc(g: ^Gitignore, path: string, is_dir: bool) -> Verdict {
	v := gitignore_matched(g, path, is_dir)
	switch v {
	case .Ignore: v = .Whitelist
	case .Whitelist: v = .Ignore
	case .None:
	}
	if v == .None && g.num_ignores > 0 && !is_dir { return .Ignore }
	return v
}

ignore_matched_ignore :: proc(n: ^Ignore_Node, path: string, is_dir: bool) -> Verdict {
	m_custom, m_ignore, m_gi, m_exclude, m_explicit := Verdict.None, Verdict.None, Verdict.None, Verdict.None, Verdict.None
	o := n.sh.opts
	any_git := !o.require_git
	if !any_git {
		for p := n; p != nil; p = p.parent {
			if p.has_git { any_git = true; break }
		}
	}
	saw_git := false
	look :: proc(g: ^Gitignore, m: ^Verdict, path: string, is_dir: bool) {
		if m^ == .None && g != nil { m^ = gitignore_matched(g, path, is_dir) }
	}
	p := n
	for ; p != nil && !p.is_absolute_parent; p = p.parent {
		look(p.custom, &m_custom, path, is_dir)
		look(p.ignore, &m_ignore, path, is_dir)
		if any_git && !saw_git {
			look(p.gitignore, &m_gi, path, is_dir)
			look(p.exclude, &m_exclude, path, is_dir)
		}
		saw_git = saw_git || p.has_git
	}
	if o.parents && n.absolute_base != "" {
		// the path made absolute against the root, after stripping this node's directory
		// (ripgrep's own, even for nodes below the root)
		prefix := strip_dot_slash(n.dir)
		rel := path
		if r, ok := strip_path_prefix(prefix, path); ok {
			rel = strings.trim_prefix(r, "/")
		}
		abs := path_join(n.absolute_base, rel)
		for ; p != nil; p = p.parent {
			look(p.custom, &m_custom, abs, is_dir)
			look(p.ignore, &m_ignore, abs, is_dir)
			if any_git && !saw_git {
				look(p.gitignore, &m_gi, abs, is_dir)
				look(p.exclude, &m_exclude, abs, is_dir)
			}
			saw_git = saw_git || p.has_git
		}
	}
	#reverse for g in n.sh.explicit {
		if m_explicit != .None { break }
		m_explicit = gitignore_matched(g, path, is_dir)
	}
	m_global := Verdict.None
	if any_git && n.sh.global != nil { m_global = gitignore_matched(n.sh.global, path, is_dir) }
	for v in ([]Verdict{m_custom, m_ignore, m_gi, m_exclude, m_global, m_explicit}) {
		if v != .None { return v }
	}
	return .None
}
