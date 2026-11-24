// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The ignore crate's file types (crates/ignore/src/types.rs): ripgrep's default table,
// changed by --type-add and --type-clear, selected by -t and negated by -T. A file's name is
// matched against the globs of every selection; the last selection with a matching glob
// decides.

File_Type_Def :: struct {
	name:  string,
	globs: [dynamic]string,
}

Types_Builder :: struct {
	types:      map[string]^File_Type_Def,
	selections: [dynamic]Type_Selection,
}

Type_Selection :: struct {
	name:    string,
	negated: bool,
}

Types :: struct {
	defs:          []File_Type_Def,      // sorted, for --type-list
	has_selected:  bool,
	globs:         [dynamic]Glob_Matcher,
	glob_negated:  [dynamic]bool,         // per glob: its selection's polarity
	empty:         bool,
}

types_builder_add :: proc(b: ^Types_Builder, name, glob: string) -> Err {
	if name == "all" { return "invalid definition (format is type:glob, e.g., html:*.html)" }
	for r in name {
		if !unicode.is_letter(r) && !unicode.is_digit(r) && !unicode.is_number(r) {
			return "invalid definition (format is type:glob, e.g., html:*.html)"
		}
	}
	def, ok := b.types[name]
	if !ok {
		def = new(File_Type_Def)
		def.name = name
		b.types[name] = def
	}
	append(&def.globs, glob)
	return nil
}

types_builder_add_defaults :: proc(b: ^Types_Builder) {
	for t in DEFAULT_TYPES {
		for n in t.names {
			for g in t.globs { types_builder_add(b, n, g) }
		}
	}
}

types_builder_add_def :: proc(b: ^Types_Builder, def: string) -> Err {
	invalid :: "invalid definition (format is type:glob, e.g., html:*.html)"
	parts := strings.split(def, ":", context.temp_allocator)
	switch len(parts) {
	case 2:
		if parts[0] == "" || parts[1] == "" { return invalid }
		return types_builder_add(b, parts[0], parts[1])
	case 3:
		name, types_string := parts[0], parts[2]
		if name == "" || parts[1] != "include" || types_string == "" { return invalid }
		names := strings.split(types_string, ",", context.temp_allocator)
		for t in names {
			if t not_in b.types { return invalid }
		}
		for t in names {
			globs := slice.clone(b.types[t].globs[:], context.temp_allocator)
			for g in globs {
				types_builder_add(b, name, g) or_return
			}
		}
		return nil
	}
	return invalid
}

// "all" stands for every type defined so far (ripgrep iterates a HashMap; here in name order)
@(private="file")
sorted_type_names :: proc(b: ^Types_Builder) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for k in b.types { append(&names, k) }
	slice.sort(names[:])
	return names[:]
}

types_builder_select :: proc(b: ^Types_Builder, name: string, negated: bool) {
	if name == "all" {
		for n in sorted_type_names(b) { append(&b.selections, Type_Selection{n, negated}) }
	} else {
		append(&b.selections, Type_Selection{name, negated})
	}
}

types_builder_clear :: proc(b: ^Types_Builder, name: string) {
	delete_key(&b.types, name)
}

types_builder_build :: proc(b: ^Types_Builder) -> (t: Types, err: Err) {
	defs := make([dynamic]File_Type_Def)
	for n in sorted_type_names(b) {
		d := b.types[n]^
		globs := slice.clone_to_dynamic(d.globs[:])
		slice.sort(globs[:])
		append(&defs, File_Type_Def{d.name, globs})
	}
	t.defs = defs[:]
	t.empty = len(b.selections) == 0
	for s in b.selections {
		if !s.negated { t.has_selected = true }
	}
	// type globs: literal_separator on, the default backslash escaping
	opts := glob_default_options()
	opts.literal_separator = true
	for s in b.selections {
		def, ok := b.types[s.name]
		if !ok { return t, strings.concatenate({"unrecognized file type: ", s.name}) }
		for g in def.globs {
			m, gerr, lo, hi := glob_compile(g, opts)
			if gerr != .None {
				return t, strings.concatenate({"error parsing glob '", g, "': ", glob_error_string(gerr, lo, hi)})
			}
			append(&t.globs, m)
			append(&t.glob_negated, s.negated)
		}
	}
	return t, nil
}

// Rust's Path::file_name: the last component, none for a path ending in ".."
path_file_name :: proc(p: string) -> (name: string, ok: bool) {
	q := p
	for len(q) > 0 && (q[len(q) - 1] == '/' || (ODIN_OS == .Windows && q[len(q) - 1] == '\\')) {
		q = q[:len(q) - 1]
	}
	i := len(q)
	for i > 0 && q[i - 1] != '/' && !(ODIN_OS == .Windows && q[i - 1] == '\\') { i -= 1 }
	name = q[i:]
	if name == "" || name == ".." { return "", false }
	if name == "." {
		// "a/." has the file name "a" in std's components; ripgrep's paths never end so
		return "", false
	}
	return name, true
}

types_matched :: proc(t: ^Types, path: string, is_dir: bool) -> Verdict {
	if is_dir || len(t.globs) == 0 { return .None }
	name, ok := path_file_name(path)
	if !ok {
		return .Ignore if t.has_selected else .None
	}
	cand := candidate_bytes(name)
	#reverse for &g, i in t.globs {
		if glob_is_match(&g, cand) {
			return .Ignore if t.glob_negated[i] else .Whitelist
		}
	}
	return .Ignore if t.has_selected else .None
}

_ :: utf8
