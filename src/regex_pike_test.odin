// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:mem/virtual"
import "core:testing"

// The PikeVM against the bounded backtracker, slot for slot: both resolve leftmost-first
// capture groups, so on the same NFA and haystack they must agree on every slot, an unset
// group (-1) included. The printers cannot show the difference between an unset group and an
// empty one, so a capture slot the PikeVM's epsilon closure fails to restore (a group's start
// leaking from one alternative into the next) is only visible here. Run with
//   odin test src -collection:nvol=vendor/NVOL/generated -define:ODIN_TEST_NAMES=grepper.test_pike_slots

@(private="file")
parse_pike :: proc(pattern: string) -> ^Hir {
	ast, perr := regex_parse(pattern)
	if perr != nil { return nil }
	tr := Translator{pattern = pattern, utf8 = true, line_terminator = '\n'}
	h, terr := translate(&tr, ast)
	if terr != nil { return nil }
	return h
}

@(test)
test_pike_slots :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	patterns := []string{
		`(?:(a)b|ac)`, `(?:(a*)b|ac)`, `x(?:(a)|a)c`, `(a)|(b)|(c)`, `((a)|b)+`,
		`(?:(a)|b)*c`, `(\w+)\s+(\w+)`, `(a+)(b+)?`, `(?:(\d)|(\w))+`, `()a|b()`,
		`(a|ab)(c|bcd)(d*)`, `(?:(?:(a)|b)(?:(c)|d))+`, `\b(\w)(\w*)\b`, `(x)?y`,
		`^(a)?(?:b|(c))$`, `(?:(é)|e)+`, `((((a))))b|ab`,
	}
	haystacks := []string{"", "a", "ab", "ac", "xac", "abc", "abcd", "cab", "aab bb", "abab cd",
		"x y", "foo bar baz", "12ab3", "eé ée", "xy y", "bd ad bc", "aaab"}
	for pat in patterns {
		h := parse_pike(pat)
		if !testing.expectf(t, h != nil, "parse %q", pat) { continue }
		n := new(Rx_NFA)
		n^ = rx_compile(h)
		rx_finish(n)
		pc := pike_cache_new(n)
		bc := backtrack_cache_new(n)
		ps := make([]int, n.slots)
		bs := make([]int, n.slots)
		for hay in haystacks {
			hb := transmute([]u8)hay
			for start in 0 ..= len(hb) {
				pm := pike_search(n, &pc, hb, start, len(hb), false, ps)
				bm := backtrack_search(n, &bc, hb, start, len(hb), bs)
				if !testing.expectf(t, pm == bm, "%q on %q from %d: PikeVM %v, backtracker %v", pat, hay, start, pm, bm) { continue }
				if !pm { continue }
				for i in 0 ..< n.slots {
					if ps[i] != bs[i] {
						testing.expectf(t, false, "%q on %q from %d: slots %v (PikeVM) vs %v (backtracker)", pat, hay, start, ps, bs)
						break
					}
				}
			}
		}
	}
}
