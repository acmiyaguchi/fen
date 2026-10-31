// Sessions replay as a transducer obligation (#668 core, #639, #643): the
// sessions model's own projection and repair (planEntry, closeReplay,
// contextValid, the doctor) must satisfy the core replay laws on every
// message log of up to MAX_LEN entries, chosen in init. This checks the
// projection onto the core (aborted markers as boundaries, summaries as
// user text), not just the core itself (spec/core/replay).
//
// Input assumptions: messages are user, assistant text, a tool call (one
// call per assistant, as in the sessions model), a result for call 0 or 1,
// an :aborted marker, or a compaction summary; ids 0 and 1 may repeat.
// The laws are stated for logs in which an :aborted marker never sits
// between a call and its result (`abortedAfterPairing`): the cancel path
// pairs every open call before it appends the marker, and with the #642
// lock no second writer interleaves. Replay treats a marker as a turn
// boundary while the provider view drops it, so on a log that breaks this
// assumption the two disagree (the sampled check `assumptionNeeded` shows
// such a log exists).
module sessionsReplay {
  import sessions(FIXES = Set("639", "643"), OTHER_WRITER = false) as S from "../../model"

  pure val MAX_LEN = 5
  pure val MSGS: Set[S::Msg] = Set(
    { mid: 1, role: "user", call: -1 },
    { mid: 2, role: "asst", call: -1 },
    { mid: 3, role: "call", call: 0 },
    { mid: 4, role: "call", call: 1 },
    { mid: 5, role: "result", call: 0 },
    { mid: 6, role: "result", call: 1 },
    { mid: 7, role: "aborted", call: -1 },
    { mid: 0, role: "summary", call: -1 },
  )

  var ms: List[S::Msg]

  action init = all {
    S::init,
    nondet len = 0.to(MAX_LEN).oneOf()
    nondet m0 = MSGS.oneOf()
    nondet m1 = MSGS.oneOf()
    nondet m2 = MSGS.oneOf()
    nondet m3 = MSGS.oneOf()
    nondet m4 = MSGS.oneOf()
    ms' = [m0, m1, m2, m3, m4].slice(0, len),
  }
  action load(l: List[S::Msg]): bool = all { S::init, ms' = l }
  action step = all { S::init, ms' = ms }

  pure def lines(l: List[S::Msg]): List[S::Line] = l.foldl([], (acc, m) => acc.append(S::msgLine(m)))

  // No :aborted marker while a call is waiting for its result.
  pure def abortedAfterPairing(l: List[S::Msg]): bool =
    l.foldl({ open: false, ok: true }, (st, m) =>
      if (m.role == "call") { open: true, ok: st.ok }
      else if (m.role == "aborted") { open: false, ok: st.ok and not(st.open) }
      else { open: false, ok: st.ok }).ok

  // closeReplay output is provider-valid, leaves valid logs alone, and the
  // doctor (on the same messages as JSONL lines) is clean exactly when the
  // log is valid; --repair output is valid.
  val sessionsReplayValid = S::contextValid(S::closeReplay(ms))
  val sessionsReplayKeepsValid =
    (abortedAfterPairing(ms) and S::contextValid(ms)) implies S::closeReplay(ms) == ms
  val sessionsDoctorCleanIffValid =
    abortedAfterPairing(ms) implies ((S::doctorIssuesCore(lines(ms)) == 0) == S::contextValid(ms))
  // Expected to be violated: without the assumption the laws fail.
  val assumptionNeeded = S::contextValid(ms) implies S::closeReplay(ms) == ms
  val sessionsDoctorRepairValid = S::contextValid(S::replayRaw(S::doctorRepairCore(lines(ms))))
  // The doctor's --repair output is replay's output (so it is valid by
  // sessionsReplayValid). This is what verify.tsv proves: checking validity
  // of the repaired file directly nests two reconstructions and times out.
  val sessionsDoctorRepairIsReplay = S::msgsOf(S::doctorRepairCore(lines(ms))) == S::closeReplay(ms)
}
