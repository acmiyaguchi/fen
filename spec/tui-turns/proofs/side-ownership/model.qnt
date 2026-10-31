// Proof model: a btw turn belongs to the tab generation that started it (#663).
//
// Contract: the open btw tab is never blocked by, and never shows events
// from, a turn it did not start; closing the tab cancels its turn.
//
// Only the state the contract needs: the open tab's generation, the live
// entry volatile.live[:btw] (present, generation, cancel requested), one
// turn being reaped (with its generation), and a ghost monitor that turns
// true when an event is delivered into a tab of another generation. No
// transcript rows: delivery is checked as it happens.
//
// Input assumption: at most one closed turn is being reaped at a time (a
// second slow close while one is reaped is modelled as the fast path).
//
// Integration model: ../../model.qnt.
module sideOwnership {
  const FIXES: Set[str]
  pure val MAX_GENS = 3

  var sideOpen: bool
  var sideGen: int      // generation of the btw tab (bumped by each /btw open)
  var sideBusy: bool    // the tab shows its turn running
  var livePresent: bool // volatile.live[:btw]
  var liveGen: int      // generation that started the live turn
  var liveCancel: bool
  var reaping: bool     // fixed: a closed turn on the reap list
  var reapGen: int
  var badDelivery: bool // ghost: an event reached a tab of another generation

  action init = all {
    sideOpen' = false, sideGen' = 0, sideBusy' = false, livePresent' = false,
    liveGen' = 0, liveCancel' = false, reaping' = false, reapGen' = 0, badDelivery' = false,
  }

  // side-chat on-event!: today routed by WORKSPACE-ID (whatever tab is :btw);
  // fixed: routed by the generation captured at the turn's start.
  pure def delivers(open: bool, tabGen: int, turnGen: int): bool =
    open and (not(FIXES.contains("663")) or turnGen == tabGen)

  action openSide = all {
    not(sideOpen), sideGen < MAX_GENS,
    sideOpen' = true, sideGen' = sideGen + 1, sideBusy' = false,
    livePresent' = livePresent, liveGen' = liveGen, liveCancel' = liveCancel,
    reaping' = reaping, reapGen' = reapGen, badDelivery' = badDelivery,
  }

  // Enter on the btw tab: entry-for! adopts any live entry under :btw, so a
  // present entry means "side agent is busy".
  action submitSide = all {
    sideOpen, not(sideBusy), not(livePresent),
    sideBusy' = true, livePresent' = true, liveGen' = sideGen, liveCancel' = false,
    sideOpen' = sideOpen, sideGen' = sideGen, reaping' = reaping, reapGen' = reapGen,
    badDelivery' = badDelivery,
  }

  // Ctrl-W: cancel! gets 8 resumes; a turn that needs more is parked.
  action closeSide(fast: bool): bool = all {
    sideOpen,
    val slow = livePresent and not(fast) and not(reaping)
    all {
      sideOpen' = false, sideBusy' = false, sideGen' = sideGen,
      if (slow and FIXES.contains("663"))
        all { livePresent' = false, liveGen' = liveGen, liveCancel' = false,
              reaping' = true, reapGen' = liveGen }
      else if (slow)
        // parked in place: still volatile.live[:btw], marked discard
        all { livePresent' = true, liveGen' = liveGen, liveCancel' = true,
              reaping' = reaping, reapGen' = reapGen }
      else
        all { livePresent' = false, liveGen' = liveGen, liveCancel' = false,
              reaping' = reaping, reapGen' = reapGen },
      badDelivery' = badDelivery,
    },
  }

  // The live turn emits an event, or finishes (its final reply is an event).
  action liveEvent(finish: bool): bool = all {
    livePresent,
    badDelivery' = (badDelivery or (delivers(sideOpen, sideGen, liveGen) and liveGen != sideGen)),
    livePresent' = not(finish), liveCancel' = (liveCancel and not(finish)),
    sideBusy' = (if (finish and liveGen == sideGen) false else sideBusy),
    sideOpen' = sideOpen, sideGen' = sideGen, liveGen' = liveGen,
    reaping' = reaping, reapGen' = reapGen,
  }

  // A reaped turn emits (its unwinding reply) or is reaped.
  action reapEvent(finish: bool): bool = all {
    reaping,
    badDelivery' = (badDelivery or (delivers(sideOpen, sideGen, reapGen) and reapGen != sideGen)),
    reaping' = not(finish),
    sideOpen' = sideOpen, sideGen' = sideGen, sideBusy' = sideBusy, livePresent' = livePresent,
    liveGen' = liveGen, liveCancel' = liveCancel, reapGen' = reapGen,
  }

  // /reload: a new side_chat OWNER marks an old-owner live turn for cancel.
  action reload = all {
    liveCancel' = (liveCancel or livePresent),
    sideOpen' = sideOpen, sideGen' = sideGen, sideBusy' = sideBusy, livePresent' = livePresent,
    liveGen' = liveGen, reaping' = reaping, reapGen' = reapGen, badDelivery' = badDelivery,
  }

  action step = any {
    openSide, submitSide,
    nondet f = Bool.oneOf()
    closeSide(f),
    nondet f = Bool.oneOf()
    liveEvent(f),
    nondet f = Bool.oneOf()
    reapEvent(f),
    reload,
  }

  // ---- properties ----

  // The open btw tab is never blocked by a turn it did not start.
  val sideEntryOwned = (sideOpen and livePresent) implies liveGen == sideGen

  // A tab only ever shows events of turns it started (monitor).
  val eventsInOwnTab = not(badDelivery)

  // Closing the tab cancels its turn: nothing un-cancelled outlives it.
  val closedSideCancelled = (livePresent and liveGen != sideGen) implies liveCancel
  val closedSideIdle = not(sideOpen) implies not(sideBusy)

  // Inductive strengthening: a live turn belongs to the open tab, a reaped
  // turn to an earlier or the just-closed generation.
  val ownershipInductive = and {
    sideOpen.in(Bool), sideGen.in(Int), sideBusy.in(Bool), livePresent.in(Bool),
    liveGen.in(Int), liveCancel.in(Bool), reaping.in(Bool), reapGen.in(Int),
    badDelivery.in(Bool),
    livePresent implies (sideOpen and liveGen == sideGen),
    reaping implies (reapGen < sideGen or (reapGen == sideGen and not(sideOpen))),
    sideEntryOwned, eventsInOwnTab, closedSideCancelled, closedSideIdle,
  }
}

module current { import sideOwnership(FIXES = Set("663")).* }
module fixed { import sideOwnership(FIXES = Set("663")).* }
