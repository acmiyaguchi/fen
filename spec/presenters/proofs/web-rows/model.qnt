// Proof model for the web presenter's transcript rows
// (extensions/adapters/presenters/web/ingest.fnl): only the last provider
// attempt's text is shown, and no row mixes two steps. Scalars only: the
// open streaming row, whether find-streaming-row can still reach it (no
// closed assistant/tool/user row after it), the (step, call, attempt) of its
// first text, and sticky ghost flags recording a violation when it happens.
//
// A step is a typed prompt (a :user row, which is a barrier) or a goal
// iteration (emit-user? false: no row), and a goal iterates only after an ok
// step. Fixes: "631" :provider-retry drops the open row's text, and :error /
// :cancelled close it.
module webrows {
  const FIXES: Set[str]

  pure val MAX_STEPS = 2
  pure val SAFETY = 2
  pure val MAX_ATTEMPTS = 2
  pure val REPLY_LEN = 2

  var phase: str      // idle | streaming
  var iter: int       // steps started, 0..MAX_STEPS
  var calls: int      // provider calls in this step, 0..SAFETY
  var attempt: int    // attempt of this call, 0..MAX_ATTEMPTS
  var buf: int        // tokens of this attempt
  var lastOk: bool    // the previous step ended ok
  var open: bool      // a streaming row exists
  var reach: bool     // find-streaming-row reaches it
  var rowText: bool   // it holds text
  var rowStep: int    // (step, call, attempt) of its first text
  var rowCall: int
  var rowAtt: int
  var rowPure: bool   // all its text has that triple
  var mixedAttempt: bool // ghost: a row got text from two attempts or calls
  var mixedStep: bool    // ghost: a row got text from two steps
  var badOk: bool        // ghost: an ok reply was not shown exactly

  action init = all {
    phase' = "idle", iter' = 0, calls' = 0, attempt' = 0, buf' = 0, lastOk' = false,
    open' = false, reach' = false, rowText' = false, rowStep' = 0, rowCall' = 0,
    rowAtt' = 0, rowPure' = true, mixedAttempt' = false, mixedStep' = false, badOk' = false,
  }

  val curIsRow: bool = rowStep == iter and rowCall == calls and rowAtt == attempt

  action startStep(typed: bool): bool = all {
    phase == "idle", iter < MAX_STEPS, typed or lastOk,
    phase' = "streaming", iter' = iter + 1, calls' = 1, attempt' = 1, buf' = 0,
    // a :user row is a barrier for find-streaming-row
    reach' = if (typed) false else reach,
    lastOk' = lastOk, open' = open, rowText' = rowText, rowStep' = rowStep,
    rowCall' = rowCall, rowAtt' = rowAtt, rowPure' = rowPure,
    mixedAttempt' = mixedAttempt, mixedStep' = mixedStep, badOk' = badOk,
  }

  action streamToken = all {
    phase == "streaming", buf < REPLY_LEN,
    buf' = buf + 1,
    val join = open and reach
    val first = not(join and rowText)
    all {
      open' = true, reach' = true, rowText' = true,
      rowStep' = if (first) iter else rowStep,
      rowCall' = if (first) calls else rowCall,
      rowAtt' = if (first) attempt else rowAtt,
      rowPure' = (first or (rowPure and curIsRow)),
      mixedAttempt' = (mixedAttempt or (not(first) and not(curIsRow))),
      mixedStep' = (mixedStep or (not(first) and rowStep != iter)),
    },
    phase' = phase, iter' = iter, calls' = calls, attempt' = attempt,
    lastOk' = lastOk, badOk' = badOk,
  }

  // :provider-retry: a generic (non-barrier) row; "631" drops the text.
  action retry = all {
    phase == "streaming", attempt < MAX_ATTEMPTS,
    attempt' = attempt + 1, buf' = 0,
    val drop = FIXES.contains("631") and open
    all {
      rowText' = if (drop) false else rowText,
      rowPure' = if (drop) true else rowPure,
    },
    phase' = phase, iter' = iter, calls' = calls, lastOk' = lastOk,
    open' = open, reach' = reach, rowStep' = rowStep, rowCall' = rowCall,
    rowAtt' = rowAtt, mixedAttempt' = mixedAttempt, mixedStep' = mixedStep, badOk' = badOk,
  }

  // assistant-stream-end {:final? true}: the reply is checked, the row closed.
  action endStop = all {
    phase == "streaming", buf == REPLY_LEN,
    badOk' = (badOk or not(open and reach and rowText and rowPure and curIsRow)),
    phase' = "idle", lastOk' = true,
    open' = false, reach' = false, rowText' = false, rowPure' = true,
    iter' = iter, calls' = calls, attempt' = attempt, buf' = buf,
    rowStep' = rowStep, rowCall' = rowCall, rowAtt' = rowAtt,
    mixedAttempt' = mixedAttempt, mixedStep' = mixedStep,
  }

  // Tool use: stream-end {:final? false} closes the row, the tool rows are
  // barriers; below the cap the next call starts, at the cap the step ends
  // (silently, or with :error after a second refusal: a non-barrier row
  // with nothing open, so the same state).
  action endToolUse = all {
    phase == "streaming", buf == REPLY_LEN,
    open' = false, reach' = false, rowText' = false, rowPure' = true,
    if (calls < SAFETY)
      all { phase' = "streaming", calls' = calls + 1, attempt' = 1, buf' = 0, lastOk' = lastOk }
    else
      all { phase' = "idle", calls' = calls, attempt' = attempt, buf' = buf, lastOk' = false },
    iter' = iter, rowStep' = rowStep, rowCall' = rowCall, rowAtt' = rowAtt,
    mixedAttempt' = mixedAttempt, mixedStep' = mixedStep, badOk' = badOk,
  }

  // :error or :cancelled: a non-barrier row; "631" closes the open row.
  action endFailed = all {
    phase == "streaming",
    phase' = "idle", lastOk' = false,
    val close = FIXES.contains("631")
    all {
      open' = if (close) false else open,
      reach' = if (close) false else reach,
      rowText' = if (close) false else rowText,
      rowPure' = if (close) true else rowPure,
    },
    iter' = iter, calls' = calls, attempt' = attempt, buf' = buf,
    rowStep' = rowStep, rowCall' = rowCall, rowAtt' = rowAtt,
    mixedAttempt' = mixedAttempt, mixedStep' = mixedStep, badOk' = badOk,
  }

  action step = any {
    startStep(true), startStep(false), streamToken, retry, endStop, endToolUse, endFailed,
  }

  // Note: write `x' = (a or b)`; `x' = a or b` parses as `(x' = a) or b`.

  // ---- properties (names as in spec/presenters/model.qnt) ----
  val webRowsSingleAttempt = not(mixedAttempt)
  val webRowsSingleStep = not(mixedStep)
  val webOkReplyShown = not(badOk)
  val allInvariants = webRowsSingleAttempt and webRowsSingleStep and webOkReplyShown

  // ---- inductive strengthenings ----
  val typeOK = and {
    phase.in(Set("idle", "streaming")),
    iter.in(0.to(MAX_STEPS)), calls.in(0.to(SAFETY)),
    attempt.in(0.to(MAX_ATTEMPTS)), buf.in(0.to(REPLY_LEN)),
    lastOk.in(Bool), open.in(Bool), reach.in(Bool), rowText.in(Bool),
    rowStep.in(0.to(MAX_STEPS)), rowCall.in(0.to(SAFETY)), rowAtt.in(0.to(MAX_ATTEMPTS)),
    rowPure.in(Bool), mixedAttempt.in(Bool), mixedStep.in(Bool), badOk.in(Bool),
  }

  // Today's design: a step-mixing join needs a reachable row with an older
  // step's text, which only a failed step leaves behind, and the next step
  // after a failure is typed (a :user barrier). "#630 is latent in web."
  val stepInv = and {
    typeOK,
    webRowsSingleStep,
    (open and reach and rowText) implies rowStep == iter,
    (phase == "idle" and lastOk) implies not(open and reach),
    phase == "streaming" implies (iter >= 1 and calls >= 1 and attempt >= 1),
  }

  // The fixed design: the reachable row holds only this attempt's text.
  val fixedInv = and {
    stepInv,
    allInvariants,
    phase == "idle" implies not(open and reach and rowText),
    (open and reach and rowText) implies (curIsRow and rowPure and phase == "streaming"),
    (phase == "streaming" and buf > 0) implies (open and reach and rowText),
    not(rowText) implies rowPure,
    not(open) implies (not(reach) and not(rowText)),
    rowText implies open,
  }
}

// Today's code carries #631.
module current { import webrows(FIXES = Set("631")).* }
module fixed { import webrows(FIXES = Set("631")).* }
