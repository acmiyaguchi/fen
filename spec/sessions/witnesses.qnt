// Deterministic witnesses (quint test). Each reach...Test shows a behaviour
// of the fixed design the invariants rely on is reachable, including the former
// counterexamples of #639-#641; w<issue>...Test replays a counterexample for an
// issue a violated row still names (here: the single-fix survival traces).
module witnesses {
  import sessions(FIXES = Set("640"), OTHER_WRITER = false) as F640 from "./model"
  import sessions(FIXES = Set("641"), OTHER_WRITER = false) as F641 from "./model"
  import sessions(FIXES = Set("639", "640", "641", "642", "643"), OTHER_WRITER = true) as F
    from "./model"

  // The traces of the fixed bugs, replayed on the fixed design: each ends
  // with the invariant that used to break holding.

  // #639: killed while the tool runs; replay closes the call, so the next
  // request after --continue is valid.
  run reachCrashClosedCallValidTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(false))
      .then(F::resume).then(F::userPrompt)
      .expect(F::phase == "llm" and F::providerContextValid and F::allInvariants)

  // #640: the torn tail is terminated, so the first prompt after --continue is
  // on disk and the compaction that names it resolves.
  run reachTornTailPromptKeptTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(true))
      .then(F::resume).then(F::userPrompt).then(F::cancel).then(F::compact(3))
      .expect(F::lastAction == "compact" and F::midsOf(F::disk).contains(3)
              and F::compactionResolves and F::allInvariants)

  // #641: the first append fails; the cursor stays, so u1 is retried.
  run reachFailedAppendRetainedTest =
    F::init.then(F::failAppend).then(F::userPrompt).then(F::cancel)
      .expect(F::ackedPersisted and F::allInvariants)

  // Each persistence fix alone leaves the other bug (the fix640/fix641 rows).
  run w641SurvivesFix640Test =
    F640::init.then(F640::failAppend).then(F640::userPrompt).then(F640::cancel)
      .expect(not(F640::midsOf(F640::disk).contains(1)) and not(F640::ackedPersisted))
  run w640SurvivesFix641Test =
    F641::init.then(F641::userPrompt).then(F641::assistant(true)).then(F641::crash(true))
      .then(F641::resume).then(F641::userPrompt)
      .expect(F641::acked.contains(3) and not(F641::midsOf(F641::disk).contains(3))
              and not(F641::ackedPersisted))

  // ---- reachability of the fixed design ----

  // A tool turn completes and the log replays to memory.
  run reachTurnCompleteTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::toolResult)
      .then(F::assistant(false))
      .expect(F::phase == "idle" and F::saved == F::mem.length() and F::allInvariants)

  // A crash mid-tool is repaired on replay: the next request is valid.
  run reachCrashRepairedTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(false))
      .then(F::resume).then(F::userPrompt)
      .expect(F::phase == "llm" and F::mem.length() == 4 and F::allInvariants)

  // A torn crash costs only the line being written.
  run reachTornRecoveredTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(true))
      .then(F::resume).then(F::userPrompt).then(F::assistant(false))
      .expect(F::midsOf(F::disk).contains(3) and F::allInvariants)

  // A failed append stops the flush; the next flush retries it.
  run reachRetryAfterFailureTest =
    F::init.then(F::failAppend).then(F::userPrompt).then(F::cancel).then(F::userPrompt)
      .expect(F::midsOf(F::disk) == Set(1, 3, 4) and F::allInvariants)

  // A cancel mid-tool, then compaction.
  run reachCancelThenCompactTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::cancel)
      .then(F::userPrompt).then(F::assistant(false)).then(F::compact(4))
      .expect(F::lastAction == "compact" and F::allInvariants)

  // A second process sends while the interactive process is down.
  run reachSendWhileDownTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(false))
      .then(F::otherSend).then(F::resume).then(F::userPrompt)
      .expect(F::bContextOk and F::lastAction == "userPrompt" and F::allInvariants)

  // The doctor reports and repairs a torn line.
  run reachDoctorRepairTest =
    F::init.then(F::userPrompt).then(F::assistant(true)).then(F::crash(true))
      .expect(F::doctorIssues(F::disk) > 0 and F::allInvariants)
}
