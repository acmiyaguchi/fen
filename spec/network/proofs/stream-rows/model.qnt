// Proof model for the stream-display contract of spec/network/model.qnt:
// "only the last attempt's text is shown, and every stream is closed exactly
// once". It keeps only the state the contract needs, as scalars: the open
// streaming row (whose turn's text it starts with, the lowest attempt of the
// current turn's text in it), the attempt's token count, the hosted flag, and
// three sticky ghost flags that record a violation when it happens instead of
// re-deriving it from a transcript every step.
//
// Same events and fixes as the integration model:
//   "629"  :provider-retry drops the open row's text
//   "630"  :error and :cancelled close the open row
module streamrows {
  const FIXES: Set[str]

  pure val MAX_TURNS = 2
  pure val MAX_ATTEMPTS = 2
  pure val REPLY_LEN = 2

  var phase: str       // idle | streaming | backoff
  var turn: int        // 0..MAX_TURNS
  var attempt: int     // 0..MAX_ATTEMPTS
  var buf: int         // tokens of this attempt, 0..REPLY_LEN
  var hostedOpen: bool // provider side: a hosted item is open
  var open: bool       // TUI: a streaming row is open
  var rowTurn: int     // turn of the open row's first text; 0 = no text
  var rowLo: int       // lowest attempt of THIS turn's text in it; 0 = none
  var hosted: bool     // TUI: a hosted tool is shown as running
  var retrying: bool   // TUI: retry flag
  var mixed: bool      // ghost: some row got text from two turns
  var stale: bool      // ghost: a finished turn showed superseded text
  var badOk: bool      // ghost: an ok reply was not shown exactly

  action init = all {
    phase' = "idle", turn' = 0, attempt' = 0, buf' = 0, hostedOpen' = false,
    open' = false, rowTurn' = 0, rowLo' = 0, hosted' = false, retrying' = false,
    mixed' = false, stale' = false, badOk' = false,
  }

  // The open row holds superseded text of the current turn.
  val rowStale: bool = open and rowLo > 0 and rowLo < attempt

  action startTurn = all {
    phase == "idle", turn < MAX_TURNS,
    phase' = "streaming", turn' = turn + 1, attempt' = 1, buf' = 0,
    hostedOpen' = false,
    // :user then :llm-start; an open row stays open but holds no text of
    // the new turn yet
    open' = open, rowTurn' = rowTurn, rowLo' = 0,
    hosted' = hosted, retrying' = false,
    mixed' = mixed, stale' = stale, badOk' = badOk,
  }

  action streamToken = all {
    phase == "streaming", buf < REPLY_LEN, not(hostedOpen),
    buf' = buf + 1,
    open' = true,
    rowTurn' = if (open and rowTurn > 0) rowTurn else turn,
    rowLo' = if (open and rowLo > 0) rowLo else attempt,
    mixed' = (mixed or (open and rowTurn > 0 and rowTurn != turn)),
    phase' = phase, turn' = turn, attempt' = attempt, hostedOpen' = hostedOpen,
    hosted' = hosted, retrying' = retrying, stale' = stale, badOk' = badOk,
  }

  action hostedEv(start: bool): bool = all {
    phase == "streaming", hostedOpen != start, buf == 0,
    hostedOpen' = start, hosted' = start,
    phase' = phase, turn' = turn, attempt' = attempt, buf' = buf,
    open' = open, rowTurn' = rowTurn, rowLo' = rowLo, retrying' = retrying,
    mixed' = mixed, stale' = stale, badOk' = badOk,
  }

  // Transient failure with attempts left: :provider-retry.
  action retry = all {
    phase == "streaming", attempt < MAX_ATTEMPTS,
    phase' = "backoff", hostedOpen' = false, hosted' = false, retrying' = true,
    val drop = FIXES.contains("629") and open
    all {
      rowTurn' = if (drop) 0 else rowTurn,
      rowLo' = if (drop) 0 else rowLo,
    },
    open' = open, turn' = turn, attempt' = attempt, buf' = buf,
    mixed' = mixed, stale' = stale, badOk' = badOk,
  }

  action backoffDone = all {
    phase == "backoff",
    phase' = "streaming", attempt' = attempt + 1, buf' = 0, hostedOpen' = false,
    turn' = turn, open' = open, rowTurn' = rowTurn, rowLo' = rowLo,
    hosted' = hosted, retrying' = retrying,
    mixed' = mixed, stale' = stale, badOk' = badOk,
  }

  // :llm-end then :assistant-stream-end: the row is checked and closed.
  action complete = all {
    phase == "streaming", buf == REPLY_LEN,
    phase' = "idle",
    badOk' = (badOk or not(open and rowTurn == turn and rowLo == attempt)),
    stale' = (stale or rowStale),
    open' = false, rowTurn' = 0, rowLo' = 0,
    hosted' = false, retrying' = false, hostedOpen' = false,
    turn' = turn, attempt' = attempt, buf' = buf, mixed' = mixed,
  }

  // Terminal failure (or retries exhausted), or a cancel at a yield:
  // :error / :cancelled, with no stream-end. The turn is over: whatever its
  // open row shows is what the user is left with.
  action endFailed(isCancel: bool): bool = all {
    if (isCancel) (phase == "streaming" or phase == "backoff") else phase == "streaming",
    phase' = "idle",
    stale' = (stale or rowStale),
    val close = FIXES.contains("630")
    all {
      open' = if (close) false else open,
      rowTurn' = if (close) 0 else rowTurn,
      rowLo' = if (close) 0 else rowLo,
    },
    hosted' = false, retrying' = false, hostedOpen' = false,
    turn' = turn, attempt' = attempt, buf' = buf, mixed' = mixed, badOk' = badOk,
  }

  action step = any {
    startTurn,
    streamToken,
    hostedEv(true),
    hostedEv(false),
    retry,
    backoffDone,
    complete,
    endFailed(false),
    endFailed(true),
  }

  // Note: write `x' = (a or b)`: an unparenthesised `x' = a or b` parses as
  // `(x' = a) or b`, which lets the simulator keep x unchanged.

  // ---- properties (same names as the integration model) ----
  val noOpenRowWhenIdle = phase == "idle" implies not(open)
  val noSupersededText = not(stale)
  val rowsSingleTurn = not(mixed)
  val okReplyDisplayed = not(badOk)
  val noHostedWhenIdle = phase == "idle" implies not(hosted)
  val boundedAttempts = attempt <= MAX_ATTEMPTS

  val allInvariants = and {
    noOpenRowWhenIdle, noSupersededText, rowsSingleTurn, okReplyDisplayed,
    noHostedWhenIdle, boundedAttempts,
  }

  // ---- inductive strengthening for the fixed design ----
  // Every variable is bound by `in` first, as Apalache's inductive check needs.
  val typeOK = and {
    phase.in(Set("idle", "streaming", "backoff")),
    turn.in(0.to(MAX_TURNS)),
    attempt.in(0.to(MAX_ATTEMPTS)),
    buf.in(0.to(REPLY_LEN)),
    hostedOpen.in(Bool),
    open.in(Bool),
    rowTurn.in(0.to(MAX_TURNS)),
    rowLo.in(0.to(MAX_ATTEMPTS)),
    hosted.in(Bool),
    retrying.in(Bool),
    mixed.in(Bool),
    stale.in(Bool),
    badOk.in(Bool),
  }

  val inductiveInv = and {
    typeOK,
    allInvariants,
    phase != "idle" implies (turn >= 1 and attempt >= 1),
    // no text without an open row; a row's text is all from this turn
    not(open) implies (rowTurn == 0 and rowLo == 0),
    rowTurn > 0 iff rowLo > 0,
    rowTurn > 0 implies (rowTurn == turn and rowLo == attempt and phase == "streaming"),
    // this attempt's tokens are exactly what the open row shows
    (phase == "streaming" and buf > 0) implies (open and rowTurn == turn and rowLo == attempt),
    phase == "idle" implies not(hostedOpen),
    hostedOpen implies (phase == "streaming" and buf == 0),
    hosted implies hostedOpen,
    retrying implies phase != "idle",
    phase == "backoff" implies (attempt < MAX_ATTEMPTS and buf <= REPLY_LEN),
  }
}

module current { import streamrows(FIXES = Set()).* }
module fixed { import streamrows(FIXES = Set("629", "630")).* }
