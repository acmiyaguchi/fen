// Reachability of the abstract process job machine: each interesting lifecycle
// path actually happens, so the inductive proof is not vacuous.
module witnesses {
  import jobSpec as J from "./model"

  // Clean completion: spawn, stream output, processes exit, finish ok.
  run reachCleanCompletionTest =
    J::init.then(J::doSpawn).then(J::doAppendOutput).then(J::doLeaderExit)
      .then(J::doMemberExit).then(J::doFinish("ok"))
      .expect(J::a.phase == "done" and J::a.outcome == "ok" and J::allInvariants)

  // Timeout and grace expiry: SIGTERM sent, grace expires -> SIGKILL sent to group.
  run reachTimeoutAndGraceTest =
    J::init.then(J::doSpawn).then(J::doTimeout(false, false)).then(J::doGraceExpired)
      .then(J::doFinish("ok"))
      .expect(J::a.phase == "done" and J::a.outcome == "timeout" and J::a.killSent and J::allInvariants)

  // Cancel immediately kills group and finishes with cancelled outcome.
  run reachCancelAbortTest =
    J::init.then(J::doSpawn).then(J::doCancel).then(J::doFinish("ok"))
      .expect(J::a.phase == "done" and J::a.outcome == "cancelled" and J::allInvariants)

  // Output streaming reaches body limit and truncates, but trailer is preserved.
  run reachOutputTruncationTest =
    J::init.then(J::doSpawn).then(J::doAppendOutput).then(J::doAppendOutput).then(J::doAppendOutput)
      .then(J::doLeaderExit).then(J::doMemberExit).then(J::doFinish("ok"))
      .expect(J::a.truncated and J::a.hasTrailer and J::a.outLen == 3 and J::allInvariants)

  // Group member survives leader exit, but timeout finish cleans up member.
  run reachAbnormalFinishCleansGroupTest =
    J::init.then(J::doSpawn).then(J::doTimeout(true, false)).then(J::doFinish("ok"))
      .expect(J::a.phase == "done" and J::a.outcome == "timeout" and not(J::a.membersAlive) and J::allInvariants)
}
