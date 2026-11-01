// Deterministic witnesses (quint test) for the serve integration model.
// Each w<issue>...Test replays the shortest known counterexample for one
// violated row against the design instance that row names; each reach...Test
// shows the proposed protocol (`proposed`/`proposedTui`, which play the part
// of `fixed`) still reaches a case its invariants guard (answers, cancels,
// steering, countdown timeouts, immediate fallback, resume, reset), so no
// invariant holds vacuously.
module witnesses {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false) as I from "./model"
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlDup",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false) as D from "./model"
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = false,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false) as H from "./model"
  import serve(ANSWER_BY_ID = false, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = true, RELOAD_RESOLVES = false) as W from "./model"
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
               TIMEOUTS = true, TARGETED = true, REPLAY = "ring",
               RECHECK = true, VERSIONED = true, LOCAL = false,
               REMOTE_SLASH = false, RELOAD_RESOLVES = true) as P from "./model"
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
               TIMEOUTS = true, TARGETED = true, REPLAY = "ring",
               RECHECK = true, VERSIONED = true, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = true) as T from "./model"
  import issueRefines as IR from "./model"
  import proposedRefines as PR from "./model"

  // ---- #638 (today's code) ----

  // issue.resolutionInScope: an idle-only command's picker is open, a turn
  // starts under it, and the command's continuation runs inside the turn.
  run w638IdleCommandActsInTurnTest =
    I::init.then(I::cmdRequest(0)).then(I::send(0)).then(I::answer(0, 1))
      .expect(not(I::resolutionInScope) and I::lastAction == "answerCmdWhileBusy"
              and I::s.running and I::s.reqs.get(1).turn == 0)

  // issueRefines.refinesTasks (#638): answering an idle picker while a turn is
  // running resolves it to "answered" instead of "aborted", breaking `reqAbsNext`.
  run w638RefinementViolatedTest =
    IR::init.then(IR::mCmdRequest(0)).then(IR::mSend(0)).then(IR::mAnswer(0, 1))
      .expect(not(IR::refinesTasks))

  // ---- #397 (V1) ----

  // issue.cancelHitsSeenTurn: the remote saw turn 1; its cancel kills turn 2.
  run w397CancelHitsSeenTurnTest =
    I::init.then(I::connect(1, false)).then(I::finishReplay(1)).then(I::send(0))
      .then(I::naturalEnd).then(I::send(0)).then(I::deliver(1)).then(I::cancel(1))
      .expect(not(I::cancelHitsSeenTurn) and I::s.cancels == [{ seen: 1, hit: 2 }])

  // issue.steeringReachesSeenTurn: the remote still sees idle; its prompt is
  // queued as steering and injected into the local user's turn 1.
  run w397SteeringIntoOtherTurnTest =
    I::init.then(I::connect(1, false)).then(I::finishReplay(1)).then(I::send(0))
      .then(I::send(1)).then(I::inject)
      .expect(not(I::steeringReachesSeenTurn) and I::lastAction == "inject"
              and I::s.steers[1] == { seen: 0, into: 1 })

  // issueRefines.refinesTasks (#397): the plain queue keeps turn 1's unread
  // steering line when the turn ends, so the end is not the holder's
  // `release` (which hands every unread steer line back) and the line is
  // carried into the next turn. (An untagged line queued into a turn the
  // sender did not see is a legal no-:turn `offer` at the abstract level;
  // that half of #397 is `steeringReachesSeenTurn`.)
  run w397RefinementViolatedTest =
    IR::init.then(IR::mConnect(1, false)).then(IR::mFinishReplay(1)).then(IR::mSend(0))
      .then(IR::mSend(1)).then(IR::mNaturalEnd)
      .expect(not(IR::refinesTasks) and IR::state.queue.length() == 1 and not(IR::state.running))

  // ---- #398 ----

  // issue.noPendingForEndedTurn (V2): a turn's request outlives the cancel.
  run w398TurnRequestOutlivesTurnTest =
    I::init.then(I::send(0)).then(I::toolRequest).then(I::cancel(0))
      .expect(not(I::noPendingForEndedTurn) and I::s.reqs.get(1).status == "pending"
              and not(I::s.running))

  // issueRefines.refinesTasks / inheritsTasksInvariants (#398): opening a request
  // without a countdown budget or leaving it pending on cancel violates refinement.
  run w398RefinementViolatedTest =
    IR::init.then(IR::mSend(0)).then(IR::mToolRequest)
      .expect(not(IR::refinesTasks) and not(IR::inheritsTasksInvariants))

  // issue.noStaleContinuation (V5): a picker survives /reload and its
  // pre-reload continuation runs.
  run w398StaleContinuationAfterReloadTest =
    I::init.then(I::cmdRequest(0)).then(I::reload).then(I::answer(0, 1))
      .expect(not(I::noStaleContinuation) and I::lastAction == "answerCmd" and I::s.gen == 1)

  // issue.answerMatchesShownChoices (V6): /model refreshes its choices
  // unannounced; the answer made against the first list is applied.
  run w398AnswerAgainstStaleChoicesTest =
    I::init.then(I::cmdRequest(0)).then(I::updateChoices(1)).then(I::answer(0, 1))
      .expect(not(I::answerMatchesShownChoices) and I::lastAction == "answerCmd"
              and I::s.reqs.get(1).ver == 1)

  // issue.answersAcked (V7): a late answer is ignored without an ack.
  run w398LateAnswerUnackedTest =
    I::init.then(I::cmdRequest(0)).then(I::answer(0, 1)).then(I::cmdRequest(0))
      .then(I::answer(0, 1))
      .expect(not(I::answersAcked) and I::lastAction == "answerLate" and I::s.unacked == 1)

  // headless.pendingHasPossibleResolver (V4): the only remote disconnects
  // while the turn is parked on a request with no deadline.
  run w398HeadlessRequestNoResolverTest =
    H::init.then(H::connect(1, false)).then(H::finishReplay(1)).then(H::send(1))
      .then(H::toolRequest).then(H::disconnect(1))
      .expect(not(H::pendingHasPossibleResolver) and H::s.parkedOn == 1
              and not(H::s.reqs.get(1).deadline))

  // ---- #396 ----

  // issue.noSilentGap (V8): the user message appended during the yielding
  // replay is in neither the snapshot nor the live stream.
  run w396ReplayGapTest =
    I::init.then(I::connect(1, false)).then(I::send(0)).then(I::finishReplay(1))
      .then(I::toolRequest).then(I::deliver(1))
      .expect(not(I::noSilentGap) and I::s.cl.get(1).got == [3])

  // issue.caughtUpSeesTurn (V8): replay finishes caught up, but believes idle.
  run w396CaughtUpMissesTurnTest =
    I::init.then(I::connect(1, false)).then(I::send(0)).then(I::finishReplay(1))
      .expect(not(I::caughtUpSeesTurn) and I::s.cl.get(1).seenTurn == 0 and I::s.running)

  // issue.caughtUpSeesPending (V8): ... and knows no pending request.
  run w396CaughtUpMissesPendingTest =
    I::init.then(I::connect(1, false)).then(I::cmdRequest(0)).then(I::finishReplay(1))
      .expect(not(I::caughtUpSeesPending) and I::s.cl.get(1).known == Set())

  // issueDup.inOrderDelivery (V8): the assistant message appended during
  // replay arrives live before an older line from the file ...
  run w396ReplayOutOfOrderTest =
    D::init.then(D::send(0)).then(D::connect(1, false)).then(D::replayStep(1))
      .then(D::naturalEnd).then(D::deliver(1)).then(D::replayStep(1))
      .expect(not(D::inOrderDelivery) and D::s.cl.get(1).got == [3, 2])

  // issueDup.noDuplicateDelivery (V8): ... and again from the growing file.
  run w396ReplayDuplicatesTest =
    D::init.then(D::send(0)).then(D::connect(1, false)).then(D::replayStep(1))
      .then(D::naturalEnd).then(D::deliver(1)).then(D::replayStep(1)).then(D::replayStep(1))
      .expect(not(D::noDuplicateDelivery) and D::s.cl.get(1).got == [3, 2, 3])

  // webReuse.answerHitsItsRequest (V9): the reused /select applies a stale
  // bare-index answer to whatever select is active.
  run w396BareIndexHitsOtherRequestTest =
    W::init.then(W::cmdRequest(0)).then(W::answer(0, 1)).then(W::cmdRequest(0))
      .then(W::answer(0, 1))
      .expect(not(W::answerHitsItsRequest) and W::s.applied[1] == {
                aimed: 1, target: 2, inScope: true, fresh: true, verOk: true })

  // webReuse.remoteNoCommands (V9): a remote "/" line opens a picker.
  run w396RemoteSlashCommandTest =
    W::init.then(W::connect(1, false)).then(W::finishReplay(1)).then(W::cmdRequest(1))
      .expect(not(W::remoteNoCommands) and W::s.remoteCmds == 1)

  // ---- reachability of the proposed protocol ----

  run reachCancelSeenTurnTest =
    T::init.then(T::send(0)).then(T::cancel(0))
      .expect(T::s.cancels == [{ seen: 1, hit: 1 }] and not(T::s.running) and T::allInvariants)

  run reachStaleCancelRejectedTest =
    T::init.then(T::connect(1, false)).then(T::send(0)).then(T::deliver(1)).then(T::naturalEnd)
      .then(T::send(0)).then(T::cancel(1))
      .expect(T::lastAction == "cancelNoop" and T::s.running and T::s.turnNo == 2
              and T::allInvariants)

  run reachSteerIntoSeenTurnTest =
    T::init.then(T::connect(1, false)).then(T::send(0)).then(T::deliver(1)).then(T::send(1))
      .then(T::inject)
      .expect(T::s.steers[1] == { seen: 1, into: 1 } and T::allInvariants)

  run reachTurnRequestAnsweredTest =
    P::init.then(P::connect(1, false)).then(P::send(1)).then(P::toolRequest)
      .then(P::deliver(1)).then(P::deliver(1)).then(P::deliver(1)).then(P::answer(1, 1))
      .expect(P::lastAction == "answerResumesTurn" and P::s.parkedOn == -1 and P::allInvariants)

  run reachCancelResolvesRequestTest =
    T::init.then(T::send(0)).then(T::toolRequest).then(T::cancel(0))
      .expect(T::s.reqs.get(1).status == "ended" and T::allInvariants)

  run reachReloadResolvesPickerTest =
    T::init.then(T::cmdRequest(0)).then(T::reload)
      .expect(T::s.reqs.get(1).status == "cancelled" and T::allInvariants)

  run reachPickerAbortedByTurnTest =
    T::init.then(T::cmdRequest(0)).then(T::send(0)).then(T::answer(0, 1))
      .expect(T::lastAction == "answerAbortedBusy" and T::allInvariants)

  run reachStaleChoicesRejectedTest =
    T::init.then(T::connect(1, false)).then(T::cmdRequest(0)).then(T::deliver(1))
      .then(T::updateChoices(1)).then(T::answer(1, 1))
      .expect(T::lastAction == "answerRejectedStaleChoices" and T::allInvariants)

  run reachLateAnswerAckedTest =
    T::init.then(T::cmdRequest(0)).then(T::answer(0, 1)).then(T::answer(0, 1))
      .expect(T::lastAction == "answerLate" and T::s.unacked == 0 and T::allInvariants)

  run reachTimeoutTest =
    PR::init.then(PR::mConnect(1, false)).then(PR::mSend(1)).then(PR::mToolRequest)
      .then(PR::mDisconnect(1)).then(PR::mTickReq(1)).then(PR::mTimeout(1))
      .expect(PR::state.reqs.get(1).status == "timeout" and PR::state.parkedOn == -1
              and PR::allInvariants and PR::refinesTasks and PR::inheritsTasksInvariants)

  run reachResumeFromRingTest =
    P::init.then(P::connect(1, false)).then(P::send(1)).then(P::deliver(1)).then(P::disconnect(1))
      .then(P::connect(1, true)).then(P::deliver(1))
      .expect(P::s.cl.get(1).got == [2] and P::s.cl.get(1).base == 1 and P::allInvariants)

  run reachSnapshotAfterOverflowTest =
    T::init.then(T::connect(1, false)).then(T::send(0)).then(T::naturalEnd).then(T::overflow(1))
      .then(T::connect(1, true))
      .expect(T::lastAction == "connectSnapshot" and T::s.cl.get(1).cursor == T::s.log.length()
              and T::allInvariants)
}
