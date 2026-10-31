// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue; each reach...Test shows a
// behaviour of the fixed design the invariants rely on is reachable.
module witnesses {
  import sessions(FIXES = Set(), OTHER_WRITER = true) as C from "./model"
  import sessions(FIXES = Set(), OTHER_WRITER = false) as S from "./model"
  import sessions(FIXES = Set("640"), OTHER_WRITER = false) as F640 from "./model"
  import sessions(FIXES = Set("641"), OTHER_WRITER = false) as F641 from "./model"
  import sessions(FIXES = Set("639", "640", "641", "642", "643"), OTHER_WRITER = true) as F
    from "./model"
  import lock(FIXES = Set()) as LC from "./proofs/lock/model"

  // #639: killed while the tool runs; the log ends at the call and the next
  // request after --continue sends it with no result.
  run w639CrashLeavesUnpairedCallTest =
    S::init.then(S::userPrompt).then(S::assistant(true)).then(S::crash(false))
      .then(S::resume).then(S::userPrompt)
      .expect(S::phase == "llm" and S::mem.foldl([], (a, m) => a.append(m.role)) == ["user", "call", "user"]
              and not(S::torn) and not(S::providerContextValid))

  // #640: a torn line swallows the first prompt after --continue, which a
  // compaction then names as its first kept entry.
  run w640TornTailSwallowsAppendTest =
    S::init.then(S::userPrompt).then(S::assistant(true)).then(S::crash(true))
      .then(S::resume).then(S::userPrompt).then(S::cancel).then(S::compact(2))
      .expect(S::lastAction == "compact" and S::acked.contains(3)
              and not(S::midsOf(S::disk).contains(3)) and not(S::compactionResolves))

  // #641: the first append fails; the cursor moves past it, so u1 is lost.
  run w641CursorPassesFailedAppendTest =
    S::init.then(S::failAppend).then(S::userPrompt).then(S::cancel)
      .expect(S::acked.contains(1) and not(S::midsOf(S::disk).contains(1))
              and not(S::torn) and not(S::ackedPersisted))

  // Each persistence fix alone leaves the other bug (the fix640/fix641 rows).
  run w641SurvivesFix640Test =
    F640::init.then(F640::failAppend).then(F640::userPrompt).then(F640::cancel)
      .expect(not(F640::midsOf(F640::disk).contains(1)) and not(F640::ackedPersisted))
  run w640SurvivesFix641Test =
    F641::init.then(F641::userPrompt).then(F641::assistant(true)).then(F641::crash(true))
      .then(F641::resume).then(F641::userPrompt)
      .expect(F641::acked.contains(3) and not(F641::midsOf(F641::disk).contains(3))
              and not(F641::ackedPersisted))

  // #642: `session send` runs while the interactive process is alive and
  // its tool call has no result yet.
  run w642SendDuringInteractiveTurnTest =
    C::init.then(C::userPrompt).then(C::assistant(true)).then(C::otherSend)
      .expect(C::up and C::phase == "tools" and not(C::bContextOk)
              and not(C::providerContextValid))

  // #643: the interleaved transcript of #642 pairs by id, so the doctor is
  // clean, yet a message sits between the call and its result.
  run w643DoctorCleanOnInterleavedTest =
    C::init.then(C::userPrompt).then(C::assistant(true)).then(C::otherSend).then(C::cancel)
      .expect(C::doctorIssues(C::disk) == 0 and not(C::contextValid(C::replayRaw(C::disk)))
              and not(C::doctorCleanMeansReplayable) and not(C::doctorRepairReplayable))

  // #644: both senders pass the stale-owner check before either removes
  // anything (12 steps; same trace as proofs/lock).
  run w644DoubleReclaimTest =
    LC::init.then(LC::tryMkdir(1)).then(LC::tryMkdir(2))
      .then(LC::readOwner(1)).then(LC::readOwner(2))
      .then(LC::recheck(1)).then(LC::recheck(2))
      .then(LC::rmOwner(1)).then(LC::rmdir(1)).then(LC::mk(1))
      .then(LC::rmOwner(2)).then(LC::rmdir(2)).then(LC::mk(2))
      .expect(LC::pc.get(1) == "own" and LC::pc.get(2) == "own" and not(LC::lockMutex))

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

  // The same bugs through the replay-equals-memory and compaction checks.
  run w641ReplayDiffersFromMemoryTest =
    S::init.then(S::failAppend).then(S::userPrompt).then(S::cancel)
      .expect(not(S::replayMatchesMemory))
  run w642ReplayDiffersFromMemoryTest =
    C::init.then(C::userPrompt).then(C::assistant(true)).then(C::otherSend)
      .expect(not(C::replayMatchesMemory))
  run w642CompactionCutSplitsPairTest =
    C::init.then(C::userPrompt).then(C::assistant(true)).then(C::otherSend).then(C::cancel)
      .then(C::crash(false)).then(C::resume).then(C::compact(2))
      .expect(not(C::compactionCutKeepsPairs))
}
