// Proof model: bash's tail cap and UTF-8 boundaries (#653).
//
// The tail half of the `out` machine of ../../model.qnt, widened to 3-byte
// characters: output is three tokens, each nothing, an ASCII byte "a", a
// control byte "x", a 2-byte character "e" = [L C], or a 3-byte character
// "f" = [L C C]; the tail cap keeps its last TAIL_BYTES bytes.
//
// Code: packages/util/src/fen/util/process/init.fnl (trim-tail:
// (string.sub out (- max-bytes)), which counts bytes, not characters).
//
// The #653 fix: after the byte cut, skip the leading continuation bytes
// ([\x80-\xBF]*; at most 3 in valid UTF-8).
module utf8Tail {
  const FIXES: Set[str]

  pure val TAIL_BYTES = 4   // process DEFAULT-MAX-BYTES, scaled
  pure val TOKENS = Set("none", "a", "x", "e", "f")

  var ran: bool
  var raw: List[str]
  var trimmed: List[str]

  pure def expand(t: str): List[str] =
    if (t == "e") ["L", "C"]
    else if (t == "f") ["L", "C", "C"]
    else if (t == "none") []
    else [t]

  // Leading continuation bytes, counted over a constant bound.
  pure def leadingConts(bs: List[str]): int =
    range(0, 3).foldl({ n: 0, going: true }, (acc, i) =>
      if (acc.going and i < bs.length() and bs[i] == "C") { n: acc.n + 1, going: true }
      else { n: acc.n, going: false }
    ).n

  pure def tailTrim(bs: List[str], fix: bool): List[str] =
    val n = bs.length()
    val t = if (n > TAIL_BYTES) bs.slice(n - TAIL_BYTES, n) else bs
    if (fix) t.slice(leadingConts(t), t.length()) else t

  action init = all { ran' = false, raw' = [], trimmed' = [] }

  action cutWith(t1: str, t2: str, t3: str): bool = all {
    not(ran),
    val r = expand(t1).concat(expand(t2)).concat(expand(t3))
    all {
      ran' = true, raw' = r,
      trimmed' = tailTrim(r, FIXES.contains("653")),
    },
  }

  action cut = {
    nondet t1 = TOKENS.oneOf()
    nondet t2 = TOKENS.oneOf()
    nondet t3 = TOKENS.oneOf()
    cutWith(t1, t2, t3)
  }

  action stutter = all { ran, ran' = ran, raw' = raw, trimmed' = trimmed }

  action step = any { cut, stutter }

  // The tail cap never starts the output inside a UTF-8 character.
  val noSplitChar = (ran and trimmed.length() > 0) implies trimmed[0] != "C"

  // The cap holds.
  val withinCap = trimmed.length() <= TAIL_BYTES

  // The fix drops less than one character: the kept text is a suffix of the
  // output no shorter than TAIL_BYTES - 2 bytes (a 3-byte character's two
  // continuation bytes), unless the output was shorter than that.
  val dropsLessThanAChar =
    ran implies trimmed.length() >= (if (raw.length() < TAIL_BYTES) raw.length()
                                     else TAIL_BYTES) - 2
}

module current { import utf8Tail(FIXES = Set("653")).* }
module fixed { import utf8Tail(FIXES = Set("653")).* }
