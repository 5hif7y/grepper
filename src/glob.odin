// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strings"
import "core:unicode/utf8"

// globset's Glob (crates/globset/src/glob.rs, ripgrep 14.1.1): the same parser, and a
// matcher equivalent to the regex globset builds from the tokens, `(?-u)` with `^...$`:
// bytes, not characters (`?` is one byte, a class holds the UTF-8 bytes of its characters),
// `.` any byte but `\n`, (?i) folding ASCII letters only. The regex is run here as a small
// Thompson NFA over bytes instead of through a regex engine.

Glob_Token_Kind :: enum { Literal, Any, Zero_Or_More, Recursive_Prefix, Recursive_Suffix, Recursive_Zero_Or_More, Class, Alternates }

Glob_Token :: struct {
	kind:    Glob_Token_Kind,
	c:       rune,                 // Literal
	negated: bool,                 // Class
	ranges:  [dynamic][2]rune,     // Class
	alts:    [dynamic][dynamic]Glob_Token,
}

Glob_Options :: struct {
	case_insensitive:  bool,
	literal_separator: bool,
	backslash_escape:  bool,
	empty_alternates:  bool,
}

// globset's default: backslash escapes everywhere but on Windows, where `\` is a separator
glob_default_options :: proc() -> Glob_Options {
	return {backslash_escape = ODIN_OS != .Windows}
}

Glob_Error_Kind :: enum { None, Invalid_Recursive, Unclosed_Class, Invalid_Range, Unopened_Alternates, Unclosed_Alternates, Nested_Alternates, Dangling_Escape }

// globset's ErrorKind display
glob_error_string :: proc(k: Glob_Error_Kind, lo, hi: rune) -> string {
	switch k {
	case .None: return ""
	case .Invalid_Recursive: return "invalid use of **; must be one path component"
	case .Unclosed_Class: return "unclosed character class; missing ']'"
	case .Invalid_Range:
		b: strings.Builder
		strings.write_string(&b, "invalid range; '")
		strings.write_rune(&b, lo)
		strings.write_string(&b, "' > '")
		strings.write_rune(&b, hi)
		strings.write_string(&b, "'")
		return strings.to_string(b)
	case .Unopened_Alternates: return "unopened alternate group; missing '{' (maybe escape '}' with '[}]'?)"
	case .Unclosed_Alternates: return "unclosed alternate group; missing '}' (maybe escape '{' with '[{]'?)"
	case .Nested_Alternates: return "nested alternate groups are not allowed"
	case .Dangling_Escape: return "dangling '\\'"
	}
	return ""
}

is_separator :: proc(c: rune) -> bool {
	return c == '/' || (ODIN_OS == .Windows && c == '\\')
}

@(private="file")
Glob_Parser :: struct {
	chars:   []rune,
	i:       int,
	stack:   [dynamic][dynamic]Glob_Token,
	prev:    Maybe(rune),
	cur:     Maybe(rune),
	opts:    Glob_Options,
	err:     Glob_Error_Kind,
	err_lo, err_hi: rune,
}

@(private="file")
gp_bump :: proc(p: ^Glob_Parser) -> (c: rune, ok: bool) {
	p.prev = p.cur
	if p.i < len(p.chars) {
		c = p.chars[p.i]
		p.i += 1
		p.cur = c
		return c, true
	}
	p.cur = nil
	return 0, false
}

@(private="file")
gp_peek :: proc(p: ^Glob_Parser) -> (c: rune, ok: bool) {
	if p.i < len(p.chars) { return p.chars[p.i], true }
	return 0, false
}

@(private="file")
gp_push :: proc(p: ^Glob_Parser, t: Glob_Token) -> bool {
	if len(p.stack) == 0 { p.err = .Unopened_Alternates; return false }
	append(&p.stack[len(p.stack) - 1], t)
	return true
}

@(private="file")
gp_pop :: proc(p: ^Glob_Parser) -> (t: Glob_Token, ok: bool) {
	if len(p.stack) == 0 { p.err = .Unopened_Alternates; return }
	return pop(&p.stack[len(p.stack) - 1]), true
}

glob_parse :: proc(glob: string, opts: Glob_Options) -> (tokens: [dynamic]Glob_Token, err: Glob_Error_Kind, lo, hi: rune) {
	p := Glob_Parser{opts = opts}
	p.chars = utf8.string_to_runes(glob)
	append(&p.stack, [dynamic]Glob_Token{})
	parse: for {
		c := gp_bump(&p) or_break
		ok := true
		switch c {
		case '?': ok = gp_push(&p, {kind = .Any})
		case '*': ok = gp_parse_star(&p)
		case '[': ok = gp_parse_class(&p)
		case '{':
			if len(p.stack) > 1 { p.err = .Nested_Alternates; ok = false } else { append(&p.stack, [dynamic]Glob_Token{}) }
		case '}':
			alts: [dynamic][dynamic]Glob_Token
			for len(p.stack) >= 2 { append(&alts, pop(&p.stack)) }
			ok = gp_push(&p, {kind = .Alternates, alts = alts})
		case ',':
			if len(p.stack) <= 1 { ok = gp_push(&p, {kind = .Literal, c = ','}) } else { append(&p.stack, [dynamic]Glob_Token{}) }
		case '\\':
			if p.opts.backslash_escape {
				n, has := gp_bump(&p)
				if !has { p.err = .Dangling_Escape; ok = false } else { ok = gp_push(&p, {kind = .Literal, c = n}) }
			} else if is_separator('\\') {
				ok = gp_push(&p, {kind = .Literal, c = '/'})
			} else {
				ok = gp_push(&p, {kind = .Literal, c = '\\'})
			}
		case:
			ok = gp_push(&p, {kind = .Literal, c = c})
		}
		if !ok { break parse }
	}
	if p.err != .None { return nil, p.err, p.err_lo, p.err_hi }
	if len(p.stack) == 0 { return nil, .Unopened_Alternates, 0, 0 }
	if len(p.stack) > 1 { return nil, .Unclosed_Alternates, 0, 0 }
	return p.stack[0], .None, 0, 0
}

@(private="file")
gp_parse_star :: proc(p: ^Glob_Parser) -> bool {
	prev := p.prev
	if n, ok := gp_peek(p); !ok || n != '*' {
		return gp_push(p, {kind = .Zero_Or_More})
	}
	gp_bump(p)
	if len(p.stack) == 0 { p.err = .Unopened_Alternates; return false }
	if len(p.stack[len(p.stack) - 1]) == 0 {
		n, ok := gp_peek(p)
		if ok && !is_separator(n) {
			return gp_push(p, {kind = .Zero_Or_More}) && gp_push(p, {kind = .Zero_Or_More})
		}
		gp_push(p, {kind = .Recursive_Prefix})
		gp_bump(p)
		return true
	}
	pv, has_prev := prev.?
	if !(has_prev && is_separator(pv)) {
		if len(p.stack) <= 1 || (pv != ',' && pv != '{') || !has_prev {
			return gp_push(p, {kind = .Zero_Or_More}) && gp_push(p, {kind = .Zero_Or_More})
		}
	}
	is_suffix: bool
	n, ok := gp_peek(p)
	switch {
	case !ok:
		gp_bump(p)
		is_suffix = true
	case (n == ',' || n == '}') && len(p.stack) >= 2:
		is_suffix = true
	case is_separator(n):
		gp_bump(p)
		is_suffix = false
	case:
		return gp_push(p, {kind = .Zero_Or_More}) && gp_push(p, {kind = .Zero_Or_More})
	}
	t := gp_pop(p) or_return
	#partial switch t.kind {
	case .Recursive_Prefix: return gp_push(p, {kind = .Recursive_Prefix})
	case .Recursive_Suffix: return gp_push(p, {kind = .Recursive_Suffix})
	}
	// the popped token is dropped, as globset does
	if is_suffix { return gp_push(p, {kind = .Recursive_Suffix}) }
	return gp_push(p, {kind = .Recursive_Zero_Or_More})
}

@(private="file")
gp_parse_class :: proc(p: ^Glob_Parser) -> bool {
	ranges: [dynamic][2]rune
	negated := false
	if n, ok := gp_peek(p); ok && (n == '!' || n == '^') {
		gp_bump(p)
		negated = true
	}
	first := true
	in_range := false
	for {
		c, ok := gp_bump(p)
		if !ok { p.err = .Unclosed_Class; return false }
		switch c {
		case ']':
			if first {
				append(&ranges, [2]rune{']', ']'})
			} else {
				if in_range { append(&ranges, [2]rune{'-', '-'}) }
				return gp_push(p, {kind = .Class, negated = negated, ranges = ranges})
			}
		case '-':
			if first {
				append(&ranges, [2]rune{'-', '-'})
			} else if in_range {
				r := &ranges[len(ranges) - 1]
				r[1] = '-'
				if r[1] < r[0] { p.err = .Invalid_Range; p.err_lo, p.err_hi = r[0], r[1]; return false }
				in_range = false
			} else {
				in_range = true
			}
		case:
			if in_range {
				r := &ranges[len(ranges) - 1]
				r[1] = c
				if r[1] < r[0] { p.err = .Invalid_Range; p.err_lo, p.err_hi = r[0], r[1]; return false }
			} else {
				append(&ranges, [2]rune{c, c})
			}
			in_range = false
		}
		first = false
	}
}

// ---------------------------------------------------------------------------------------------
// The matcher: the regex's NFA over bytes.

Byte_Set :: [4]u64

bs_add :: #force_inline proc(s: ^Byte_Set, b: u8) { s[b >> 6] |= 1 << (b & 63) }
bs_has :: #force_inline proc(s: Byte_Set, b: u8) -> bool { return s[b >> 6] & (1 << (b & 63)) != 0 }

bs_add_range :: proc(s: ^Byte_Set, lo, hi: u8) {
	for b := int(lo); b <= int(hi); b += 1 { bs_add(s, u8(b)) }
}

// (?i) on bytes: an ASCII letter also stands for its other case
bs_fold :: proc(s: ^Byte_Set) {
	for c in u8('a') ..= u8('z') {
		if bs_has(s^, c) { bs_add(s, c - 32) }
		if bs_has(s^, c - 32) { bs_add(s, c) }
	}
}

bs_negate :: proc(s: ^Byte_Set) {
	for &w in s { w = ~w }
}

NFA_Kind :: enum u8 { Byte, Split, Match }

NFA_State :: struct {
	kind:      NFA_Kind,
	set:       Byte_Set,
	out, out1: int,
}

Glob_Matcher :: struct {
	glob:      string,
	states:    [dynamic]NFA_State,
	start:     int,
	strategy:  Glob_Strategy,
	lit:       string,
	component: bool,
}

// The NFA simulation's scratch, one per thread: a matcher is shared by every thread that
// walks directories. A state's mark holds the generation it was last added in; generations
// only grow, so marks left by another matcher are always older.
@(private="file")
Glob_Scratch :: struct {
	cur, nxt: [dynamic]int,
	mark:     [dynamic]int,
	gen:      int,
}

@(private="file", thread_local)
glob_scratch: Glob_Scratch

@(private="file")
nfa_add :: proc(m: ^Glob_Matcher, s: NFA_State) -> int {
	append(&m.states, s)
	return len(m.states) - 1
}

// a fragment: its start state and the dangling exits to patch
@(private="file")
Frag :: struct {
	start: int,
	outs:  [dynamic]^int,
}

@(private="file")
patch :: proc(m: ^Glob_Matcher, f: Frag, to: int) {
	for o in f.outs { o^ = to }
}

// The states are built back to front: `next` is where the piece continues.
@(private="file")
build_seq :: proc(m: ^Glob_Matcher, tokens: []Glob_Token, opts: Glob_Options, next: int) -> int {
	cur := next
	#reverse for t in tokens {
		cur = build_token(m, t, opts, cur)
	}
	return cur
}

@(private="file")
dot_set :: proc() -> (s: Byte_Set) {
	s = {~u64(0), ~u64(0), ~u64(0), ~u64(0)}
	s[0] &~= 1 << '\n'
	return
}

@(private="file")
not_slash_set :: proc() -> (s: Byte_Set) {
	s = {~u64(0), ~u64(0), ~u64(0), ~u64(0)}
	s[0] &~= 1 << '/'
	return
}

@(private="file")
byte_state :: proc(m: ^Glob_Matcher, set: Byte_Set, next: int) -> int {
	return nfa_add(m, {kind = .Byte, set = set, out = next})
}

@(private="file")
lit_bytes :: proc(m: ^Glob_Matcher, bytes: []u8, ci: bool, next: int) -> int {
	cur := next
	#reverse for b in bytes {
		s: Byte_Set
		bs_add(&s, b)
		if ci { bs_fold(&s) }
		cur = byte_state(m, s, cur)
	}
	return cur
}

// set* then next
@(private="file")
star :: proc(m: ^Glob_Matcher, set: Byte_Set, next: int) -> int {
	split := nfa_add(m, {kind = .Split, out1 = next})
	b := byte_state(m, set, split)
	m.states[split].out = b
	return split
}

@(private="file")
alt2 :: proc(m: ^Glob_Matcher, a, b: int) -> int {
	return nfa_add(m, {kind = .Split, out = a, out1 = b})
}

@(private="file")
build_token :: proc(m: ^Glob_Matcher, t: Glob_Token, opts: Glob_Options, next: int) -> int {
	ci := opts.case_insensitive
	switch t.kind {
	case .Literal:
		buf, n := utf8.encode_rune(t.c)
		return lit_bytes(m, buf[:n], ci, next)
	case .Any:
		return byte_state(m, not_slash_set() if opts.literal_separator else dot_set(), next)
	case .Zero_Or_More:
		return star(m, not_slash_set() if opts.literal_separator else dot_set(), next)
	case .Recursive_Prefix:
		// (?:/?|.*/)
		slash := lit_bytes(m, {'/'}, false, next)
		any_slash := star(m, dot_set(), lit_bytes(m, {'/'}, false, next))
		return alt2(m, alt2(m, next, slash), any_slash)
	case .Recursive_Suffix:
		// /.*
		return lit_bytes(m, {'/'}, false, star(m, dot_set(), next))
	case .Recursive_Zero_Or_More:
		// (?:/|/.*/)
		one := lit_bytes(m, {'/'}, false, next)
		many := lit_bytes(m, {'/'}, false, star(m, dot_set(), lit_bytes(m, {'/'}, false, next)))
		return alt2(m, one, many)
	case .Class:
		return byte_state(m, class_set(t, ci, opts.literal_separator), next)
	case .Alternates:
		// each alternative's regex; empty ones are dropped (empty_alternates is off for
		// every glob ripgrep builds), and no group at all if none is left
		alts: [dynamic]int
		defer delete(alts)
		for a in t.alts {
			if len(a) == 0 && !opts.empty_alternates { continue }
			append(&alts, build_seq(m, a[:], opts, next))
		}
		if len(alts) == 0 { return next }
		cur := alts[len(alts) - 1]
		for k := len(alts) - 2; k >= 0; k -= 1 { cur = alt2(m, alts[k], cur) }
		return cur
	}
	return next
}

// The class as regex-syntax reads `[...]` built from escaped UTF-8 bytes: every range end
// is its character's bytes, so a non-ASCII character adds its bytes one by one, and a range
// joins the last byte of one end to the first byte of the other.
//
// With literal_separator a class never matches '/', negated or not, as in git and POSIX
// fnmatch with FNM_PATHNAME. Fix over 14.1.1 (ripgrep 16.0.0's #2745), whose `[/]` and
// `[!a]` matched it.
class_set :: proc(t: Glob_Token, ci: bool, literal_separator: bool) -> (s: Byte_Set) {
	Item :: struct { b: u8, dash: bool }
	items: [dynamic]Item
	defer delete(items)
	for r in t.ranges {
		b0, n0 := utf8.encode_rune(r[0])
		for k in 0 ..< n0 { append(&items, Item{b = b0[k]}) }
		if r[0] != r[1] {
			append(&items, Item{dash = true})
			b1, n1 := utf8.encode_rune(r[1])
			for k in 0 ..< n1 { append(&items, Item{b = b1[k]}) }
		}
	}
	for i := 0; i < len(items); i += 1 {
		if i + 2 < len(items) && items[i + 1].dash && !items[i + 2].dash {
			lo, hi := items[i].b, items[i + 2].b
			if lo <= hi { bs_add_range(&s, lo, hi) }
			i += 2
		} else if !items[i].dash {
			bs_add(&s, items[i].b)
		}
	}
	if ci { bs_fold(&s) }
	if literal_separator {
		// upstream drops '/' from the ranges of a class, and adds it to a negated one
		if t.negated { bs_add(&s, '/') } else { s['/' >> 6] &~= 1 << ('/' & 63) }
	}
	if t.negated { bs_negate(&s) }
	return
}

// globset's MatchStrategy: most globs are decided without the regex, by comparing the
// candidate's path, base name or extension (lib.rs); only Regex and RequiredExtension run it.
Glob_Strategy :: enum { Literal, Basename_Literal, Extension, Prefix, Suffix, Required_Extension, Regex }

glob_compile :: proc(glob: string, opts: Glob_Options) -> (m: Glob_Matcher, err: Glob_Error_Kind, lo, hi: rune) {
	tokens: [dynamic]Glob_Token
	tokens, err, lo, hi = glob_parse(glob, opts)
	if err != .None { return }
	m.glob = glob
	match_state := nfa_add(&m, {kind = .Match})
	if len(tokens) == 1 && tokens[0].kind == .Recursive_Prefix {
		m.start = star(&m, dot_set(), match_state)     // ^.*$
	} else {
		m.start = build_seq(&m, tokens[:], opts, match_state)
	}
	glob_choose_strategy(&m, tokens[:], opts)
	return
}

@(private="file")
lit_of :: proc(tokens: []Glob_Token) -> (lit: string, ok: bool) {
	b: strings.Builder
	for t in tokens {
		if t.kind != .Literal { return "", false }
		strings.write_rune(&b, t.c)
	}
	return strings.to_string(b), true
}

glob_choose_strategy :: proc(m: ^Glob_Matcher, tokens: []Glob_Token, opts: Glob_Options) {
	m.strategy = .Regex
	if opts.case_insensitive { return }
	n := len(tokens)
	// basename_literal: ** then literals without '/' (with literal_separator, ? and * would
	// be allowed by basename_tokens, but not by a literal)
	if n > 1 && tokens[0].kind == .Recursive_Prefix {
		rest := tokens[1:]
		ok := true
		for t in rest {
			if t.kind != .Literal || t.c == '/' { ok = false; break }
		}
		if ok {
			if lit, is_lit := lit_of(rest); is_lit {
				m.strategy, m.lit = .Basename_Literal, lit
				return
			}
		}
	}
	// literal
	if n > 0 {
		if lit, ok := lit_of(tokens); ok {
			m.strategy, m.lit = .Literal, lit
			return
		}
	}
	// ext: [**] * . literal..., no '.' or '/' after the dot
	ext: {
		start := 0
		if n > 0 && tokens[0].kind == .Recursive_Prefix { start = 1 }
		if start >= n || tokens[start].kind != .Zero_Or_More { break ext }
		if start == 0 && opts.literal_separator { break ext }
		if start + 1 >= n || tokens[start + 1].kind != .Literal || tokens[start + 1].c != '.' { break ext }
		b: strings.Builder
		strings.write_byte(&b, '.')
		for t in tokens[start + 2:] {
			if t.kind != .Literal || t.c == '.' || t.c == '/' { break ext }
			strings.write_rune(&b, t.c)
		}
		m.strategy, m.lit = .Extension, strings.to_string(b)
		return
	}
	// prefix: literals then * (without literal_separator) or the recursive suffix
	prefix: {
		if n == 0 { break prefix }
		end := n
		need_sep := false
		#partial switch tokens[n - 1].kind {
		case .Zero_Or_More:
			if opts.literal_separator { break prefix }
			end = n - 1
		case .Recursive_Suffix:
			end = n - 1
			need_sep = true
		}
		lit, ok := lit_of(tokens[:end])
		if !ok { break prefix }
		if need_sep { lit = strings.concatenate({lit, "/"}) }
		if lit == "" { break prefix }
		m.strategy, m.lit = .Prefix, lit
		return
	}
	// suffix: [**] [*] literals
	suffix: {
		if n == 0 { break suffix }
		b: strings.Builder
		start := 0
		entire := false
		if tokens[0].kind == .Recursive_Prefix {
			start = 1
			if n > 1 && tokens[1].kind == .Literal {
				strings.write_byte(&b, '/')
				entire = true
			}
		}
		if start >= n { break suffix }
		if tokens[start].kind == .Zero_Or_More {
			if opts.literal_separator { break suffix }
			start += 1
		}
		for t in tokens[start:] {
			if t.kind != .Literal { break suffix }
			strings.write_rune(&b, t.c)
		}
		lit := strings.to_string(b)
		if lit == "" || lit == "/" { break suffix }
		m.strategy, m.lit, m.component = .Suffix, lit, entire
		return
	}
	// required_ext: the glob ends in '.' and literals (no '/')
	req: {
		ext: [dynamic]rune
		defer delete(ext)
		#reverse for t in tokens {
			if t.kind != .Literal || t.c == '/' { break req }
			append(&ext, t.c)
			if t.c == '.' { break }
		}
		if len(ext) == 0 || ext[len(ext) - 1] != '.' { break req }
		b: strings.Builder
		#reverse for r in ext { strings.write_rune(&b, r) }
		m.strategy, m.lit = .Required_Extension, strings.to_string(b)
		return
	}
}

// globset's Candidate: the base name (none when the path is empty or ends in `..`) and its
// extension (from the last '.'). Fix over 14.1.1 (ripgrep 15.0.0's #2990): 14.1.1 had no
// base name for any path ending in '.', so `foo.` matched no file named `foo.`.
candidate_parts :: proc(path: []u8) -> (basename, ext: []u8) {
	if len(path) == 0 { return nil, nil }
	i := len(path)
	for i > 0 && path[i - 1] != '/' { i -= 1 }
	basename = path[i:]
	if string(basename) == ".." { return nil, nil }
	for k := len(basename) - 1; k >= 0; k -= 1 {
		if basename[k] == '.' { return basename, basename[k:] }
	}
	return basename, nil
}

// whether the glob matches the whole path, as globset decides it
glob_is_match :: proc(m: ^Glob_Matcher, path: []u8) -> bool {
	lit := transmute([]u8)m.lit
	switch m.strategy {
	case .Literal:
		return string(path) == m.lit
	case .Basename_Literal:
		base, _ := candidate_parts(path)
		return string(base) == m.lit
	case .Extension:
		_, ext := candidate_parts(path)
		return string(ext) == m.lit
	case .Prefix:
		return len(path) >= len(lit) && string(path[:len(lit)]) == m.lit
	case .Suffix:
		if m.component && string(path) == m.lit[1:] { return true }
		return len(path) >= len(lit) && string(path[len(path) - len(lit):]) == m.lit
	case .Required_Extension:
		_, ext := candidate_parts(path)
		if string(ext) != m.lit { return false }
		return nfa_is_match(m, path)
	case .Regex:
		return nfa_is_match(m, path)
	}
	return false
}

// the regex's NFA, simulated over the path's bytes (^...$); the scratch lists live in the
// matcher, which only the walking thread uses
nfa_is_match :: proc(m: ^Glob_Matcher, path: []u8) -> bool {
	add :: proc(m: ^Glob_Matcher, sc: ^Glob_Scratch, list: ^[dynamic]int, s: int) {
		if sc.mark[s] == sc.gen { return }
		sc.mark[s] = sc.gen
		if m.states[s].kind == .Split {
			add(m, sc, list, m.states[s].out)
			add(m, sc, list, m.states[s].out1)
			return
		}
		append(list, s)
	}
	sc := &glob_scratch
	if len(sc.mark) < len(m.states) { resize(&sc.mark, len(m.states)) }
	clear(&sc.cur)
	sc.gen += 1
	add(m, sc, &sc.cur, m.start)
	for b in path {
		sc.gen += 1
		clear(&sc.nxt)
		for s in sc.cur {
			st := &m.states[s]
			if st.kind == .Byte && bs_has(st.set, b) {
				add(m, sc, &sc.nxt, st.out)
			}
		}
		sc.cur, sc.nxt = sc.nxt, sc.cur
		if len(sc.cur) == 0 { return false }
	}
	for s in sc.cur {
		if m.states[s].kind == .Match { return true }
	}
	return false
}
