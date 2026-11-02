// Liveness model for the L0 session lease (../lease), checked with TLC.
//
// Mirrors leaseAbstract's step relation with the counters abstracted away:
//   - `n` (turn number) and `hid` (holder id) are dropped. They only feed
//     cancel fencing and the turn numbering, which are safety properties
//     proved on ../lease; no L0 guard on starting or releasing a holder reads
//     them, so dropping them does not change which holders can start. The
//     state is then finite (3 kinds x 4 booleans + 1 ghost).
//   - `cancel` is kept but only as "the current holder was armed": it never
//     blocks or forces anything in L0 (a cancelled body still exits by the
//     ordinary release), so it is here only to keep the step relation whole.
//   - `last` is a ghost: the name of the last action taken. It lets the
//     assumption "finitely many new offers" and the "withdrawn" exit of the
//     turn property be stated temporally (a withdrawal by doDropStart is
//     distinguishable from a request consumed without starting a turn).
//
// No forced steps: fairness is stated as temporal assumptions in each
// property (TLC checks `Spec => (fairness => goal)`).

module liveness {
  var kind: str        // "none" | "turn" | "exclusive"
  var body: bool
  var cancel: bool
  var startReq: bool
  var exReq: bool
  var last: str        // ghost: last action taken ("init" initially)

  val vars = (kind, body, cancel, startReq, exReq, last)

  action init = all {
    kind' = "none", body' = false, cancel' = false,
    startReq' = false, exReq' = false, last' = "init",
  }

  // next-start! + (with-holder :turn ...): consumes the request.
  action doStartTurn = all {
    kind == "none", startReq,
    kind' = "turn", body' = true, cancel' = false, startReq' = false,
    exReq' = exReq, last' = "doStartTurn",
  }

  // next-job!: one scheduler; a pending turn start has priority.
  action doStartExclusive = all {
    kind == "none", exReq, not(startReq),
    kind' = "exclusive", body' = true, cancel' = false, exReq' = false,
    startReq' = startReq, last' = "doStartExclusive",
  }

  action doRequestExclusive = all {
    not(exReq),
    exReq' = true,
    kind' = kind, body' = body, cancel' = cancel, startReq' = startReq, last' = "doRequestExclusive",
  }

  // The body exits (return, error, or after a cancel): leaseRelease.
  action doBodyExit = all {
    body,
    kind' = "none", body' = false, cancel' = false,
    startReq' = startReq, exReq' = exReq, last' = "doBodyExit",
  }

  action doCancel = all {
    kind != "none", not(cancel),
    cancel' = true,
    kind' = kind, body' = body, startReq' = startReq, exReq' = exReq, last' = "doCancel",
  }

  // A start request is raised while no turn holds (idle offer, or one behind
  // an exclusive job) ...
  action doRequestStart = all {
    kind != "turn", not(startReq),
    startReq' = true, last' = "doRequestStart",
    kind' = kind, body' = body, cancel' = cancel, exReq' = exReq,
  }

  // ... or withdrawn (its line was cleared).
  action doDropStart = all {
    startReq,
    startReq' = false, last' = "doDropStart",
    kind' = kind, body' = body, cancel' = cancel, exReq' = exReq,
  }

  action step = any {
    doStartTurn,
    doStartExclusive,
    doRequestExclusive,
    doBodyExit,
    doCancel,
    doRequestStart,
    doDropStart,
  }

  // ---- Fairness assumptions ----
  // Turn bodies (and exclusive bodies) eventually exit; the scheduler does
  // not stall while it has something to start.
  temporal fairBody = weakFair(doBodyExit, vars)
  temporal fairSchedWeak = weakFair(doStartTurn, vars) and weakFair(doStartExclusive, vars)
  // Strong fairness for the exclusive start: if it is enabled infinitely
  // often (every release with no pending turn start), it eventually runs.
  temporal fairExclusiveStrong = strongFair(doStartExclusive, vars)
  // Finitely many new offers: from some point on, no start request is raised.
  temporal finiteOffers = eventually(always(last != "doRequestStart"))

  // ---- Properties ----

  // Every requested turn start eventually runs, unless withdrawn (its line
  // was cleared: doDropStart). A request consumed without a turn fails it.
  temporal turnStartLive =
    (fairBody and fairSchedWeak)
      implies always(startReq implies eventually(kind == "turn" or last == "doDropStart"))

  // Every holder is released.
  temporal releaseLive =
    fairBody implies always(kind != "none" implies eventually(kind == "none"))

  // Every requested exclusive job eventually runs: the plain claim under weak
  // fairness alone. EXPECTED TO FAIL: offers raised after each release keep a
  // turn start pending, and a pending turn start beats the exclusive job, so
  // turns can starve it forever (doStartExclusive is enabled only
  // intermittently, which weak fairness does not cover).
  temporal exclusiveLiveWeak =
    (fairBody and fairSchedWeak)
      implies always(exReq implies eventually(kind == "exclusive"))

  // The same with withdrawals ruled out from some point on: the remaining
  // counterexample is repeated turns (offer, turn, release, offer, ...).
  temporal exclusiveLiveWeakNoDrop =
    (fairBody and fairSchedWeak and eventually(always(last != "doDropStart")))
      implies always(exReq implies eventually(kind == "exclusive"))

  // Holds with finitely many new offers.
  temporal exclusiveLiveFiniteOffers =
    (fairBody and fairSchedWeak and finiteOffers)
      implies always(exReq implies eventually(kind == "exclusive"))

  // Holds with strong fairness on the exclusive start: every release leaves
  // a state with no pending start (offers are raised one step at a time),
  // so the exclusive start is enabled infinitely often.
  temporal exclusiveLiveStrong =
    (fairBody and fairSchedWeak and fairExclusiveStrong)
      implies always(exReq implies eventually(kind == "exclusive"))
}
