// Deterministic witnesses (quint test) for the replay-cursor proof model.
// w396...Test: the #396 JSONL replay drops, repeats, or reorders events, or
// finishes caught up with a stale state. reach...Test: the proposed ring
// still delivers live, resumes, and resets with a snapshot.
module witnesses {
  import replay(REPLAY = "jsonlGap") as G from "./model"
  import replay(REPLAY = "jsonlDup") as D from "./model"
  import replay(REPLAY = "ring") as P from "./model"

  // #396 (replay, then live): the message appended during the yielding
  // replay is in neither the snapshot nor the live stream.
  run w396ReplayGapTest =
    G::init.then(G::connect(false)).then(G::emitState(1)).then(G::emitMsg)
      .then(G::finishReplay).then(G::emitState(2)).then(G::deliver)
      .expect(not(G::noSilentGap) and G::got == Set(3) and not(G::got.contains(2)))

  // #396: replay finishes caught up, but the JSONL carries no turn state.
  run w396CaughtUpMissesStateTest =
    G::init.then(G::connect(false)).then(G::emitState(1)).then(G::finishReplay)
      .expect(not(G::caughtUpSeesState) and G::cursor == G::len and G::view == 0)

  // #396 (live, then replay): the message appended during replay arrives
  // live, then again from the growing file, after an older one.
  run w396ReplayOutOfOrderTest =
    D::init.then(D::emitState(1)).then(D::emitMsg).then(D::connect(false)).then(D::replayStep)
      .then(D::emitMsg).then(D::deliver).then(D::replayStep)
      .expect(not(D::inOrderDelivery) and D::noDuplicateDelivery)

  run w396ReplayDuplicatesTest =
    D::init.then(D::emitState(1)).then(D::emitMsg).then(D::connect(false)).then(D::replayStep)
      .then(D::emitMsg).then(D::deliver).then(D::replayStep).then(D::replayStep)
      .expect(not(D::noDuplicateDelivery) and D::got == Set(2, 3))

  // ---- reachability of the proposed protocol ----

  run reachLiveDeliveryTest =
    P::init.then(P::connect(false)).then(P::emitState(1)).then(P::emitMsg)
      .then(P::deliver).then(P::deliver)
      .expect(P::cursor == P::len and P::view == 1 and P::got == Set(1, 2) and P::inductiveInv)

  run reachSnapshotMidTurnTest =
    P::init.then(P::emitState(1)).then(P::emitMsg).then(P::connect(false))
      .expect(P::lastAction == "connectSnapshot" and P::view == 1 and P::got == Set(2)
              and P::inductiveInv)

  run reachResumeFromRingTest =
    P::init.then(P::connect(false)).then(P::emitMsg).then(P::deliver).then(P::disconnect)
      .then(P::emitMsg).then(P::connect(true)).then(P::deliver)
      .expect(P::got == Set(2) and P::base == 1 and P::cursor == P::len and P::inductiveInv)

  run reachSnapshotAfterOverflowTest =
    P::init.then(P::connect(false)).then(P::emitState(1)).then(P::emitMsg).then(P::emitMsg)
      .then(P::overflow).then(P::connect(true))
      .expect(P::lastAction == "connectSnapshot" and P::cursor == P::len and P::view == P::cur
              and P::inductiveInv)
}
