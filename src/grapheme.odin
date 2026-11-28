// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

// bstr 1.10.0's grapheme segmentation (src/unicode/grapheme.rs), which grep-printer uses for
// --max-columns-preview: the extended grapheme clusters of UAX #29, Table 1c. bstr searches a
// sparse DFA generated from the regex below (scripts/regex/grapheme.sh, built with
// `regex-cli generate serialize sparse dfa --minimize --start-kind anchored`); grepper
// compiles the same regex with its own engine and the Unicode tables of regex-syntax 0.8.4,
// and runs it anchored and leftmost-first on its lazy DFA.

GRAPHEME_REGEX :: `(?x)
\p{gcb=CR} \p{gcb=LF}
|
\p{gcb=Control}
|
\p{gcb=Prepend}*
(
  (
    (\p{gcb=L}* (\p{gcb=V}+ | \p{gcb=LV} \p{gcb=V}* | \p{gcb=LVT}) \p{gcb=T}*)
    |
    \p{gcb=L}+
    |
    \p{gcb=T}+
  )
  |
  \p{gcb=RI} \p{gcb=RI}
  |
  \p{Extended_Pictographic} (\p{gcb=Extend}* \p{gcb=ZWJ} \p{Extended_Pictographic})*
  |
  [^\p{gcb=Control} \p{gcb=CR} \p{gcb=LF}]
)
[\p{gcb=Extend} \p{gcb=ZWJ} \p{gcb=SpacingMark}]*
|
\p{any}
`

// one per printer (a worker's own): the DFA's cache is written as it searches
Grapheme_Segmenter :: struct {
	nfa:   ^Rx_NFA,
	dfa:   Lazy_Dfa,
	pike:  Pike_Cache,
	slots: []int,
}

grapheme_segmenter_new :: proc() -> ^Grapheme_Segmenter {
	ast, perr := regex_parse(GRAPHEME_REGEX)
	assert(perr == nil, "the grapheme regex parses")
	tr := Translator{pattern = GRAPHEME_REGEX, utf8 = true, line_terminator = '\n'}
	h, terr := translate(&tr, ast)
	assert(terr == nil, "the grapheme regex translates")
	g := new(Grapheme_Segmenter)
	g.nfa = new(Rx_NFA)
	g.nfa^ = rx_compile(h)
	rx_finish(g.nfa)
	g.dfa = dfa_new(g.nfa, .Leftmost_First, unanchored = false)
	// bstr's DFA is built ahead of time, so --dfa-size-limit never reaches it: this cache
	// keeps the default capacity whatever the flag says
	g.dfa.capacity = 1000 * (1 << 20)
	g.pike = pike_cache_new(g.nfa)
	g.slots = make([]int, g.nfa.slots)
	return g
}

// decode_grapheme: the length of the grapheme at the start of bs (0 when bs is empty). Two
// ASCII bytes, the first not whitespace, make a one-byte grapheme without the DFA (bstr's fast
// path); when the DFA finds nothing, bs starts with invalid UTF-8, and the grapheme is the
// U+FFFD that its maximal invalid prefix becomes (utf8::decode_lossy)
decode_grapheme :: proc(g: ^Grapheme_Segmenter, bs: []u8) -> int {
	if len(bs) == 0 { return 0 }
	if len(bs) >= 2 && bs[0] < 0x80 && bs[1] < 0x80 && !is_ascii_whitespace(bs[0]) { return 1 }
	at, r := dfa_find_fwd(&g.dfa, bs, 0, len(bs), anchored = true)
	if r == .Quit {
		r = .No_Match
		if pike_search(g.nfa, &g.pike, bs, 0, len(bs), true, g.slots) { at, r = g.slots[1], .Match }
	}
	if r == .Match && at > 0 { return at }
	return utf8_decode_lossy_len(bs)
}

// u8::is_ascii_whitespace: space, \t, \n, \x0C, \r (not \x0B)
@(private="file")
is_ascii_whitespace :: #force_inline proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == 0x0C || b == '\r'
}

// bstr's utf8::decode on invalid input: the bytes before the one its DFA rejects, at least 1,
// or every byte when the input ends inside a sequence (the maximal subpart of Unicode 3.9
// D93b, Table 3-7's ranges for the second byte)
utf8_decode_lossy_len :: proc(bs: []u8) -> int {
	if len(bs) == 0 { return 0 }
	b0 := bs[0]
	need: int
	lo, hi := u8(0x80), u8(0xBF)
	switch b0 {
	case 0x00 ..= 0x7F: return 1
	case 0xC2 ..= 0xDF: need = 1
	case 0xE0:          need, lo = 2, 0xA0
	case 0xED:          need, hi = 2, 0x9F
	case 0xE1 ..= 0xEC, 0xEE ..= 0xEF: need = 2
	case 0xF0:          need, lo = 3, 0x90
	case 0xF4:          need, hi = 3, 0x8F
	case 0xF1 ..= 0xF3: need = 3
	case:               return 1
	}
	i := 1
	for k in 0 ..< need {
		if i >= len(bs) { return i }
		b := bs[i]
		if k == 0 {
			if b < lo || b > hi { return i }
		} else if b < 0x80 || b > 0xBF {
			return i
		}
		i += 1
	}
	return i
}
