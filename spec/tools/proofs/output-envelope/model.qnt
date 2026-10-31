// Proof model: bash's result envelope under the provider-side cap (#652).
//
// The scrub half of the `out` machine of ../../model.qnt.  Bash keeps the
// tail of the output (TAIL units), appends the exit/timeout trailer, and
// tools.scrub-result escapes every control or invalid byte as a 4-byte \xNN
// and head-keeps FEN_TOOL_RESULT_MAX_BYTES sanitized bytes.  UTF-8 detail is
// the utf8-tail proof's job: here a body unit is either a safe byte "a"
// (1 sanitized byte) or an escaped one "x" (4), and the trailer "T" is plain
// ASCII of TRAILER sanitized bytes.
//
// Code: extensions/behaviors/kernel/builtin-tools/bash.fnl (result-text,
// exit-tag), packages/core/src/fen/core/tools.fnl (scrub-result),
// packages/util/src/fen/util/text.fnl (scrub-tool-text).
//
// The #652 fix: the cap reserves the trailer's size, keeps the head of the
// body within the rest, and appends the trailer last.
module outputEnvelope {
  const FIXES: Set[str]

  pure val TAIL = 3       // bash tail cap (units), scaled
  pure val LIMIT = 8      // FEN_TOOL_RESULT_MAX_BYTES, scaled
  pure val TRAILER = 2    // sanitized size of "[exit N]", scaled
  pure val UNITS = Set("none", "a", "x")

  var ran: bool
  var body: List[str]     // after the tail cap
  var kept: List[str]     // what the provider receives

  pure def unitBytes(u: str): int = if (u == "x") 4 else if (u == "T") TRAILER else 1

  pure def sizeOf(bs: List[str]): int = bs.foldl(0, (n, u) => n + unitBytes(u))

  // utf8-prefix head-keep up to `limit` sanitized bytes.
  pure def headKeep(bs: List[str], limit: int): List[str] =
    bs.foldl({ kept: List(), used: 0, stop: false }, (acc, u) =>
      if (acc.stop or acc.used + unitBytes(u) > limit) { ...acc, stop: true }
      else { kept: acc.kept.append(u), used: acc.used + unitBytes(u), stop: false }
    ).kept

  pure def scrub(b: List[str], fix: bool): List[str] =
    if (fix) headKeep(b, LIMIT - TRAILER).append("T")
    else headKeep(b.append("T"), LIMIT)

  pure def unit(t: str): List[str] = if (t == "none") [] else [t]

  action init = all { ran' = false, body' = [], kept' = [] }

  // The body already fits the tail cap: at most TAIL units.
  action emitWith(t1: str, t2: str, t3: str): bool = all {
    not(ran),
    val b = unit(t1).concat(unit(t2)).concat(unit(t3))
    all { ran' = true, body' = b, kept' = scrub(b, FIXES.contains("652")) },
  }

  action emit = {
    nondet t1 = UNITS.oneOf()
    nondet t2 = UNITS.oneOf()
    nondet t3 = UNITS.oneOf()
    emitWith(t1, t2, t3)
  }

  action stutter = all { ran, ran' = ran, body' = body, kept' = kept }

  action step = any { emit, stutter }

  // Truncation never loses the exit/timeout tag the model reads.
  val exitStatusVisible = ran implies kept.foldl(false, (f, u) => f or u == "T")

  // The provider cap holds.
  val withinLimit = sizeOf(kept) <= LIMIT

  // The trailer, when present, is the last thing sent.
  val trailerLast =
    (ran and kept.length() > 0) implies
      kept.foldl({ seen: false, ok: true }, (acc, u) =>
        { seen: acc.seen or u == "T", ok: acc.ok and not(acc.seen) }).ok

  // A result that fits is sent whole.
  val fitsSentWhole =
    (ran and sizeOf(body) + TRAILER <= LIMIT) implies kept == body.append("T")
}

module current { import outputEnvelope(FIXES = Set("652")).* }
module fixed { import outputEnvelope(FIXES = Set("652")).* }
