// Deterministic witnesses (quint test) for the persistence proof model.
module witnesses {
  import persistence(FIXES = Set("640")) as F640 from "./model"
  import persistence(FIXES = Set("641")) as F641 from "./model"
  import persistence(FIXES = Set("640", "641")) as F from "./model"

  // Each fix alone leaves the other bug.
  run w641SurvivesFix640Test =
    F640::init.then(F640::failAppend).then(F640::produce).then(F640::flush)
      .expect(not(F640::ackedReadable))
  run w640SurvivesFix641Test =
    F641::init.then(F641::produce).then(F641::flush).then(F641::produce)
      .then(F641::crash(true)).then(F641::resume).then(F641::produce).then(F641::flush)
      .expect(not(F641::ackedReadable))

  // ---- reachability of the fixed design ----

  // Messages are flushed and readable.
  run reachFlushTest =
    F::init.then(F::produce).then(F::produce).then(F::flush).then(F::flush)
      .expect(F::readable == Set(1, 2) and F::replayMatchesMemory and F::persistInductive)

  // A failed append is retried by the next flush.
  run reachRetryAfterFailureTest =
    F::init.then(F::failAppend).then(F::produce).then(F::flush).then(F::flush)
      .expect(F::readable == Set(1) and F::saved == 1 and F::persistInductive)

  // A torn crash costs only the entry being written; the next append after
  // --continue is readable.
  run reachTornCrashRecoveredTest =
    F::init.then(F::produce).then(F::flush).then(F::produce).then(F::crash(true))
      .then(F::resume).then(F::produce).then(F::flush)
      .expect(F::readable == Set(1, 3) and F::mem == Set(1, 3) and F::persistInductive)
}
