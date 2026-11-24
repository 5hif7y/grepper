// Copyright (c) 2026 Matías Alemán (5hif7y). SPDX-License-Identifier: MIT
package grepper

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// The Odin side of tests/literal_oracle.py: every pattern of $LITERAL_ORACLE_PATTERNS (one per
// line) parsed and translated the way build_matcher does for a plain `rg PATTERN` (no line
// terminator stripping), its literals extracted, written to $LITERAL_ORACLE_OUT in the format
// of tools/literal_oracle (see its main.rs). Without the variables the test does nothing.

@(private="file")
oracle_fmt_seq :: proc(b: ^strings.Builder, s: Seq) {
	if !s.finite {
		strings.write_string(b, "INF")
		return
	}
	strings.write_byte(b, '[')
	for l, i in s.lits {
		if i > 0 { strings.write_byte(b, ' ') }
		strings.write_byte(b, 'E' if l.exact else 'I')
		oracle_quote(b, l.bytes[:])
	}
	strings.write_byte(b, ']')
}

@(private="file")
oracle_quote :: proc(b: ^strings.Builder, bytes: []u8) {
	strings.write_byte(b, '"')
	for c in bytes {
		if c >= 0x21 && c <= 0x7E && c != '"' && c != '\\' {
			strings.write_byte(b, c)
		} else {
			fmt.sbprintf(b, "\\x%02X", c)
		}
	}
	strings.write_byte(b, '"')
}

@(private="file")
oracle_fmt_bytes :: proc(b: ^strings.Builder, bytes: []u8, ok: bool) {
	if ok { oracle_quote(b, bytes) } else { strings.write_byte(b, '-') }
}

@(private="file")
oracle_fmt_opt :: proc(b: ^strings.Builder, n: int, ok: bool) {
	if ok { fmt.sbprintf(b, "%d", n) } else { strings.write_byte(b, '-') }
}

// the remaining Seq methods, on PRE and SUF (the oracle's extras)
@(private="file")
oracle_extras :: proc(out: ^strings.Builder, i: int, pre, suf: Seq) {
	s := seq_clone(pre)
	seq_minimize_by_preference(&s)
	fmt.sbprintf(out, "%d MIN ", i)
	oracle_fmt_seq(out, s)
	s = seq_clone(suf)
	seq_sort(&s)
	fmt.sbprintf(out, "\n%d SORT ", i)
	oracle_fmt_seq(out, s)
	s = seq_clone(suf)
	seq_reverse_literals(&s)
	fmt.sbprintf(out, "\n%d REV ", i)
	oracle_fmt_seq(out, s)
	s = seq_clone(pre)
	o := seq_clone(suf)
	seq_union_into_empty(&s, &o)
	fmt.sbprintf(out, "\n%d UIE ", i)
	oracle_fmt_seq(out, s)
	strings.write_byte(out, ' ')
	oracle_fmt_seq(out, o)
	if n, ok := seq_max_cross_len(pre, suf); !ok || n <= 400 {
		s = seq_clone(pre)
		o = seq_clone(suf)
		seq_cross_forward(&s, &o)
		fmt.sbprintf(out, "\n%d XF ", i)
		oracle_fmt_seq(out, s)
		strings.write_byte(out, ' ')
		oracle_fmt_seq(out, o)
		s = seq_clone(pre)
		o = seq_clone(suf)
		seq_cross_reverse(&s, &o)
		fmt.sbprintf(out, "\n%d XR ", i)
		oracle_fmt_seq(out, s)
		strings.write_byte(out, ' ')
		oracle_fmt_seq(out, o)
	}
	u := seq_clone(pre)
	o = seq_clone(suf)
	seq_union(&u, &o)
	fmt.sbprintf(out, "\n%d INFO len=", i)
	oracle_fmt_opt(out, seq_len(pre))
	strings.write_string(out, " min=")
	oracle_fmt_opt(out, seq_min_literal_len(pre))
	strings.write_string(out, " max=")
	oracle_fmt_opt(out, seq_max_literal_len(pre))
	fmt.sbprintf(out, " exact=%d inexact=%d empty=%d lcp=", int(seq_is_exact(pre)), int(seq_is_inexact(pre)), int(seq_is_empty(pre)))
	oracle_fmt_bytes(out, seq_longest_common_prefix(pre))
	strings.write_string(out, " lcs=")
	oracle_fmt_bytes(out, seq_longest_common_suffix(suf))
	strings.write_string(out, " ulen=")
	oracle_fmt_opt(out, seq_max_union_len(pre, suf))
	strings.write_string(out, " xlen=")
	oracle_fmt_opt(out, seq_max_cross_len(pre, suf))
	strings.write_string(out, " union=")
	oracle_fmt_seq(out, u)
	strings.write_byte(out, '\n')
}

@(test)
test_literal_oracle :: proc(t: ^testing.T) {
	in_path := os.get_env("LITERAL_ORACLE_PATTERNS", context.allocator)
	out_path := os.get_env("LITERAL_ORACLE_OUT", context.allocator)
	defer delete(in_path)
	defer delete(out_path)
	if in_path == "" || out_path == "" { return }
	data, rerr := os.read_entire_file(in_path, context.allocator)
	if !testing.expect(t, rerr == nil, "cannot read the pattern file") { return }
	defer delete(data)

	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) { return }
	defer virtual.arena_destroy(&arena)

	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	lines := strings.split(string(data), "\n")
	defer delete(lines)
	for line, i in lines {
		if i + 1 == len(lines) && line == "" { break }
		pat := strings.trim_suffix(line, "\r")
		{
			context.allocator = virtual.arena_allocator(&arena)
			defer virtual.arena_free_all(&arena)
			ast, perr := regex_parse(pat)
			if perr != nil {
				fmt.sbprintf(&out, "%d ERR\n", i)
				continue
			}
			tr := Translator{pattern = pat, utf8 = false, line_terminator = '\n'}
			tr.flags.multi_line = true
			hir, terr := translate(&tr, ast)
			if terr != nil {
				fmt.sbprintf(&out, "%d ERR\n", i)
				continue
			}
			pre_ex := extractor_new(.Prefix)
			suf_ex := extractor_new(.Suffix)
			pre := extractor_extract(&pre_ex, hir)
			suf := extractor_extract(&suf_ex, hir)
			opre := seq_clone(pre)
			seq_optimize_for_prefix_by_preference(&opre)
			osuf := seq_clone(suf)
			seq_optimize_for_suffix_by_preference(&osuf)
			names := [4]string{"PRE", "SUF", "OPRE", "OSUF"}
			seqs := [4]Seq{pre, suf, opre, osuf}
			for s, k in seqs {
				fmt.sbprintf(&out, "%d %s ", i, names[k])
				oracle_fmt_seq(&out, s)
				strings.write_byte(&out, '\n')
			}
			oracle_extras(&out, i, pre, suf)
		}
	}
	werr := os.write_entire_file(out_path, out.buf[:])
	testing.expect(t, werr == nil, "cannot write the output file")
}
