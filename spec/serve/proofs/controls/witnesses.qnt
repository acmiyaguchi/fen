// Deterministic witnesses (quint test) for the targeted-controls proof model.
// w397...Test: the #397 design as written lets a lagging client's control hit
// a turn it never saw. reach...Test: the proposed protocol still accepts
// controls aimed at the running turn, and rejects stale ones.
module witnesses {
  import controls(TARGETED = false) as I from "./model"
  import controls(TARGETED = true) as P from "./model"

  // #397: client 1 saw turn 1; the local user starts turn 2 before the
  // remote learns turn 1 ended; the remote's cancel kills turn 2.
  run w397CancelHitsSeenTurnTest =
    I::init.then(I::send(0)).then(I::observe(1)).then(I::naturalEnd)
      .then(I::send(0)).then(I::cancel(1))
      .expect(not(I::cancelHitsSeenTurn) and I::lastAction == "cancel"
              and I::turnNo == 2 and I::seen.get(1) == 1)

  // #397: client 1 still sees idle and sends a prompt; it is queued as
  // steering and injected into turn 1, which the local user started.
  run w397SteeringIntoOtherTurnTest =
    I::init.then(I::send(0)).then(I::send(1)).then(I::inject)
      .expect(not(I::steeringReachesSeenTurn) and I::lastAction == "inject"
              and I::seen.get(1) == 0 and I::turnNo == 1)

  // #397: a steer for an ended turn starts a fresh turn (busy? is false).
  run w397StaleSteerStartsTurnTest =
    I::init.then(I::send(0)).then(I::observe(1)).then(I::naturalEnd).then(I::send(1))
      .expect(not(I::steeringReachesSeenTurn) and I::lastAction == "sendStaleStartsTurn")

  // ---- reachability of the proposed protocol ----

  run reachCancelSeenTurnTest =
    P::init.then(P::send(0)).then(P::observe(0)).then(P::cancel(0))
      .expect(P::lastAction == "cancel" and not(P::running) and P::inductiveInv)

  run reachStaleCancelRejectedTest =
    P::init.then(P::send(0)).then(P::observe(1)).then(P::naturalEnd)
      .then(P::send(0)).then(P::cancel(1))
      .expect(P::lastAction == "cancelNoop" and P::running and P::turnNo == 2 and P::inductiveInv)

  run reachSteerInjectedTest =
    P::init.then(P::send(0)).then(P::observe(1)).then(P::send(1)).then(P::inject)
      .expect(P::lastAction == "inject" and P::queue == Set() and P::inductiveInv)

  run reachStalePromptRejectedTest =
    P::init.then(P::send(0)).then(P::send(1))
      .expect(P::lastAction == "sendRejectedNotCurrent" and P::queue == Set() and P::inductiveInv)

  run reachLinesHandedBackTest =
    P::init.then(P::send(0)).then(P::observe(1)).then(P::send(1)).then(P::naturalEnd)
      .expect(P::queue == Set() and not(P::running) and P::inductiveInv)
}
