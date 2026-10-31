// Proof model: steering typed during a turn reaches that turn or is handed
// back (#662).
//
// Only the state the contract needs: whether the main turn runs and its
// number, the steering queue as (length, the turn its lines were typed for),
// counters of lines typed, delivered and handed back, and a ghost monitor
// that turns true when a line is delivered into a turn it was not typed for.
// No transcripts and no delivery list.
//
// Input assumption: the queue only ever holds lines of one turn. Today that
// holds because a new turn's start drains the queue before any new line can
// be typed for it.
//
// Integration model: ../../model.qnt.
module steering {
  const FIXES: Set[str]
  pure val MAX_TURNS = 3
  pure val MAX_TYPED = 3

  var busy: bool
  var turn: int        // number of the current (or last) main turn
  var qLen: int        // queued steering lines
  var qFor: int        // the turn those lines were typed for
  var typed: int
  var delivered: int
  var returned: int
  var misdelivered: bool

  action init = all {
    busy' = false, turn' = 0, qLen' = 0, qFor' = 0, typed' = 0, delivered' = 0,
    returned' = 0, misdelivered' = false,
  }

  // Enter while idle: step appends the prompt, then step-loop injects the
  // queued steering into the new turn.
  action submit = all {
    not(busy), turn < MAX_TURNS,
    busy' = true, turn' = turn + 1,
    misdelivered' = (misdelivered or (qLen > 0 and qFor != turn + 1)),
    delivered' = delivered + qLen, qLen' = 0, qFor' = qFor,
    typed' = typed, returned' = returned,
  }

  // Enter while busy queues a steering line for the running turn.
  action queueSteer = all {
    busy, typed < MAX_TYPED,
    qLen' = qLen + 1, qFor' = turn, typed' = typed + 1,
    busy' = busy, turn' = turn, delivered' = delivered, returned' = returned,
    misdelivered' = misdelivered,
  }

  // The top of the next step-loop iteration, or inject-after-natural-stop!
  // at an :ok end: the turn takes its own queue.
  action takeQueue = all {
    busy, qLen > 0,
    misdelivered' = (misdelivered or qFor != turn),
    delivered' = delivered + qLen, qLen' = 0,
    busy' = busy, turn' = turn, qFor' = qFor, typed' = typed, returned' = returned,
  }

  // The turn ends. :ok drains the queue; :error and cancel return without
  // draining (today), or hand the lines back (fixed).
  action finish(outcome: str): bool = all {
    busy,
    busy' = false, turn' = turn, qFor' = qFor, typed' = typed,
    if (outcome == "ok")
      all { misdelivered' = (misdelivered or (qLen > 0 and qFor != turn)),
            delivered' = delivered + qLen, qLen' = 0, returned' = returned }
    else if (FIXES.contains("662"))
      all { misdelivered' = misdelivered, delivered' = delivered, qLen' = 0,
            returned' = returned + qLen }
    else
      all { misdelivered' = misdelivered, delivered' = delivered, qLen' = qLen,
            returned' = returned },
  }

  action stutter = all {
    busy' = busy, turn' = turn, qLen' = qLen, qFor' = qFor, typed' = typed,
    delivered' = delivered, returned' = returned, misdelivered' = misdelivered,
  }

  action step = any {
    submit, queueSteer, takeQueue,
    nondet o = Set("ok", "error", "cancelled").oneOf()
    finish(o),
    stutter,
  }

  // A steering line reaches the turn it was typed for, or none at all.
  val steeringReachesItsTurn = not(misdelivered)

  // Every line typed while busy is delivered, still queued, or handed back.
  val noSteeringLost = typed == delivered + qLen + returned

  // Inductive strengthening: queued lines belong to the running turn, and
  // nothing is queued while idle.
  val steeringInductive = and {
    busy.in(Bool), turn.in(Int), qLen.in(Int), qFor.in(Int), typed.in(Int),
    delivered.in(Int), returned.in(Int), misdelivered.in(Bool),
    qLen >= 0, delivered >= 0, returned >= 0,
    qLen > 0 implies (busy and qFor == turn),
    steeringReachesItsTurn, noSteeringLost,
  }
}

module current { import steering(FIXES = Set("662")).* }
module fixed { import steering(FIXES = Set("662")).* }
