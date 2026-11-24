// grep-regex 14.1.1's inner literal Extractor (crates/regex/src/literal.rs of ripgrep
// 14.1.1), copied verbatim from `struct Extractor` to the end of `is_poisonous`, so the
// oracle can print what ripgrep extracts. ripgrep is MIT / Unlicense.
#![allow(dead_code)]

macro_rules! trace {
    ($($t:tt)*) => {};
}

use regex_syntax::hir::{
    self,
    literal::{Literal, Seq},
    Hir,
};

pub fn extract_untagged(hir: &Hir) -> Seq {
    Extractor::new().extract_untagged(hir)
}

#[derive(Debug)]
struct Extractor {
    limit_class: usize,
    limit_repeat: usize,
    limit_literal_len: usize,
    limit_total: usize,
}

impl Extractor {
    /// Create a new inner literal extractor with a default configuration.
    fn new() -> Extractor {
        Extractor {
            limit_class: 10,
            limit_repeat: 10,
            limit_literal_len: 100,
            limit_total: 64,
        }
    }

    /// Execute the extractor at the top-level and return an untagged sequence
    /// of literals.
    fn extract_untagged(&self, hir: &Hir) -> Seq {
        let mut seq = self.extract(hir);
        trace!("extracted inner literals: {:?}", seq.seq);
        seq.seq.optimize_for_prefix_by_preference();
        trace!(
            "extracted inner literals after optimization: {:?}",
            seq.seq
        );
        if !seq.is_good() {
            trace!(
                "throwing away inner literals because they might be slow"
            );
            seq.make_infinite();
        }
        seq.seq
    }

    /// Execute the extractor and return a sequence of literals.
    fn extract(&self, hir: &Hir) -> TSeq {
        use regex_syntax::hir::HirKind::*;

        match *hir.kind() {
            Empty | Look(_) => TSeq::singleton(self::Literal::exact(vec![])),
            Literal(hir::Literal(ref bytes)) => {
                let mut seq =
                    TSeq::singleton(self::Literal::exact(bytes.to_vec()));
                self.enforce_literal_len(&mut seq);
                seq
            }
            Class(hir::Class::Unicode(ref cls)) => {
                self.extract_class_unicode(cls)
            }
            Class(hir::Class::Bytes(ref cls)) => self.extract_class_bytes(cls),
            Repetition(ref rep) => self.extract_repetition(rep),
            Capture(hir::Capture { ref sub, .. }) => self.extract(sub),
            Concat(ref hirs) => self.extract_concat(hirs.iter()),
            Alternation(ref hirs) => self.extract_alternation(hirs.iter()),
        }
    }

    /// Extract a sequence from the given concatenation. Sequences from each of
    /// the child HIR expressions are combined via cross product.
    ///
    /// This short circuits once the cross product turns into a sequence
    /// containing only inexact literals.
    fn extract_concat<'a, I: Iterator<Item = &'a Hir>>(&self, it: I) -> TSeq {
        let mut seq = TSeq::singleton(self::Literal::exact(vec![]));
        let mut prev: Option<TSeq> = None;
        for hir in it {
            // If every element in the sequence is inexact, then a cross
            // product will always be a no-op. Thus, there is nothing else we
            // can add to it and can quit early. Note that this also includes
            // infinite sequences.
            if seq.is_inexact() {
                // If a concatenation has an empty sequence anywhere, then
                // it's impossible for the concatenantion to ever match. So we
                // can just quit now.
                if seq.is_empty() {
                    return seq;
                }
                if seq.is_really_good() {
                    return seq;
                }
                prev = Some(match prev {
                    None => seq,
                    Some(prev) => prev.choose(seq),
                });
                seq = TSeq::singleton(self::Literal::exact(vec![]));
                seq.make_not_prefix();
            }
            // Note that 'cross' also dispatches based on whether we're
            // extracting prefixes or suffixes.
            seq = self.cross(seq, self.extract(hir));
        }
        if let Some(prev) = prev {
            prev.choose(seq)
        } else {
            seq
        }
    }

    /// Extract a sequence from the given alternation.
    ///
    /// This short circuits once the union turns into an infinite sequence.
    fn extract_alternation<'a, I: Iterator<Item = &'a Hir>>(
        &self,
        it: I,
    ) -> TSeq {
        let mut seq = TSeq::empty();
        for hir in it {
            // Once our 'seq' is infinite, every subsequent union
            // operation on it will itself always result in an
            // infinite sequence. Thus, it can never change and we can
            // short-circuit.
            if !seq.is_finite() {
                break;
            }
            seq = self.union(seq, &mut self.extract(hir));
        }
        seq
    }

    /// Extract a sequence of literals from the given repetition. We do our
    /// best, Some examples:
    ///
    ///   'a*'    => [inexact(a), exact("")]
    ///   'a*?'   => [exact(""), inexact(a)]
    ///   'a+'    => [inexact(a)]
    ///   'a{3}'  => [exact(aaa)]
    ///   'a{3,5} => [inexact(aaa)]
    ///
    /// The key here really is making sure we get the 'inexact' vs 'exact'
    /// attributes correct on each of the literals we add. For example, the
    /// fact that 'a*' gives us an inexact 'a' and an exact empty string means
    /// that a regex like 'ab*c' will result in [inexact(ab), exact(ac)]
    /// literals being extracted, which might actually be a better prefilter
    /// than just 'a'.
    fn extract_repetition(&self, rep: &hir::Repetition) -> TSeq {
        let mut subseq = self.extract(&rep.sub);
        match *rep {
            hir::Repetition { min: 0, max, greedy, .. } => {
                // When 'max=1', we can retain exactness, since 'a?' is
                // equivalent to 'a|'. Similarly below, 'a??' is equivalent to
                // '|a'.
                if max != Some(1) {
                    subseq.make_inexact();
                }
                let mut empty = TSeq::singleton(Literal::exact(vec![]));
                if !greedy {
                    std::mem::swap(&mut subseq, &mut empty);
                }
                self.union(subseq, &mut empty)
            }
            hir::Repetition { min, max: Some(max), .. } if min == max => {
                assert!(min > 0); // handled above
                let limit =
                    u32::try_from(self.limit_repeat).unwrap_or(u32::MAX);
                let mut seq = TSeq::singleton(Literal::exact(vec![]));
                for _ in 0..std::cmp::min(min, limit) {
                    if seq.is_inexact() {
                        break;
                    }
                    seq = self.cross(seq, subseq.clone());
                }
                if usize::try_from(min).is_err() || min > limit {
                    seq.make_inexact();
                }
                seq
            }
            hir::Repetition { min, max: Some(max), .. } if min < max => {
                assert!(min > 0); // handled above
                let limit =
                    u32::try_from(self.limit_repeat).unwrap_or(u32::MAX);
                let mut seq = TSeq::singleton(Literal::exact(vec![]));
                for _ in 0..std::cmp::min(min, limit) {
                    if seq.is_inexact() {
                        break;
                    }
                    seq = self.cross(seq, subseq.clone());
                }
                seq.make_inexact();
                seq
            }
            hir::Repetition { .. } => {
                subseq.make_inexact();
                subseq
            }
        }
    }

    /// Convert the given Unicode class into a sequence of literals if the
    /// class is small enough. If the class is too big, return an infinite
    /// sequence.
    fn extract_class_unicode(&self, cls: &hir::ClassUnicode) -> TSeq {
        if self.class_over_limit_unicode(cls) {
            return TSeq::infinite();
        }
        let mut seq = TSeq::empty();
        for r in cls.iter() {
            for ch in r.start()..=r.end() {
                seq.push(Literal::from(ch));
            }
        }
        self.enforce_literal_len(&mut seq);
        seq
    }

    /// Convert the given byte class into a sequence of literals if the class
    /// is small enough. If the class is too big, return an infinite sequence.
    fn extract_class_bytes(&self, cls: &hir::ClassBytes) -> TSeq {
        if self.class_over_limit_bytes(cls) {
            return TSeq::infinite();
        }
        let mut seq = TSeq::empty();
        for r in cls.iter() {
            for b in r.start()..=r.end() {
                seq.push(Literal::from(b));
            }
        }
        self.enforce_literal_len(&mut seq);
        seq
    }

    /// Returns true if the given Unicode class exceeds the configured limits
    /// on this extractor.
    fn class_over_limit_unicode(&self, cls: &hir::ClassUnicode) -> bool {
        let mut count = 0;
        for r in cls.iter() {
            if count > self.limit_class {
                return true;
            }
            count += r.len();
        }
        count > self.limit_class
    }

    /// Returns true if the given byte class exceeds the configured limits on
    /// this extractor.
    fn class_over_limit_bytes(&self, cls: &hir::ClassBytes) -> bool {
        let mut count = 0;
        for r in cls.iter() {
            if count > self.limit_class {
                return true;
            }
            count += r.len();
        }
        count > self.limit_class
    }

    /// Compute the cross product of the two sequences if the result would be
    /// within configured limits. Otherwise, make `seq2` infinite and cross the
    /// infinite sequence with `seq1`.
    fn cross(&self, mut seq1: TSeq, mut seq2: TSeq) -> TSeq {
        if !seq2.prefix {
            return seq1.choose(seq2);
        }
        if seq1
            .max_cross_len(&seq2)
            .map_or(false, |len| len > self.limit_total)
        {
            seq2.make_infinite();
        }
        seq1.cross_forward(&mut seq2);
        assert!(seq1.len().map_or(true, |x| x <= self.limit_total));
        self.enforce_literal_len(&mut seq1);
        seq1
    }

    /// Union the two sequences if the result would be within configured
    /// limits. Otherwise, make `seq2` infinite and union the infinite sequence
    /// with `seq1`.
    fn union(&self, mut seq1: TSeq, seq2: &mut TSeq) -> TSeq {
        if seq1.max_union_len(seq2).map_or(false, |len| len > self.limit_total)
        {
            // We try to trim our literal sequences to see if we can make
            // room for more literals. The idea is that we'd rather trim down
            // literals already in our sequence if it means we can add a few
            // more and retain a finite sequence. Otherwise, we'll union with
            // an infinite sequence and that infects everything and effectively
            // stops literal extraction in its tracks.
            //
            // We do we keep 4 bytes here? Well, it's a bit of an abstraction
            // leakage. Downstream, the literals may wind up getting fed to
            // the Teddy algorithm, which supports searching literals up to
            // length 4. So that's why we pick that number here. Arguably this
            // should be a tuneable parameter, but it seems a little tricky to
            // describe. And I'm still unsure if this is the right way to go
            // about culling literal sequences.
            seq1.keep_first_bytes(4);
            seq2.keep_first_bytes(4);
            seq1.dedup();
            seq2.dedup();
            if seq1
                .max_union_len(seq2)
                .map_or(false, |len| len > self.limit_total)
            {
                seq2.make_infinite();
            }
        }
        seq1.union(seq2);
        assert!(seq1.len().map_or(true, |x| x <= self.limit_total));
        seq1.prefix = seq1.prefix && seq2.prefix;
        seq1
    }

    /// Applies the literal length limit to the given sequence. If none of the
    /// literals in the sequence exceed the limit, then this is a no-op.
    fn enforce_literal_len(&self, seq: &mut TSeq) {
        seq.keep_first_bytes(self.limit_literal_len);
    }
}

#[derive(Clone, Debug)]
struct TSeq {
    seq: Seq,
    prefix: bool,
}

#[allow(dead_code)]
impl TSeq {
    fn empty() -> TSeq {
        TSeq { seq: Seq::empty(), prefix: true }
    }

    fn infinite() -> TSeq {
        TSeq { seq: Seq::infinite(), prefix: true }
    }

    fn singleton(lit: Literal) -> TSeq {
        TSeq { seq: Seq::singleton(lit), prefix: true }
    }

    fn new<I, B>(it: I) -> TSeq
    where
        I: IntoIterator<Item = B>,
        B: AsRef<[u8]>,
    {
        TSeq { seq: Seq::new(it), prefix: true }
    }

    fn literals(&self) -> Option<&[Literal]> {
        self.seq.literals()
    }

    fn push(&mut self, lit: Literal) {
        self.seq.push(lit);
    }

    fn make_inexact(&mut self) {
        self.seq.make_inexact();
    }

    fn make_infinite(&mut self) {
        self.seq.make_infinite();
    }

    fn cross_forward(&mut self, other: &mut TSeq) {
        assert!(other.prefix);
        self.seq.cross_forward(&mut other.seq);
    }

    fn union(&mut self, other: &mut TSeq) {
        self.seq.union(&mut other.seq);
    }

    fn dedup(&mut self) {
        self.seq.dedup();
    }

    fn sort(&mut self) {
        self.seq.sort();
    }

    fn keep_first_bytes(&mut self, len: usize) {
        self.seq.keep_first_bytes(len);
    }

    fn is_finite(&self) -> bool {
        self.seq.is_finite()
    }

    fn is_empty(&self) -> bool {
        self.seq.is_empty()
    }

    fn len(&self) -> Option<usize> {
        self.seq.len()
    }

    fn is_exact(&self) -> bool {
        self.seq.is_exact()
    }

    fn is_inexact(&self) -> bool {
        self.seq.is_inexact()
    }

    fn max_union_len(&self, other: &TSeq) -> Option<usize> {
        self.seq.max_union_len(&other.seq)
    }

    fn max_cross_len(&self, other: &TSeq) -> Option<usize> {
        assert!(other.prefix);
        self.seq.max_cross_len(&other.seq)
    }

    fn min_literal_len(&self) -> Option<usize> {
        self.seq.min_literal_len()
    }

    fn max_literal_len(&self) -> Option<usize> {
        self.seq.max_literal_len()
    }

    // Below are methods specific to a TSeq that aren't just forwarding calls
    // to a Seq method.

    /// Tags this sequence as "not a prefix." When this happens, this sequence
    /// can't be crossed as a suffix of another sequence.
    fn make_not_prefix(&mut self) {
        self.prefix = false;
    }

    /// Returns true if it's believed that the sequence given is "good" for
    /// acceleration. This is useful for determining whether a sequence of
    /// literals has any shot of being fast.
    fn is_good(&self) -> bool {
        if self.has_poisonous_literal() {
            return false;
        }
        let Some(min) = self.min_literal_len() else { return false };
        let Some(len) = self.len() else { return false };
        // If we have some very short literals, then let's require that our
        // sequence is itself very small.
        if min <= 1 {
            return len <= 3;
        }
        min >= 2 && len <= 64
    }

    /// Returns true if it's believed that the sequence given is "really
    /// good" for acceleration. This is useful for short circuiting literal
    /// extraction.
    fn is_really_good(&self) -> bool {
        if self.has_poisonous_literal() {
            return false;
        }
        let Some(min) = self.min_literal_len() else { return false };
        let Some(len) = self.len() else { return false };
        min >= 3 && len <= 8
    }

    /// Returns true if the given sequence contains a poisonous literal.
    fn has_poisonous_literal(&self) -> bool {
        let Some(lits) = self.literals() else { return false };
        lits.iter().any(is_poisonous)
    }

    /// Compare the two sequences and return the one that is believed to be
    /// best according to a hodge podge of heuristics.
    fn choose(self, other: TSeq) -> TSeq {
        let (mut seq1, mut seq2) = (self, other);
        // Whichever one we pick, by virtue of picking one, we choose
        // to not take the other. So we must consider the result inexact.
        seq1.make_inexact();
        seq2.make_inexact();

        if !seq1.is_finite() {
            return seq2;
        } else if !seq2.is_finite() {
            return seq1;
        }
        if seq1.has_poisonous_literal() {
            return seq2;
        } else if seq2.has_poisonous_literal() {
            return seq1;
        }
        let Some(min1) = seq1.min_literal_len() else { return seq2 };
        let Some(min2) = seq2.min_literal_len() else { return seq1 };
        if min1 < min2 {
            return seq2;
        } else if min2 < min1 {
            return seq1;
        }
        // OK because we know both sequences are finite, otherwise they wouldn't
        // have a minimum literal length.
        let len1 = seq1.len().unwrap();
        let len2 = seq2.len().unwrap();
        if len1 < len2 {
            return seq2;
        } else if len2 < len1 {
            return seq1;
        }
        // We could do extra stuff like looking at a background frequency
        // distribution of bytes and picking the one that looks more rare, but for
        // now we just pick one.
        seq1
    }
}

impl FromIterator<Literal> for TSeq {
    fn from_iter<T: IntoIterator<Item = Literal>>(it: T) -> TSeq {
        TSeq { seq: Seq::from_iter(it), prefix: true }
    }
}

/// Returns true if it is believe that this literal is likely to match very
/// frequently, and is thus not a good candidate for a prefilter.
fn is_poisonous(lit: &Literal) -> bool {
    use regex_syntax::hir::literal::rank;

    lit.is_empty() || (lit.len() == 1 && rank(lit.as_bytes()[0]) >= 250)
}

