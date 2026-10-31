// Abstract specification of the usage ledger (#672): usage as a fold over
// one append-only log, with markers and a history-rewrite watermark.
//
// The ledger records provider calls (turns and compactions alike, plus replayed
// usage as a seed). Every view (session total, run delta, headless invocation
// delta) is a fold over the log from a marker. The log is strictly append-only:
// history rewrites (such as compaction) do not rewrite or drop ledger entries,
// but advance a watermark epoch so that stale context estimates are recognized.
//
// Pure definitions only, so concrete models can import them.
module ledgerAbstract {
  type Entry = { tok: int, epoch: int }

  type Abs = {
    log: List[Entry],
    marks: Set[int],
    watermark: int,
  }

  pure val EMPTY_LOG: List[Entry] = []

  pure val absInit: Abs = {
    log: EMPTY_LOG,
    marks: Set(0),
    watermark: 0,
  }

  // Tokens of the entries of l from index m on.
  pure def sumFrom(l: List[Entry], m: int): int =
    l.foldl({ i: 0, s: 0 }, (acc, e) =>
      { i: acc.i + 1, s: if (acc.i >= m) acc.s + e.tok else acc.s }).s

  pure def sessionTotal(a: Abs): int = sumFrom(a.log, 0)
  pure def deltaFrom(a: Abs, m: int): int = sumFrom(a.log, m)

  // Append a provider call usage entry with positive tokens.
  pure def appendEntry(a: Abs, b: Abs): bool = and {
    b.log.length() == a.log.length() + 1,
    b.log.slice(0, a.log.length()) == a.log,
    val e = b.log[a.log.length()]
    and {
      e.tok > 0,
      e.epoch == a.watermark,
    },
    b.marks == a.marks,
    b.watermark == a.watermark,
  }

  // Record a marker at the current log length.
  pure def takeMark(a: Abs, b: Abs): bool = and {
    b.log == a.log,
    b.marks == a.marks.union(Set(a.log.length())),
    b.watermark == a.watermark,
  }

  // History rewrite watermark advances (e.g. compaction or context truncation).
  pure def rewrite(a: Abs, b: Abs): bool = and {
    b.log == a.log,
    b.marks == a.marks,
    b.watermark == a.watermark + 1,
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    appendEntry(a, b),
    takeMark(a, b),
    rewrite(a, b),
  }

  // ---- properties every refining owner inherits ----

  // All markers are valid indices into the log.
  pure def marksValid(a: Abs): bool =
    a.marks.forall(m => 0 <= m and m <= a.log.length())

  // The baseline session marker 0 is always present.
  pure def zeroMarkPresent(a: Abs): bool =
    a.marks.contains(0)

  // Watermark is non-negative and all entry epochs are within watermark.
  pure def epochBounded(a: Abs): bool = and {
    a.watermark >= 0,
    a.log.foldl(true, (ok, e) => ok and 0 <= e.epoch and e.epoch <= a.watermark),
  }

  // Entry epochs in the log are non-decreasing.
  pure def epochMonotonic(a: Abs): bool =
    a.log.foldl({ ok: true, lastEpoch: 0 }, (acc, e) =>
      { ok: acc.ok and acc.lastEpoch <= e.epoch, lastEpoch: e.epoch }
    ).ok

  // Any delta from a valid marker is non-negative and at most the session total.
  pure def deltasBounded(a: Abs): bool =
    a.marks.forall(m =>
      val d = deltaFrom(a, m)
      0 <= d and d <= sessionTotal(a)
    )

  // A marker at the current log tip has zero delta.
  pure def tipMarkZero(a: Abs): bool =
    a.marks.contains(a.log.length()) implies deltaFrom(a, a.log.length()) == 0

  pure def absInv(a: Abs): bool = and {
    marksValid(a),
    zeroMarkPresent(a),
    epochBounded(a),
    epochMonotonic(a),
    deltasBounded(a),
    tipMarkZero(a),
  }
}
