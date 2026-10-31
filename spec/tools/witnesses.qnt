// Deterministic witnesses (quint test). reach...Test shows a case the fixed
// design relies on is reachable (no vacuous pass); w...Test replays a
// counterexample for an issue a violated row still names (#656, #657 residuals).
module witnesses {
  import tools(FIXES = Set("651", "652", "653", "654", "655", "656", "657", "658", "659")) as C from "./model"
  import tools(FIXES = Set("651", "652", "653", "654", "655", "656", "657",
                           "658", "659")) as F from "./model"

  // #652: two control bytes escape to 8 bytes, filling the cap; the exit tag
  // is cut.  No split character is involved.
  run reach652ExitTagCutTest =
    C::init.then(C::oRunWith("x", "x", "none"))
      .expect(C::exitStatusVisible and C::noSplitChar)

  // #654: a cancel at the first chunk yield leaves the truncated target.
  run reach654CancelLeavesTornFileTest =
    C::init.then(C::wStartWith(false)).then(C::wChunk1).then(C::wCancel)
      .expect(C::noTornFile and C::wr.result == "cancelled")

  // #654: mid-write, any reader (or the disk after a crash) sees a prefix.
  run reach654ReaderSeesPrefixTest =
    C::init.then(C::wStartWith(false)).then(C::wChunk1)
      .expect(C::noTornTarget and C::wr.result == "none")

  // #656 (residual, under every fix): renames are atomic one file at a time;
  // a crash between them leaves the batch half-applied.  Cancel-atomic, not
  // crash-atomic.
  run w656FixedCrashBetweenRenamesTest =
    F::init.then(F::bfStart).then(F::bfStage).then(F::bfRenameA).then(F::bfCrash)
      .expect(not(F::batchCrashAtomic) and F::allInvariants)

  // #657 (residual, under every fix): an outside write between the check and
  // the rename is still lost.  Not yielding does not stop other processes.
  run w657FixedCheckRenameWindowTest =
    F::init.then(F::eStart).then(F::eCheck).then(F::eOutsideWrite).then(F::eRename)
      .expect(not(F::noLostUpdate) and F::allInvariants and F::ed.result == "ok")

  // #659: cancel closes the pipe while the child lives; pclose blocks.
  run reach659CancelBlocksInPcloseTest =
    C::init.then(C::pStart).then(C::pCancel)
      .expect(C::noUnboundedBlockingWait)

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
