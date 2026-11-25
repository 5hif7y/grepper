// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:mem/virtual"
import "core:testing"

// regex-automata 0.4.18's unit tests of meta/reverse_suffix.rs, case for case. Patterns are
// parsed as its util::syntax::parse does (Unicode, UTF-8, no flags). Run with
//   odin test src -collection:nvol=vendor/NVOL/generated -define:ODIN_TEST_NAMES=grepper.test_reverse_suffix_proofs

@(private="file")
parse_default :: proc(pattern: string) -> ^Hir {
	ast, perr := regex_parse(pattern)
	if perr != nil { return nil }
	tr := Translator{pattern = pattern, utf8 = true, line_terminator = '\n'}
	h, terr := translate(&tr, ast)
	if terr != nil { return nil }
	return h
}

@(private="file")
check_strip :: proc(t: ^testing.T, pattern, suffix: string, expected: Maybe(string), loc := #caller_location) {
	h := parse_default(pattern)
	if !testing.expect(t, h != nil, pattern, loc = loc) { return }
	got, ok := strip_literal_suffix(h, transmute([]u8)suffix)
	want, has := expected.?
	if !has {
		testing.expectf(t, !ok, "strip %q from %q: expected none", suffix, pattern, loc = loc)
		return
	}
	if !testing.expectf(t, ok, "strip %q from %q: expected %q, got none", suffix, pattern, want, loc = loc) { return }
	testing.expectf(t, hir_equal(got, parse_default(want)), "strip %q from %q: not %q", suffix, pattern, want, loc = loc)
}

@(private="file")
check_fixed :: proc(t: ^testing.T, yes: bool, pattern, suffix: string, loc := #caller_location) {
	p, ok := strip_literal_suffix(parse_default(pattern), transmute([]u8)suffix)
	testing.expectf(t, (ok && prefix_hir_has_fixed_length(p)) == yes, "fixed length prefix of %q less %q: want %v", pattern, suffix, yes, loc = loc)
}

@(private="file")
check_internal :: proc(t: ^testing.T, yes: bool, pattern, suffix: string, loc := #caller_location) {
	p, ok := strip_literal_suffix(parse_default(pattern), transmute([]u8)suffix)
	testing.expectf(t, (ok && prefix_hir_can_contain_literal(p, transmute([]u8)suffix)) == yes, "internal suffix of %q less %q: want %v", pattern, suffix, yes, loc = loc)
}

@(test)
test_reverse_suffix_proofs :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) { return }
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// literal
	check_strip(t, "foobar", "bar", "foo")
	check_strip(t, "foobar", "foobar", "")
	check_strip(t, "foobar", "", "foobar")
	// capture
	check_strip(t, `.+foo(bar)`, "foobar", `.+`)
	// concat
	check_strip(t, `.+(?:ab){2}cd`, "ababcd", `.+`)
	check_strip(t, `a(?:)cd`, "acd", ``)
	check_strip(t, `az{0}cd`, "acd", ``)
	check_strip(t, `az{2}cd`, "acd", nil)
	check_strip(t, `az{0,2}cd`, "acd", nil)
	// repetition
	check_strip(t, `x(?:ab){3}`, "bab", "xaba")
	check_strip(t, `x(?:ab){2,}`, "bab", `x(?:ab)*a`)
	// mismatch
	check_strip(t, "foobar", "baz", nil)
	check_strip(t, "foobar", "xfoobar", nil)
	check_strip(t, `foo[a-z]`, "a", nil)
	// suffix_must_be_adjacent
	check_strip(t, `foo(xbar)`, "foobar", nil)
	// repetition_must_be_required
	check_strip(t, `x(?:ab)*cd`, "abcd", nil)
	// reverse_suffix_accepts_prefix_without_internal_suffix
	check_internal(t, false, `\d+XYZ`, "XYZ")
	check_internal(t, false, `[a-q][^u-z]{13}x`, "x")
	// reverse_suffix_accepts_fixed_length_prefix
	check_fixed(t, true, `(?:ab|cd)XYZ`, "XYZ")
	check_internal(t, true, `[A-Z][0-9]XYZ`, "XYZ")
	check_fixed(t, true, `[A-Z][0-9]XYZ`, "XYZ")
	// reverse_suffix_fixed_length_prefix_is_conservative
	check_fixed(t, false, `a{1,3}yy`, "yy")
	check_fixed(t, false, `a*yy`, "yy")
	// the case ripgrep 14.1.1 gets wrong: no proof holds, so no reverse suffix search
	testing.expect(t, !reverse_suffix_has_no_earlier_match(parse_default(`[a-c][^\n]*xz|z`), transmute([]u8)string("z")))
	// the separator proof: \s+ is disjoint from \w and from "Holmes" (prefix.rs's own example)
	testing.expect(t, reverse_suffix_has_no_earlier_match(parse_default(`\w+\s+Holmes`), transmute([]u8)string("Holmes")))
	// conservative: [A-Z] can hold the E of "Error", [a-z]+ its r and o, so no proof holds
	// (safe in fact; regex-automata 0.4.18 and ripgrep 16.0.0 also refuse it)
	testing.expect(t, !reverse_suffix_has_no_earlier_match(parse_default(`[A-Z][a-z]+Error`), transmute([]u8)string("Error")))
}
