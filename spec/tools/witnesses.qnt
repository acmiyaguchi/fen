// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue; each reach...Test shows a
// case the `fixed` invariants rely on is reachable (no vacuous pass).
module witnesses {
  import tools(FIXES = Set()) as C from "./model"
  import tools(FIXES = Set("651", "652", "653", "654", "655", "656", "657",
                           "658", "659")) as F from "./model"

  // #651: SIGTERM at the deadline kills the leader; the member that ignores
  // TERM survives, SIGKILL is gated on the unreaped leader, and the job
  // returns with the member still alive.
  run w651TermIgnoringMemberSurvivesTest =
    C::init.then(C::bStartWith(false, true)).then(C::bDeadline).then(C::bFinish)
      .expect(not(C::noLiveProcessAfterAbnormalEnd)
              and C::bash.timedOut and not(C::bash.killSent))

  // #652: two control bytes escape to 8 bytes, filling the cap; the exit tag
  // is cut.  No split character is involved.
  run w652ExitTagCutTest =
    C::init.then(C::oRunWith("x", "x", "none"))
      .expect(not(C::exitStatusVisible) and C::noSplitChar)

  // #653: [L C L C] keeps its last 3 bytes, starting on a continuation byte.
  run w653TailStartsMidCharTest =
    C::init.then(C::oRunWith("e", "e", "none"))
      .expect(not(C::noSplitChar) and C::out.trimmed == ["C", "L", "C"])

  // #654: a cancel at the first chunk yield leaves the truncated target.
  run w654CancelLeavesTornFileTest =
    C::init.then(C::wStartWith(false)).then(C::wChunk1).then(C::wCancel)
      .expect(not(C::noTornFile) and C::wr.result == "cancelled")

  // #654: mid-write, any reader (or the disk after a crash) sees a prefix.
  run w654ReaderSeesPrefixTest =
    C::init.then(C::wStartWith(false)).then(C::wChunk1)
      .expect(not(C::noTornTarget) and C::wr.result == "none")

  // #655: ENOSPC on a chunk is ignored and the tool reports ok.
  run w655FailedWriteReportsOkTest =
    C::init.then(C::wStartWith(true)).then(C::wChunk1).then(C::wChunk2)
      .then(C::wClose).then(C::wReturn)
      .expect(not(C::okMeansWritten) and C::wr.disk == "part")

  // #656: a cancel between the files of a batch leaves a written, b not.
  run w656BatchCancelBetweenFilesTest =
    C::init.then(C::bfStart).then(C::bfWriteA).then(C::bfCancel)
      .expect(not(C::batchAllOrNothing) and C::batch.a and not(C::batch.b))

  // #656: the yield after edit's commit turns a completed edit into
  // "cancelled".
  run w656CancelAfterCommitTest =
    C::init.then(C::eStart).then(C::eWrite).then(C::eCancel)
      .expect(not(C::cancelledMeansUnchanged) and C::ed.committed
              and C::ed.result == "cancelled")

  // #656 (residual, under every fix): renames are atomic one file at a time;
  // a crash between them leaves the batch half-applied.  Cancel-atomic, not
  // crash-atomic.
  run w656FixedCrashBetweenRenamesTest =
    F::init.then(F::bfStart).then(F::bfStage).then(F::bfRenameA).then(F::bfCrash)
      .expect(not(F::batchCrashAtomic) and F::allInvariants)

  // #657: an outside write during edit's yields is reverted.
  run w657OutsideWriteRevertedTest =
    C::init.then(C::eStart).then(C::eOutsideWrite).then(C::eWrite)
      .expect(not(C::noLostUpdate) and not(C::outsideLossOnlyInWindow)
              and C::noLostFenUpdate)

  // #657: so is a sibling fen process's edit or write (the in-process mutex
  // does not order processes).
  run w657FenWriteRevertedTest =
    C::init.then(C::eStart).then(C::eFenWrite).then(C::eWrite)
      .expect(not(C::noLostFenUpdate))

  // #657 (residual, under every fix): an outside write between the check and
  // the rename is still lost.  Not yielding does not stop other processes.
  run w657FixedCheckRenameWindowTest =
    F::init.then(F::eStart).then(F::eCheck).then(F::eOutsideWrite).then(F::eRename)
      .expect(not(F::noLostUpdate) and F::allInvariants and F::ed.result == "ok")

  // #658: "aaab" has two overlapping "aa"; find-all counts one.
  run w658OverlapCountedOnceTest =
    C::init.then(C::vRunWith(["a", "a", "a", "b"]))
      .expect(not(C::uniqueMatchIsUnique) and C::ov.found == 1 and C::ov.actual == 2)

  // #659: cancel closes the pipe while the child lives; pclose blocks.
  run w659CancelBlocksInPcloseTest =
    C::init.then(C::pStart).then(C::pCancel)
      .expect(not(C::noUnboundedBlockingWait))

  // ---- reachability of the fixed design ----

  run reachBashCleanExitTest =
    F::init.then(F::bStartWith(false, false)).then(F::bLeaderExit)
      .then(F::bMemberExit).then(F::bFinish)
      .expect(F::bash.done and not(F::bash.killSent) and F::allInvariants)

  run reachBashTimeoutKillsGroupTest =
    F::init.then(F::bStartWith(false, true)).then(F::bDeadline).then(F::bGrace)
      .then(F::bFinish)
      .expect(F::bash.done and F::bash.timedOut and not(F::bash.memberAlive)
              and F::allInvariants)

  run reachBashCancelAfterReapTest =
    F::init.then(F::bStartWith(false, false)).then(F::bLeaderExit)
      .then(F::bCancel).then(F::bFinish)
      .expect(F::bash.cancelled and not(F::bash.memberAlive) and F::allInvariants)

  run reachPopenCancelKillsTest =
    F::init.then(F::pStart).then(F::pCancel).then(F::pCloseReturns)
      .expect(F::popen.result == "cancelled" and F::allInvariants)

  run reachWriteOkTest =
    F::init.then(F::wStartWith(false)).then(F::wChunk1).then(F::wChunk2)
      .then(F::wClose)
      .expect(F::wr.result == "ok" and F::wr.disk == "new" and F::allInvariants)

  run reachWriteErrorTest =
    F::init.then(F::wStartWith(true)).then(F::wChunk1).then(F::wChunk2)
      .then(F::wClose)
      .expect(F::wr.result == "error" and F::wr.disk == "orig" and F::allInvariants)

  run reachWriteCancelTest =
    F::init.then(F::wStartWith(false)).then(F::wChunk1).then(F::wCancel)
      .expect(F::wr.result == "cancelled" and F::wr.disk == "orig" and F::allInvariants)

  run reachEditOkTest =
    F::init.then(F::eStart).then(F::eCheck).then(F::eRename)
      .expect(F::ed.result == "ok" and F::ed.committed and F::allInvariants)

  // The check catches a change made while the edit yielded.
  run reachEditDetectsChangeTest =
    F::init.then(F::eStart).then(F::eOutsideWrite).then(F::eCheck)
      .expect(F::ed.result == "error" and not(F::ed.committed) and F::allInvariants)

  // Another fen writer waits on the kernel lock instead of interleaving:
  // the lock is held through the check/rename window (eFenWrite is disabled).
  run reachEditLockExcludesFenWriterTest =
    F::init.then(F::eStart).then(F::eCheck)
      .expect(F::ed.phase == "checked" and F::fenLockHeld(F::ed) and F::allInvariants)

  run reachEditCancelTest =
    F::init.then(F::eStart).then(F::eCancel)
      .expect(F::ed.result == "cancelled" and not(F::ed.committed) and F::allInvariants)

  run reachBatchOkTest =
    F::init.then(F::bfStart).then(F::bfStage).then(F::bfRenameA).then(F::bfWriteB)
      .expect(F::batch.result == "ok" and F::batch.a and F::batch.b and F::allInvariants)

  run reachBatchCancelWhileStagingTest =
    F::init.then(F::bfStart).then(F::bfStage).then(F::bfCancel)
      .expect(F::batch.result == "cancelled" and not(F::batch.a) and F::allInvariants)

  // Between the renames there is no yield, so bfCancel is disabled there.
  run reachBatchNoCancelBetweenRenamesTest =
    F::init.then(F::bfStart).then(F::bfStage).then(F::bfRenameA)
      .expect(F::batch.phase == "aDone"
              and not(Set("pre", "staged").contains(F::batch.phase))
              and F::allInvariants)

  run reachOutputTagKeptTest =
    F::init.then(F::oRunWith("x", "x", "none"))
      .expect(F::out.kept.length() > 0 and F::allInvariants)

  run reachSplitCharSkippedTest =
    F::init.then(F::oRunWith("e", "e", "none"))
      .expect(F::out.trimmed == ["L", "C"] and F::allInvariants)

  run reachOverlapRejectedTest =
    F::init.then(F::vRunWith(["a", "a", "a", "b"]))
      .expect(F::ov.found == 2 and F::allInvariants)

  run reachUniqueAcceptedTest =
    F::init.then(F::vRunWith(["a", "a", "b", "b"]))
      .expect(F::ov.found == 1 and F::allInvariants)
}
