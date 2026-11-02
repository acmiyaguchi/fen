// Proof model: cancel fencing for the holders outside the session lease.
//
// The session lease (../lease) fences turn cancel on a fresh holder id per
// acquire. Side chat turns and blocking subagent runs are holders of their
// own: each owner (a side chat entry, a headless session state, the turn that
// owns a blocking subagent run) has its own id space, and a cancel carries
// (owner, id) captured at keypress or command time and may land later (a
// stale closure, a /subagents command typed after the turn ended).
//
// Two owners stand for any number: the claim is per owner and the owners
// share nothing but the address format.
//
//   acquire      fen.util.cancel_fence `acquire!` (fresh id, unarmed)
//   bodyStart    the body begins running (where the old flags were reset)
//   release      `release!` at body exit
//   cancel(o,h)  `cancel! t h` with h captured earlier (any id up to the
//                current one: a cancel cannot name a run not yet started)
//
// Invariant: a cancel addressed to an earlier holder never arms a later one
// (`cancelFencedInv`), and a cancel addressed to the current holder is never
// lost while it holds (`cancelNotLostInv`).
//
// The unfenced flag-with-reset designs fen used before are mutants of this
// file (mutants.tsv), each caught by one of the two invariants.

module fence {
  pure val OWNERS = Set(0, 1)
  pure val MAX_H = 3
  pure val HS = 0.to(MAX_H)

  // per owner
  var hid: int -> int        // id of the current (or last) holder
  var held: int -> bool      // a holder is running
  var started: int -> bool   // its body has started
  var armed: int -> bool     // cancel-requested? hid would answer true

  // ---- ghosts ----
  var armedBy: int -> int    // the id the arming cancel carried
  var armedFrom: int -> int  // the owner the arming cancel was addressed to
  var delivered: int -> bool // a cancel addressed to the current holder landed while it held

  action init = all {
    hid' = OWNERS.mapBy(o => 0),
    held' = OWNERS.mapBy(o => false),
    started' = OWNERS.mapBy(o => false),
    armed' = OWNERS.mapBy(o => false),
    armedBy' = OWNERS.mapBy(o => 0),
    armedFrom' = OWNERS.mapBy(o => o),
    delivered' = OWNERS.mapBy(o => false),
  }

  // acquire!: a fresh id, unarmed. The reset is safe only because the id is
  // fresh: no cancel can carry it yet.
  pure def acqArmed(a: bool): bool = false
  action doAcquire(o: int): bool = all {
    not(held.get(o)), hid.get(o) < MAX_H,
    hid' = hid.set(o, hid.get(o) + 1),
    held' = held.set(o, true),
    started' = started.set(o, false),
    armed' = armed.set(o, acqArmed(armed.get(o))),
    armedBy' = armedBy, armedFrom' = armedFrom,
    delivered' = delivered.set(o, false),
  }

  // The body starts. Fenced: nothing to reset.
  pure def startArmed(a: bool): bool = a
  action doBodyStart(o: int): bool = all {
    held.get(o), not(started.get(o)),
    hid' = hid, held' = held,
    started' = started.set(o, true),
    armed' = armed.set(o, startArmed(armed.get(o))),
    armedBy' = armedBy, armedFrom' = armedFrom, delivered' = delivered,
  }

  action doRelease(o: int): bool = all {
    held.get(o),
    hid' = hid,
    held' = held.set(o, false),
    started' = started.set(o, false),
    armed' = armed.set(o, false),
    armedBy' = armedBy, armedFrom' = armedFrom,
    delivered' = delivered.set(o, false),
  }

  // cancel! (o, h): arms owner p iff the address matches it.
  pure def hits(p: int, o: int, h: int, hidP: int, heldP: bool): bool = heldP and p == o and h == hidP

  action doCancel(o: int, h: int): bool = all {
    h <= hid.get(o),
    val arm = OWNERS.mapBy(p => hits(p, o, h, hid.get(p), held.get(p)))
    all {
      hid' = hid, held' = held, started' = started,
      armed' = OWNERS.mapBy(p => armed.get(p) or arm.get(p)),
      armedBy' = OWNERS.mapBy(p => if (arm.get(p) and not(armed.get(p))) h else armedBy.get(p)),
      armedFrom' = OWNERS.mapBy(p => if (arm.get(p) and not(armed.get(p))) o else armedFrom.get(p)),
      delivered' = OWNERS.mapBy(p => delivered.get(p) or (p == o and held.get(p) and h == hid.get(p))),
    },
  }

  action step = {
    nondet o = OWNERS.oneOf()
    nondet h = HS.oneOf()
    any { doAcquire(o), doBodyStart(o), doRelease(o), doCancel(o, h) }
  }

  // ---- Properties ----

  // A cancel never arms a holder other than the one it was addressed to.
  val cancelFencedInv = OWNERS.forall(o => armed.get(o) implies (armedFrom.get(o) == o and armedBy.get(o) == hid.get(o)))
  // A cancel addressed to the current holder stays armed until it releases.
  val cancelNotLostInv = OWNERS.forall(o => (held.get(o) and delivered.get(o)) implies armed.get(o))
  val armedHeldInv = OWNERS.forall(o => armed.get(o) implies held.get(o))

  val allInvariants = and { cancelFencedInv, cancelNotLostInv, armedHeldInv }

  val inductiveInv = and {
    hid.in(OWNERS.setOfMaps(HS)),
    held.in(OWNERS.setOfMaps(Bool)),
    started.in(OWNERS.setOfMaps(Bool)),
    armed.in(OWNERS.setOfMaps(Bool)),
    armedBy.in(OWNERS.setOfMaps(HS)),
    armedFrom.in(OWNERS.setOfMaps(OWNERS)),
    delivered.in(OWNERS.setOfMaps(Bool)),
    OWNERS.forall(o => and {
      started.get(o) implies held.get(o),
      delivered.get(o) implies held.get(o),
    }),
    allInvariants,
  }
}
