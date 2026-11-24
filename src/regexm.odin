// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:strings"
import "core:text/regex"
import nvol "nvol:odin"

// The interim regex engine: Odin's core:text/regex (a Pike VM), until ripgrep's regex-automata
// is ported. A match never crosses a line, as in ripgrep: candidates come from NVOL's memmem on
// a literal every match must contain (the prefilter) or, without one, from the VM over the
// rest of the buffer (every match inside a line is a match there too); each candidate's line is
// then checked alone. A pattern with `^` or `$` and no prefilter is checked line by line:
// Odin's multiline anchors consume the newline (`^$` finds no empty line in "a\n\nb", and `$`
// spans [1, 2) there), so the buffer-wide search would miss lines.
//
// Limits of the engine, for now: -i folds ASCII only; `\d \w \s` are ASCII (as ripgrep's are
// not: Unicode there).
Regex_Matcher :: struct {
	buf_rx:    regex.Regular_Expression,   // over the buffer: candidates
	line_rx:   regex.Regular_Expression,   // one line alone: the verdict and the bounds
	by_line:   bool,                       // anchors and no prefilter: every line alone
	capture:   regex.Capture,
	prefilter: Maybe(nvol.Memmem_Finder),
	literal:   string,
}

META :: "\\.^$|?*+()[]{}"

has_meta :: proc(p: string) -> bool {
	return strings.index_any(p, META) >= 0
}

regex_escape :: proc(p: string) -> string {
	b: strings.Builder
	for c in transmute([]u8)p {
		if strings.index_byte(META, c) >= 0 { strings.write_byte(&b, '\\') }
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// The longest run of literal bytes that every match contains: the pattern's top level, outside
// groups and classes, with no `|` anywhere at that level; a byte followed by `?`, `*` or `{`
// (which may repeat it zero times) ends a run without joining it.
required_literal :: proc(p: string) -> string {
	depth := 0
	in_class := false
	for i := 0; i < len(p); i += 1 {
		c := p[i]
		switch {
		case c == '\\': i += 1
		case in_class: if c == ']' { in_class = false }
		case c == '[': in_class = true
		case c == '(': depth += 1
		case c == ')': depth -= 1
		case c == '|' && depth == 0: return ""
		}
	}
	best, cur: strings.Builder
	depth = 0
	in_class = false
	flush :: proc(best, cur: ^strings.Builder) {
		if strings.builder_len(cur^) > strings.builder_len(best^) {
			strings.builder_reset(best)
			strings.write_string(best, strings.to_string(cur^))
		}
		strings.builder_reset(cur)
	}
	for i := 0; i < len(p); i += 1 {
		c := p[i]
		next: u8 = p[i + 1] if i + 1 < len(p) else 0
		lit: u8 = 0
		is_lit := false
		if in_class {
			if c == '\\' { i += 1 } else if c == ']' { in_class = false }
			continue
		}
		switch c {
		case '[': in_class = true; flush(&best, &cur); continue
		case '(': depth += 1; flush(&best, &cur); continue
		case ')': depth -= 1; flush(&best, &cur); continue
		case '\\':
			if i + 1 < len(p) && strings.index_byte(META, p[i + 1]) >= 0 {
				lit, is_lit = p[i + 1], true
				i += 1
				next = p[i + 1] if i + 1 < len(p) else 0
			} else {               // \d \w \s \b ...: not a literal byte
				i += 1
				flush(&best, &cur)
				continue
			}
		case '.', '^', '$', '|', '?', '*', '+', '{', '}', ']':
			flush(&best, &cur)
			continue
		case:
			lit, is_lit = c, true
		}
		if depth > 0 || !is_lit { continue }
		if next == '?' || next == '*' || next == '{' {
			flush(&best, &cur)
			continue
		}
		strings.write_byte(&cur, lit)
		if next == '+' { flush(&best, &cur) }   // `a+`: one a is required, the run ends
	}
	flush(&best, &cur)
	return strings.to_string(best)
}

matcher_regex :: proc(pattern: string, ignore_case: bool) -> (m: Matcher, err: Maybe(string)) {
	flags: regex.Flags = {.Unicode}
	if ignore_case { flags += {.Case_Insensitive} }
	line_rx, e1 := regex.create(pattern, flags)
	if e1 != nil {
		return m, strings.concatenate({"invalid regex: ", pattern})
	}
	buf_rx, e2 := regex.create(pattern, flags)
	if e2 != nil {
		return m, strings.concatenate({"invalid regex: ", pattern})
	}
	r := new(Regex_Matcher)
	r.line_rx, r.buf_rx = line_rx, buf_rx
	r.capture = regex.preallocate_capture()
	if !ignore_case {
		if lit := required_literal(pattern); len(lit) > 0 {
			r.literal = lit
			r.prefilter = nvol.memmem_finder(transmute([]u8)lit)
		}
	}
	r.by_line = r.prefilter == nil && has_anchor(pattern)
	m.kind = .Regex
	m.rx = r
	return m, nil
}

// one regex per -e pattern is joined as an alternation (ripgrep searches them as one)
join_patterns :: proc(patterns: []string, fixed: bool) -> string {
	if len(patterns) == 1 {
		return regex_escape(patterns[0]) if fixed else patterns[0]
	}
	b: strings.Builder
	for p, i in patterns {
		if i > 0 { strings.write_byte(&b, '|') }
		strings.write_string(&b, "(?:")
		strings.write_string(&b, regex_escape(p) if fixed else p)
		strings.write_byte(&b, ')')
	}
	return strings.to_string(b)
}

// an unescaped `^` or `$` outside a class (a class's leading `^` negates it)
has_anchor :: proc(p: string) -> bool {
	in_class := false
	for i := 0; i < len(p); i += 1 {
		switch {
		case p[i] == '\\': i += 1
		case in_class: if p[i] == ']' { in_class = false }
		case p[i] == '[':
			in_class = true
			if i + 1 < len(p) && p[i + 1] == '^' { i += 1 }
			if i + 1 < len(p) && p[i + 1] == ']' { i += 1 }
		case p[i] == '^' || p[i] == '$': return true
		}
	}
	return false
}

// the first match in hay[start:end) that lies within one line
find_regex :: proc(r: ^Regex_Matcher, hay: []u8, start, end: int) -> (s, e: int, ok: bool) {
	if r.by_line {
		pos := start
		for {
			le := end
			if fwd, found := nvol.memchr('\n', hay[pos:end]); found { le = pos + fwd }
			if _, found := regex.match_with_preallocated_capture(r.line_rx, string(hay[pos:le]), &r.capture); found {
				return pos + r.capture.pos[0][0], pos + r.capture.pos[0][1], true
			}
			if le >= end { return }
			pos = le + 1
		}
	}
	pos := start
	for pos < end || (pos == start && start == end) {
		c := 0
		if f, has := &r.prefilter.?; has {
			i := nvol.memmem_find(f, hay[pos:end]) or_return
			c = pos + i
		} else {
			_, found := regex.match_with_preallocated_capture(r.buf_rx, string(hay[pos:end]), &r.capture)
			if !found { return }
			c = pos + r.capture.pos[0][0]
		}
		ls := pos
		if back, found := nvol.memrchr('\n', hay[pos:c]); found { ls = pos + back + 1 }
		le := end
		if fwd, found := nvol.memchr('\n', hay[c:end]); found { le = c + fwd }
		if _, found := regex.match_with_preallocated_capture(r.line_rx, string(hay[ls:le]), &r.capture); found {
			return ls + r.capture.pos[0][0], ls + r.capture.pos[0][1], true
		}
		if le >= end { return }
		pos = le + 1
	}
	return
}
