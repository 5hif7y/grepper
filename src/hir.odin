// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:slice"
import "core:unicode/utf8"

// regex-syntax 0.8.4's high-level intermediate representation (src/hir/mod.rs and
// src/hir/interval.rs): classes as canonical interval sets (of code points or of bytes), the
// smart constructors that flatten and simplify as they build (literals merged in a concat,
// single-character alternations turned into a class, common prefixes lifted), and the
// properties the automata and the literal extraction read.

// ---------------------------------------------------------------------------------------------
// Interval sets. A Unicode class's bounds are scalar values (the surrogates skipped when
// stepping), a byte class's are 0..255.

Class_Range :: struct {
	lo, hi: u32,
}

Hir_Class :: struct {
	unicode: bool,
	ranges:  [dynamic]Class_Range,
	folded:  bool,
}

@(private="file")
bound_max :: #force_inline proc(c: ^Hir_Class) -> u32 { return 0x10FFFF if c.unicode else 0xFF }

@(private="file")
bound_inc :: proc(c: ^Hir_Class, x: u32) -> u32 {
	if c.unicode && x == 0xD7FF { return 0xE000 }
	return x + 1
}

@(private="file")
bound_dec :: proc(c: ^Hir_Class, x: u32) -> u32 {
	if c.unicode && x == 0xE000 { return 0xD7FF }
	return x - 1
}

class_new :: proc(unicode: bool, ranges: []Class_Range) -> (c: Hir_Class) {
	c.unicode = unicode
	append(&c.ranges, ..ranges)
	c.folded = len(ranges) == 0
	class_canonicalize(&c)
	return
}

class_clone :: proc(c: Hir_Class) -> (d: Hir_Class) {
	d = c
	d.ranges = slice.clone_to_dynamic(c.ranges[:])
	return
}

class_push :: proc(c: ^Hir_Class, r: Class_Range) {
	append(&c.ranges, Class_Range{min(r.lo, r.hi), max(r.lo, r.hi)})
	class_canonicalize(c)
	c.folded = false
}

@(private="file")
is_contiguous :: proc(a, b: Class_Range) -> bool {
	return max(a.lo, b.lo) <= min(a.hi, b.hi) + 1
}

class_canonicalize :: proc(c: ^Hir_Class) {
	rs := c.ranges[:]
	canonical := true
	for i in 1 ..< len(rs) {
		a, b := rs[i - 1], rs[i]
		if !(a.lo < b.lo || (a.lo == b.lo && a.hi < b.hi)) || is_contiguous(a, b) { canonical = false; break }
	}
	if canonical { return }
	slice.sort_by(rs, proc(a, b: Class_Range) -> bool { return a.lo < b.lo || (a.lo == b.lo && a.hi < b.hi) })
	out := make([dynamic]Class_Range, 0, len(rs))
	for r in rs {
		if n := len(out); n > 0 && is_contiguous(out[n - 1], r) {
			out[n - 1] = {min(out[n - 1].lo, r.lo), max(out[n - 1].hi, r.hi)}
			continue
		}
		append(&out, r)
	}
	delete(c.ranges)
	c.ranges = out
}

class_union :: proc(c: ^Hir_Class, o: Hir_Class) {
	if len(o.ranges) == 0 || slice.equal(c.ranges[:], o.ranges[:]) { return }
	append(&c.ranges, ..o.ranges[:])
	class_canonicalize(c)
	c.folded = c.folded && o.folded
}

class_intersect :: proc(c: ^Hir_Class, o: Hir_Class) {
	if len(c.ranges) == 0 { return }
	if len(o.ranges) == 0 {
		clear(&c.ranges)
		c.folded = true
		return
	}
	out: [dynamic]Class_Range
	a, b := 0, 0
	for {
		lo := max(c.ranges[a].lo, o.ranges[b].lo)
		hi := min(c.ranges[a].hi, o.ranges[b].hi)
		if lo <= hi { append(&out, Class_Range{lo, hi}) }
		if c.ranges[a].hi < o.ranges[b].hi {
			a += 1
			if a >= len(c.ranges) { break }
		} else {
			b += 1
			if b >= len(o.ranges) { break }
		}
	}
	delete(c.ranges)
	c.ranges = out
	c.folded = c.folded && o.folded
}

class_difference :: proc(c: ^Hir_Class, o: Hir_Class) {
	if len(c.ranges) == 0 || len(o.ranges) == 0 { return }
	out: [dynamic]Class_Range
	a, b := 0, 0
	outer: for a < len(c.ranges) && b < len(o.ranges) {
		if o.ranges[b].hi < c.ranges[a].lo { b += 1; continue }
		if c.ranges[a].hi < o.ranges[b].lo {
			append(&out, c.ranges[a])
			a += 1
			continue
		}
		r := c.ranges[a]
		for b < len(o.ranges) && max(r.lo, o.ranges[b].lo) <= min(r.hi, o.ranges[b].hi) {
			old := r
			x := o.ranges[b]
			// Interval::difference
			if x.lo <= r.lo && r.hi <= x.hi {
				a += 1
				continue outer
			}
			add_lower := x.lo > r.lo
			add_upper := x.hi < r.hi
			r1, r2: Maybe(Class_Range)
			if add_lower { r1 = Class_Range{r.lo, bound_dec(c, x.lo)} }
			if add_upper {
				up := Class_Range{bound_inc(c, x.hi), r.hi}
				if r1 == nil { r1 = up } else { r2 = up }
			}
			if v2, has2 := r2.?; has2 {
				append(&out, r1.?)
				r = v2
			} else {
				r = r1.?
			}
			if x.hi > old.hi { break }
			b += 1
		}
		append(&out, r)
		a += 1
	}
	for ; a < len(c.ranges); a += 1 { append(&out, c.ranges[a]) }
	delete(c.ranges)
	c.ranges = out
	c.folded = c.folded && o.folded
}

class_symmetric_difference :: proc(c: ^Hir_Class, o: Hir_Class) {
	inter := class_clone(c^)
	class_intersect(&inter, o)
	class_union(c, o)
	class_difference(c, inter)
}

class_negate :: proc(c: ^Hir_Class) {
	mx := bound_max(c)
	if len(c.ranges) == 0 {
		append(&c.ranges, Class_Range{0, mx})
		c.folded = true
		return
	}
	out: [dynamic]Class_Range
	if c.ranges[0].lo > 0 { append(&out, Class_Range{0, bound_dec(c, c.ranges[0].lo)}) }
	for i in 1 ..< len(c.ranges) {
		append(&out, Class_Range{bound_inc(c, c.ranges[i - 1].hi), bound_dec(c, c.ranges[i].lo)})
	}
	if last := c.ranges[len(c.ranges) - 1].hi; last < mx {
		append(&out, Class_Range{bound_inc(c, last), mx})
	}
	delete(c.ranges)
	c.ranges = out
}

// IntervalSet::case_fold_simple: every range's simple case mappings added
class_case_fold_simple :: proc(c: ^Hir_Class) {
	if c.folded { return }
	n := len(c.ranges)
	for i in 0 ..< n {
		r := c.ranges[i]
		if c.unicode {
			if !case_fold_overlaps(rune(r.lo), rune(r.hi)) { continue }
			for cp := r.lo; cp <= r.hi; cp += 1 {
				if cp >= 0xD800 && cp <= 0xDFFF { continue }
				for f in case_fold_mapping(rune(cp)) {
					append(&c.ranges, Class_Range{u32(f), u32(f)})
				}
			}
		} else {
			if max(r.lo, 'a') <= min(r.hi, 'z') {
				append(&c.ranges, Class_Range{max(r.lo, 'a') - 32, min(r.hi, 'z') - 32})
			}
			if max(r.lo, 'A') <= min(r.hi, 'Z') {
				append(&c.ranges, Class_Range{max(r.lo, 'A') + 32, min(r.hi, 'Z') + 32})
			}
		}
	}
	class_canonicalize(c)
	c.folded = true
}

// the simple case folding table's entries for c (empty when it has none)
case_fold_mapping :: proc(c: rune) -> []rune {
	lo, hi := 0, len(UT_CASE_FOLD)
	for lo < hi {
		mid := (lo + hi) / 2
		if UT_CASE_FOLD[mid].c < c { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(UT_CASE_FOLD) && UT_CASE_FOLD[lo].c == c {
		e := UT_CASE_FOLD[lo]
		return UT_CASE_FOLD_TO[e.start:e.start + e.count]
	}
	return nil
}

// SimpleCaseFolder::overlaps: some code point in [start, end] has a mapping
case_fold_overlaps :: proc(start, end: rune) -> bool {
	lo, hi := 0, len(UT_CASE_FOLD)
	for lo < hi {
		mid := (lo + hi) / 2
		if UT_CASE_FOLD[mid].c < start { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(UT_CASE_FOLD) && UT_CASE_FOLD[lo].c <= end
}

class_is_ascii :: proc(c: Hir_Class) -> bool {
	return len(c.ranges) == 0 || c.ranges[len(c.ranges) - 1].hi <= 0x7F
}

class_is_utf8 :: proc(c: Hir_Class) -> bool { return c.unicode || class_is_ascii(c) }

class_minimum_len :: proc(c: Hir_Class) -> Maybe(int) {
	if len(c.ranges) == 0 { return nil }
	return utf8_len(c.ranges[0].lo) if c.unicode else 1
}

class_maximum_len :: proc(c: Hir_Class) -> Maybe(int) {
	if len(c.ranges) == 0 { return nil }
	return utf8_len(c.ranges[len(c.ranges) - 1].hi) if c.unicode else 1
}

utf8_len :: proc(cp: u32) -> int {
	switch {
	case cp < 0x80: return 1
	case cp < 0x800: return 2
	case cp < 0x10000: return 3
	}
	return 4
}

// the class as a literal when it holds a single code point or byte
class_literal :: proc(c: Hir_Class) -> (lit: []u8, ok: bool) {
	if len(c.ranges) != 1 || c.ranges[0].lo != c.ranges[0].hi { return }
	if c.unicode {
		buf, n := utf8.encode_rune(rune(c.ranges[0].lo))
		return slice.clone(buf[:n]), true
	}
	return slice.clone([]u8{u8(c.ranges[0].lo)}), true
}

class_to_bytes :: proc(c: Hir_Class) -> (b: Hir_Class, ok: bool) {
	if !class_is_ascii(c) { return }
	b = class_clone(c)
	b.unicode = false
	return b, true
}

class_to_unicode :: proc(c: Hir_Class) -> (u: Hir_Class, ok: bool) {
	if !class_is_ascii(c) { return }
	u = class_clone(c)
	u.unicode = true
	return u, true
}

// ---------------------------------------------------------------------------------------------
// Look-around assertions, as bits (Look's repr)

Look :: enum u32 {
	Start = 1 << 0, End = 1 << 1, Start_LF = 1 << 2, End_LF = 1 << 3, Start_CRLF = 1 << 4, End_CRLF = 1 << 5,
	Word_Ascii = 1 << 6, Word_Ascii_Negate = 1 << 7, Word_Unicode = 1 << 8, Word_Unicode_Negate = 1 << 9,
	Word_Start_Ascii = 1 << 10, Word_End_Ascii = 1 << 11, Word_Start_Unicode = 1 << 12, Word_End_Unicode = 1 << 13,
	Word_Start_Half_Ascii = 1 << 14, Word_End_Half_Ascii = 1 << 15, Word_Start_Half_Unicode = 1 << 16, Word_End_Half_Unicode = 1 << 17,
}

Look_Set :: u32

look_set_contains :: #force_inline proc(s: Look_Set, l: Look) -> bool { return s & u32(l) != 0 }

look_set_contains_anchor_haystack :: proc(s: Look_Set) -> bool {
	return look_set_contains(s, .Start) || look_set_contains(s, .End)
}

look_set_contains_word_unicode :: proc(s: Look_Set) -> bool {
	return s & (u32(Look.Word_Unicode) | u32(Look.Word_Unicode_Negate) | u32(Look.Word_Start_Unicode) | u32(Look.Word_End_Unicode) | u32(Look.Word_Start_Half_Unicode) | u32(Look.Word_End_Half_Unicode)) != 0
}

// ---------------------------------------------------------------------------------------------
// The HIR

Hir_Kind :: enum { Empty, Literal, Class, Look, Repetition, Capture, Concat, Alternation }

Hir_Props :: struct {
	minimum_len:                  Maybe(int),
	maximum_len:                  Maybe(int),
	look_set:                     Look_Set,
	look_set_prefix:              Look_Set,
	look_set_suffix:              Look_Set,
	look_set_prefix_any:          Look_Set,
	look_set_suffix_any:          Look_Set,
	utf8:                         bool,
	explicit_captures_len:        int,
	static_explicit_captures_len: Maybe(int),
	literal:                      bool,
	alternation_literal:          bool,
}

Hir :: struct {
	kind:   Hir_Kind,
	props:  Hir_Props,
	lit:    []u8,
	class:  Hir_Class,
	look:   Look,
	// Repetition
	min:    u32,
	max:    Maybe(u32),
	greedy: bool,
	// Capture
	index:  u32,
	name:   Maybe(string),
	sub:    ^Hir,
	subs:   [dynamic]^Hir,
}

@(private="file")
mk :: proc(h: Hir) -> ^Hir {
	p := new(Hir)
	p^ = h
	return p
}

hir_empty :: proc() -> ^Hir {
	return mk({kind = .Empty, props = {minimum_len = 0, maximum_len = 0, utf8 = true, static_explicit_captures_len = 0}})
}

hir_fail :: proc() -> ^Hir {
	c := class_new(false, nil)
	return mk({kind = .Class, class = c, props = props_class(c)})
}

hir_literal :: proc(bytes: []u8) -> ^Hir {
	if len(bytes) == 0 { return hir_empty() }
	return mk({kind = .Literal, lit = bytes, props = {
		minimum_len = len(bytes), maximum_len = len(bytes), utf8 = utf8_valid(bytes),
		static_explicit_captures_len = 0, literal = true, alternation_literal = true,
	}})
}

@(private="file")
props_class :: proc(c: Hir_Class) -> Hir_Props {
	return {minimum_len = class_minimum_len(c), maximum_len = class_maximum_len(c), utf8 = class_is_utf8(c), static_explicit_captures_len = 0}
}

hir_class :: proc(c: Hir_Class) -> ^Hir {
	if len(c.ranges) == 0 { return hir_fail() }
	if lit, ok := class_literal(c); ok { return hir_literal(lit) }
	return mk({kind = .Class, class = c, props = props_class(c)})
}

hir_look :: proc(l: Look) -> ^Hir {
	s := u32(l)
	return mk({kind = .Look, look = l, props = {
		minimum_len = 0, maximum_len = 0, look_set = s, look_set_prefix = s, look_set_suffix = s,
		look_set_prefix_any = s, look_set_suffix_any = s, utf8 = true, static_explicit_captures_len = 0,
	}})
}

// Hir::repetition
hir_rep :: proc(min_: u32, max_: Maybe(u32), greedy: bool, sub: ^Hir) -> ^Hir {
	mn, mx := min_, max_
	if ml, ok := sub.props.maximum_len.?; ok && ml == 0 {
		mn = min(mn, 1)
		if m, has := mx.?; has { mx = min(m, 1) } else { mx = 1 }
	}
	if m, has := mx.?; has {
		if mn == 0 && m == 0 { return hir_empty() }
		if mn == 1 && m == 1 { return sub }
	}
	p := sub.props
	props := Hir_Props{
		look_set = p.look_set,
		look_set_prefix_any = p.look_set_prefix_any,
		look_set_suffix_any = p.look_set_suffix_any,
		utf8 = p.utf8,
		explicit_captures_len = p.explicit_captures_len,
		static_explicit_captures_len = p.static_explicit_captures_len,
	}
	if cm, ok := p.minimum_len.?; ok { props.minimum_len = sat_mul(cm, int(mn)) }
	if m, has := mx.?; has {
		if cm, ok := p.maximum_len.?; ok {
			if v, okm := checked_mul(cm, int(m)); okm { props.maximum_len = v }
		}
	}
	if mn > 0 {
		props.look_set_prefix = p.look_set_prefix
		props.look_set_suffix = p.look_set_suffix
	}
	if sl, ok := props.static_explicit_captures_len.?; mn == 0 && ok && sl > 0 {
		if m, has := mx.?; has && m == 0 { props.static_explicit_captures_len = 0 } else { props.static_explicit_captures_len = nil }
	}
	return mk({kind = .Repetition, min = mn, max = mx, greedy = greedy, sub = sub, props = props})
}

sat_mul :: proc(a, b: int) -> int {
	if a != 0 && b > max(int) / a { return max(int) }
	return a * b
}

checked_mul :: proc(a, b: int) -> (int, bool) {
	if a != 0 && b > max(int) / a { return 0, false }
	return a * b, true
}

hir_capture :: proc(index: u32, name: Maybe(string), sub: ^Hir) -> ^Hir {
	p := sub.props
	p.explicit_captures_len += 1
	if s, ok := p.static_explicit_captures_len.?; ok { p.static_explicit_captures_len = s + 1 }
	p.literal = false
	p.alternation_literal = false
	return mk({kind = .Capture, index = index, name = name, sub = sub, props = p})
}

// Hir::concat: nested concats flattened, empties dropped, adjacent literals merged
hir_concat :: proc(subs: []^Hir) -> ^Hir {
	out: [dynamic]^Hir
	prior: [dynamic]u8
	has_prior := false
	flush :: proc(out: ^[dynamic]^Hir, prior: ^[dynamic]u8, has_prior: ^bool) {
		if has_prior^ {
			append(out, hir_literal(slice.clone(prior[:])))
			clear(prior)
			has_prior^ = false
		}
	}
	add :: proc(out: ^[dynamic]^Hir, prior: ^[dynamic]u8, has_prior: ^bool, h: ^Hir) {
		#partial switch h.kind {
		case .Literal:
			append(prior, ..h.lit)
			has_prior^ = true
		case .Empty:
		case:
			flush(out, prior, has_prior)
			append(out, h)
		}
	}
	for sub in subs {
		if sub.kind == .Concat {
			for s2 in sub.subs {
				if s2.kind == .Literal {
					append(&prior, ..s2.lit)
					has_prior = true
				} else {
					flush(&out, &prior, &has_prior)
					append(&out, s2)
				}
			}
			continue
		}
		add(&out, &prior, &has_prior, sub)
	}
	flush(&out, &prior, &has_prior)
	if len(out) == 0 { return hir_empty() }
	if len(out) == 1 { return out[0] }
	return mk({kind = .Concat, subs = out, props = props_concat(out[:])})
}

@(private="file")
props_concat :: proc(xs: []^Hir) -> Hir_Props {
	props := Hir_Props{minimum_len = 0, maximum_len = 0, utf8 = true, static_explicit_captures_len = 0, literal = true, alternation_literal = true}
	for x in xs {
		p := x.props
		props.look_set |= p.look_set
		props.utf8 = props.utf8 && p.utf8
		props.explicit_captures_len += p.explicit_captures_len
		a, aok := p.static_explicit_captures_len.?
		b, bok := props.static_explicit_captures_len.?
		if aok && bok { props.static_explicit_captures_len = a + b } else { props.static_explicit_captures_len = nil }
		props.literal = props.literal && p.literal
		props.alternation_literal = props.alternation_literal && p.alternation_literal
		if mn, ok := props.minimum_len.?; ok {
			if l, lok := p.minimum_len.?; lok { props.minimum_len = mn + l } else { props.minimum_len = nil }
		}
		if mx, ok := props.maximum_len.?; ok {
			if l, lok := p.maximum_len.?; lok { props.maximum_len = mx + l } else { props.maximum_len = nil }
		}
	}
	for x in xs {
		props.look_set_prefix |= x.props.look_set_prefix
		props.look_set_prefix_any |= x.props.look_set_prefix_any
		if ml, ok := x.props.maximum_len.?; !ok || ml > 0 { break }
	}
	#reverse for x in xs {
		props.look_set_suffix |= x.props.look_set_suffix
		props.look_set_suffix_any |= x.props.look_set_suffix_any
		if ml, ok := x.props.maximum_len.?; !ok || ml > 0 { break }
	}
	return props
}

// Properties::union, for alternations
@(private="file")
props_union :: proc(xs: []^Hir) -> Hir_Props {
	fix: Look_Set = 0 if len(xs) == 0 else ~u32(0)
	props := Hir_Props{look_set_prefix = fix, look_set_suffix = fix, utf8 = true, alternation_literal = true}
	if len(xs) > 0 { props.static_explicit_captures_len = xs[0].props.static_explicit_captures_len }
	min_poisoned, max_poisoned := false, false
	for x in xs {
		p := x.props
		props.look_set |= p.look_set
		props.look_set_prefix &= p.look_set_prefix
		props.look_set_suffix &= p.look_set_suffix
		props.look_set_prefix_any |= p.look_set_prefix_any
		props.look_set_suffix_any |= p.look_set_suffix_any
		props.utf8 = props.utf8 && p.utf8
		props.explicit_captures_len += p.explicit_captures_len
		if props.static_explicit_captures_len != p.static_explicit_captures_len { props.static_explicit_captures_len = nil }
		props.alternation_literal = props.alternation_literal && p.literal
		if !min_poisoned {
			if xmin, ok := p.minimum_len.?; ok {
				if pmin, has := props.minimum_len.?; !has || xmin < pmin { props.minimum_len = xmin }
			} else {
				props.minimum_len = nil
				min_poisoned = true
			}
		}
		if !max_poisoned {
			if xmax, ok := p.maximum_len.?; ok {
				if pmax, has := props.maximum_len.?; !has || xmax > pmax { props.maximum_len = xmax }
			} else {
				props.maximum_len = nil
				max_poisoned = true
			}
		}
	}
	return props
}

// Hir::alternation
hir_alternation :: proc(subs: []^Hir) -> ^Hir {
	out: [dynamic]^Hir
	for s in subs {
		if s.kind == .Alternation { append(&out, ..s.subs[:]) } else { append(&out, s) }
	}
	if len(out) == 0 { return hir_fail() }
	if len(out) == 1 { return out[0] }
	// singleton_chars: every branch a single UTF-8 encoded code point
	{
		cls := Hir_Class{unicode = true}
		ok := true
		for h in out {
			if h.kind != .Literal { ok = false; break }
			r, n := utf8.decode_rune(h.lit)
			if len(h.lit) == 0 || (r == utf8.RUNE_ERROR && n <= 1) { ok = false; break }
			if n != len(h.lit) { ok = false; break }
			append(&cls.ranges, Class_Range{u32(r), u32(r)})
		}
		if ok {
			class_canonicalize(&cls)
			return hir_class(cls)
		}
		delete(cls.ranges)
	}
	// singleton_bytes
	{
		cls := Hir_Class{}
		ok := true
		for h in out {
			if h.kind != .Literal || len(h.lit) != 1 { ok = false; break }
			append(&cls.ranges, Class_Range{u32(h.lit[0]), u32(h.lit[0])})
		}
		if ok {
			class_canonicalize(&cls)
			return hir_class(cls)
		}
		delete(cls.ranges)
	}
	// class_chars, then class_bytes: every branch a class
	{
		cls := Hir_Class{unicode = true}
		ok := true
		for h in out {
			if h.kind != .Class { ok = false; break }
			if h.class.unicode {
				class_union(&cls, h.class)
			} else {
				u, uok := class_to_unicode(h.class)
				if !uok { ok = false; break }
				class_union(&cls, u)
			}
		}
		if ok { return hir_class(cls) }
	}
	{
		cls := Hir_Class{}
		ok := true
		for h in out {
			if h.kind != .Class { ok = false; break }
			if !h.class.unicode {
				class_union(&cls, h.class)
			} else {
				b, bok := class_to_bytes(h.class)
				if !bok { ok = false; break }
				class_union(&cls, b)
			}
		}
		if ok { return hir_class(cls) }
	}
	if lifted, ok := lift_common_prefix(out[:]); ok { return lifted }
	return mk({kind = .Alternation, subs = out, props = props_union(out[:])})
}

@(private="file")
lift_common_prefix :: proc(hirs: []^Hir) -> (h: ^Hir, ok: bool) {
	if len(hirs) <= 1 || hirs[0].kind != .Concat { return }
	prefix := hirs[0].subs[:]
	if len(prefix) == 0 { return }
	for x in hirs[1:] {
		if x.kind != .Concat { return }
		n := 0
		for n < len(prefix) && n < len(x.subs) && hir_equal(prefix[n], x.subs[n]) { n += 1 }
		prefix = prefix[:n]
		if len(prefix) == 0 { return }
	}
	n := len(prefix)
	suffix_alts: [dynamic]^Hir
	for x in hirs { append(&suffix_alts, hir_concat(x.subs[n:])) }
	concat: [dynamic]^Hir
	append(&concat, ..hirs[0].subs[:n])
	append(&concat, hir_alternation(suffix_alts[:]))
	return hir_concat(concat[:]), true
}

// structural equality (Hir's derived PartialEq; the properties follow from the structure)
hir_equal :: proc(a, b: ^Hir) -> bool {
	if a.kind != b.kind { return false }
	switch a.kind {
	case .Empty: return true
	case .Literal: return slice.equal(a.lit, b.lit)
	case .Class: return a.class.unicode == b.class.unicode && slice.equal(a.class.ranges[:], b.class.ranges[:])
	case .Look: return a.look == b.look
	case .Repetition: return a.min == b.min && a.max == b.max && a.greedy == b.greedy && hir_equal(a.sub, b.sub)
	case .Capture: return a.index == b.index && a.name == b.name && hir_equal(a.sub, b.sub)
	case .Concat, .Alternation:
		if len(a.subs) != len(b.subs) { return false }
		for s, i in a.subs { if !hir_equal(s, b.subs[i]) { return false } }
		return true
	}
	return false
}

Dot_Kind :: enum { Any_Char, Any_Byte, Any_Char_Except, Any_Char_Except_CRLF, Any_Byte_Except, Any_Byte_Except_CRLF }

hir_dot :: proc(d: Dot_Kind, except: u32 = 0) -> ^Hir {
	switch d {
	case .Any_Char: return hir_class(class_new(true, {{0, 0x10FFFF}}))
	case .Any_Byte: return hir_class(class_new(false, {{0, 0xFF}}))
	case .Any_Char_Except:
		c := class_new(true, {{except, except}})
		class_negate(&c)
		return hir_class(c)
	case .Any_Char_Except_CRLF: return hir_class(class_new(true, {{0, 0x09}, {0x0B, 0x0C}, {0x0E, 0x10FFFF}}))
	case .Any_Byte_Except:
		c := class_new(false, {{except, except}})
		class_negate(&c)
		return hir_class(c)
	case .Any_Byte_Except_CRLF: return hir_class(class_new(false, {{0, 0x09}, {0x0B, 0x0C}, {0x0E, 0xFF}}))
	}
	return nil
}
