// The abstract usage ledger machine (#672), checked on its own.
// Its invariants hold inductively (verify.tsv), so every concrete model
// that refines absNext inherits them.
module ledgerSpec {
  import ledgerAbstract.* from "./abstract"

  pure val MAX_LOG = 2
  pure val MAX_EPOCH = 1
  pure val TOK_VALUES = Set(1, 2)
  pure val EPOCH_VALUES = 0.to(MAX_EPOCH)

  pure val ENTRY_POOL: Set[Entry] =
    tuples(TOK_VALUES, EPOCH_VALUES).map(t => { tok: t._1, epoch: t._2 })

  pure val LOG_LISTS: Set[List[Entry]] =
    Set(EMPTY_LOG).union(ENTRY_POOL.map(e => [e]))
      .union(tuples(ENTRY_POOL, ENTRY_POOL)
        .filter(p => p._1.epoch <= p._2.epoch)
        .map(p => [p._1, p._2]))

  pure val MARKS_SUBSETS: Set[Set[int]] =
    0.to(MAX_LOG).powerset().filter(s => s.contains(0))

  pure val ABS_STATES: Set[Abs] =
    LOG_LISTS.map(l =>
      MARKS_SUBSETS.map(ms =>
        EPOCH_VALUES.filter(w => l.foldl(true, (ok, e) => ok and e.epoch <= w)).map(w =>
          { log: l, marks: ms.filter(m => m <= l.length()), watermark: w }
        )
      ).flatten()
    ).flatten()

  var a: Abs
  var prev: Abs

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doAppend(tok: int): bool = all {
    a.log.length() < MAX_LOG,
    tok.in(TOK_VALUES),
    val e = { tok: tok, epoch: a.watermark }
    move({ ...a, log: a.log.append(e) }),
  }

  action doTakeMark = all {
    move({ ...a, marks: a.marks.union(Set(a.log.length())) }),
  }

  action doRewrite = all {
    a.watermark < MAX_EPOCH,
    move({ ...a, watermark: a.watermark + 1 }),
  }

  action step = any {
    nondet tok = TOK_VALUES.oneOf()
    doAppend(tok),
    doTakeMark,
    doRewrite,
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)
  val marksValidInv = marksValid(a)
  val zeroMarkPresentInv = zeroMarkPresent(a)
  val epochBoundedInv = epochBounded(a)
  val epochMonotonicInv = epochMonotonic(a)
  val deltasBoundedInv = deltasBounded(a)
  val tipMarkZeroInv = tipMarkZero(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    marksValidInv,
    zeroMarkPresentInv,
    epochBoundedInv,
    epochMonotonicInv,
    deltasBoundedInv,
    tipMarkZeroInv,
    inductiveInv,
  }
}
