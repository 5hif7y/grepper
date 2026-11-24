// Literal extraction oracle: regex-syntax 0.8.4's Extractor over every pattern of a file (one
// per line), printed as
//
//     <index> PRE  <seq>      prefix extraction
//     <index> SUF  <seq>      suffix extraction
//     <index> OPRE <seq>      prefix extraction after optimize_for_prefix_by_preference
//     <index> OSUF <seq>      suffix extraction after optimize_for_suffix_by_preference
//     <index> ERR             the pattern does not parse
//
// where <seq> is INF or [lit lit ...], a lit E"..." (exact) or I"..." (inexact) with bytes
// 0x21..0x7E other than `"` and `\` raw and every other byte as \xHH. `--hir` adds a
// `<index> HIR <debug>` line. The remaining Seq methods are exercised on PRE and SUF by the
// MIN, SORT, REV, UIE, XF, XR and INFO lines (see extras). src/hir_literal_test.odin prints
// the same format.

use std::io::Write;

use regex_syntax::hir::literal::{ExtractKind, Extractor, Seq};
use regex_syntax::ParserBuilder;

fn fmt_seq(seq: &Seq) -> String {
    let lits = match seq.literals() {
        None => return "INF".to_string(),
        Some(lits) => lits,
    };
    let mut s = String::from("[");
    for (i, lit) in lits.iter().enumerate() {
        if i > 0 {
            s.push(' ');
        }
        s.push(if lit.is_exact() { 'E' } else { 'I' });
        s.push_str(&quote(lit.as_bytes()));
    }
    s.push(']');
    s
}

fn quote(bytes: &[u8]) -> String {
    let mut s = String::from("\"");
    for &b in bytes {
        if (0x21..=0x7E).contains(&b) && b != b'"' && b != b'\\' {
            s.push(b as char);
        } else {
            s.push_str(&format!("\\x{:02X}", b));
        }
    }
    s.push('"');
    s
}

fn fmt_bytes(b: Option<&[u8]>) -> String {
    match b {
        None => "-".to_string(),
        Some(b) => quote(b),
    }
}

fn fmt_opt(n: Option<usize>) -> String {
    n.map_or("-".to_string(), |n| n.to_string())
}

fn extras<W: Write>(out: &mut W, i: usize, pre: &Seq, suf: &Seq) {
    let mut s = pre.clone();
    s.minimize_by_preference();
    writeln!(out, "{} MIN {}", i, fmt_seq(&s)).unwrap();
    let mut s = suf.clone();
    s.sort();
    writeln!(out, "{} SORT {}", i, fmt_seq(&s)).unwrap();
    let mut s = suf.clone();
    s.reverse_literals();
    writeln!(out, "{} REV {}", i, fmt_seq(&s)).unwrap();
    let mut s = pre.clone();
    let mut o = suf.clone();
    s.union_into_empty(&mut o);
    writeln!(out, "{} UIE {} {}", i, fmt_seq(&s), fmt_seq(&o)).unwrap();
    if pre.max_cross_len(suf).map_or(true, |n| n <= 400) {
        let mut s = pre.clone();
        let mut o = suf.clone();
        s.cross_forward(&mut o);
        writeln!(out, "{} XF {} {}", i, fmt_seq(&s), fmt_seq(&o)).unwrap();
        let mut s = pre.clone();
        let mut o = suf.clone();
        s.cross_reverse(&mut o);
        writeln!(out, "{} XR {} {}", i, fmt_seq(&s), fmt_seq(&o)).unwrap();
    }
    let mut u = pre.clone();
    let mut o = suf.clone();
    u.union(&mut o);
    writeln!(
        out,
        "{} INFO len={} min={} max={} exact={} inexact={} empty={} lcp={} lcs={} ulen={} xlen={} union={}",
        i,
        fmt_opt(pre.len()),
        fmt_opt(pre.min_literal_len()),
        fmt_opt(pre.max_literal_len()),
        pre.is_exact() as u8,
        pre.is_inexact() as u8,
        pre.is_empty() as u8,
        fmt_bytes(pre.longest_common_prefix()),
        fmt_bytes(suf.longest_common_suffix()),
        fmt_opt(pre.max_union_len(suf)),
        fmt_opt(pre.max_cross_len(suf)),
        fmt_seq(&u),
    )
    .unwrap();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let with_hir = args.iter().any(|a| a == "--hir");
    let path = args.iter().skip(1).find(|a| !a.starts_with("--")).expect("usage: literal_oracle [--hir] PATTERNS");
    let data = std::fs::read(path).expect("read pattern file");
    let text = String::from_utf8(data).expect("pattern file is not UTF-8");
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for (i, line) in text.split('\n').enumerate() {
        let pat = line.strip_suffix('\r').unwrap_or(line);
        if pat.is_empty() && i + 1 == text.split('\n').count() {
            break;
        }
        let hir = match ParserBuilder::new().utf8(false).build().parse(pat) {
            Ok(hir) => hir,
            Err(_) => {
                writeln!(out, "{} ERR", i).unwrap();
                continue;
            }
        };
        if with_hir {
            writeln!(out, "{} HIR {:?}", i, hir).unwrap();
        }
        let pre = Extractor::new().kind(ExtractKind::Prefix).extract(&hir);
        let suf = Extractor::new().kind(ExtractKind::Suffix).extract(&hir);
        let mut opre = pre.clone();
        opre.optimize_for_prefix_by_preference();
        let mut osuf = suf.clone();
        osuf.optimize_for_suffix_by_preference();
        writeln!(out, "{} PRE {}", i, fmt_seq(&pre)).unwrap();
        writeln!(out, "{} SUF {}", i, fmt_seq(&suf)).unwrap();
        writeln!(out, "{} OPRE {}", i, fmt_seq(&opre)).unwrap();
        writeln!(out, "{} OSUF {}", i, fmt_seq(&osuf)).unwrap();
        extras(&mut out, i, &pre, &suf);
    }
}
