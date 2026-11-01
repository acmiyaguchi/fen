// Proof model, layer L1 of the holder design: ONE representative queued line
// against the lease (L0, ../lease). Every line behaves alike, so properties
// proved for an arbitrary line hold for all of them; the other lines are
// abstracted to what this line can observe:
//
//   steerAhead   another steer line is queued ahead of this one (FIFO)
//   otherSteer   any other steer line is queued
//   followAhead  another follow-up is queued ahead of this one
//
// Once a line is queued, nothing new can arrive ahead of it, so the "ahead"
// flags can only go from true to false while it waits.
//
// L2 (../holder) refines this per seq: for every seq q, each L2 step is an
// L1 step of q's view (`refinesLine` there).

module lineAbstract {
  import leaseAbstract.* from "../lease/model"

  pure val LINE_STATES = Set("unissued", "steer", "follow", "done")
  pure val LINE_WHYS = Set("", "taken", "started", "released", "refused", "cleared")
  pure val LINE_MODES = Set("one", "all")

  type View = {
    lease: Lease,
    st: str,            // this line's state
    why: str,           // its disposition once lineDone
    whyN: int,          // the turn number its disposition was attributed to
    forTurn: int,       // the turn a steer line was offered for (0 otherwise)
    wasSteer: bool,     // lineAdmitted as a steer line
    local: bool,        // offered without :turn
    steerAhead: bool,
    otherSteer: bool,
    followAhead: bool,
    steerMode: str,
    followMode: str,
  }

  pure def lineViewInit: View = {
    lease: leaseInit, st: "unissued", why: "", whyN: 0, forTurn: 0,
    wasSteer: false, local: false, steerAhead: false, otherSteer: false,
    followAhead: false, steerMode: "one", followMode: "one",
  }

  pure def lineFields(v: View): (str, str, int, int, bool, bool) =
    (v.st, v.why, v.whyN, v.forTurn, v.wasSteer, v.local)

  pure def lineDone(v: View, w: str, at: int): View = { ...v, st: "done", why: w, whyN: at }

  // Other lines and modes may change, but nothing new arrives ahead of a
  // queued line, and steer lines exist only while a turn holds.
  pure def lineEnvOk(a: View, b: View): bool = and {
    (a.st == "steer" and b.st == "steer") implies (b.steerAhead implies a.steerAhead),
    // another line may jump ahead only as the line whose idle offer raises
    // the start request (the typed prompt starts first)
    (a.st == "follow" and b.st == "follow" and not(b.lease.startReq and not(a.lease.startReq)))
      implies (b.followAhead implies a.followAhead),
    b.steerAhead implies b.otherSteer,
    b.otherSteer implies b.lease.kind == "turn",
    LINE_MODES.contains(b.steerMode), LINE_MODES.contains(b.followMode),
  }

  // This line is lineAdmitted by offer! (t = -1 local, 0 start-if-idle, > 0 turn t).
  pure def lineAdmitted(a: View, b: View): bool = and {
    a.st == "unissued",
    // an idle offer may also raise the start request in the same step
    b.lease == a.lease or (a.lease.kind == "none" and b.lease == leaseSetStartReq(a.lease, true)),
    or {
      // steer: the running turn, local or the turn the sender saw
      and { a.lease.kind == "turn", b.st == "steer", b.wasSteer, b.why == "",
            b.forTurn == a.lease.n, b.whyN == 0 },
      // follow-up
      and { b.st == "follow", not(b.wasSteer), b.forTurn == 0, b.why == "", b.whyN == 0 },
      // refused: only a non-local offer, attributed to the current number
      and { not(b.local), b.st == "done", b.why == "refused", b.whyN == a.lease.n,
            not(b.wasSteer), b.forTurn == 0 },
    },
  }

  pure def lineNext(a: View, b: View): bool = and {
    lineEnvOk(a, b),
    or {
      // env: only the lease and the other lines move
      and { lineFields(b) == lineFields(a), leaseNext(a.lease, b.lease),
            // this line's own queue pins what the lease may do
            a.st == "steer" implies (b.lease.kind == "turn" and b.lease.n == a.lease.n),
            // a turn start must consume the head follow-up (no phantom start)
            (a.st == "follow" and not(a.followAhead)) implies b.lease.n == a.lease.n },
      lineAdmitted(a, b),
      // take! :steer: the running turn takes this line (head unless :all)
      and { a.st == "steer", a.lease.kind == "turn", a.lease.body,
            a.steerMode == "all" or not(a.steerAhead),
            b.lease == a.lease,
            lineFields(b) == lineFields(lineDone(a, "taken", a.lease.n)) },
      // take! :follow-up: only once no steer line is queued (steering wins)
      and { a.st == "follow", a.lease.kind == "turn", a.lease.body, not(a.otherSteer),
            a.followMode == "all" or not(a.followAhead),
            b.lease == a.lease,
            lineFields(b) == lineFields(lineDone(a, "taken", a.lease.n)) },
      // next-start!: this head follow-up opens turn n+1
      and { a.st == "follow", not(a.followAhead), a.lease.kind == "none", a.lease.startReq,
            b.lease == leaseStartTurn(a.lease),
            lineFields(b) == lineFields(lineDone(a, "started", a.lease.n + 1)) },
      // leaseRelease: this unread steer line is returned to its own turn
      and { a.st == "steer", a.lease.body, b.lease == leaseRelease(a.lease),
            lineFields(b) == lineFields(lineDone(a, "released", a.lease.n)) },
      // clear!
      // clear!: the lease does not move, except the start request may drop
      and { a.st == "steer" or a.st == "follow",
            b.lease == a.lease or b.lease == leaseSetStartReq(a.lease, false),
            lineFields(b) == lineFields(lineDone(a, "cleared", a.lease.n)) },
    },
  }

  // ---- properties of one line ----

  // A queued steer line belongs to the running turn it was offered for.
  pure def steerBelongs(v: View): bool =
    v.st == "steer" implies (v.lease.kind == "turn" and v.forTurn == v.lease.n)

  // A steer line that left was taken or returned by its own turn.
  pure def steerAttributed(v: View): bool =
    (v.wasSteer and (v.why == "taken" or v.why == "released")) implies v.whyN == v.forTurn

  // A local offer is never refused.
  pure def localNotRefused(v: View): bool =
    v.why == "refused" implies not(v.local)

  pure def doneHasWhy(v: View): bool = (v.st == "done") == (v.why != "")
}

module lineSpec {
  import leaseAbstract.* from "../lease/model"
  import lineAbstract.* from "./model"

  pure val MAX_N = 3
  pure val NS = 0.to(MAX_N)
  pure val MAX_H = 4
  pure val HS = 0.to(MAX_H)

  // The view, split into variables so Apalache can bound each one.
  var kind: str
  var n: int
  var body: bool
  var cancel: bool
  var hid: int
  var startReq: bool
  var st: str
  var why: str
  var whyN: int
  var forTurn: int
  var wasSteer: bool
  var local: bool
  var steerAhead: bool
  var otherSteer: bool
  var followAhead: bool
  var steerMode: str
  var followMode: str
  var stepOk: bool

  def v: View = {
    lease: { kind: kind, n: n, hid: hid, body: body, cancel: cancel, startReq: startReq },
    st: st, why: why, whyN: whyN, forTurn: forTurn, wasSteer: wasSteer, local: local,
    steerAhead: steerAhead, otherSteer: otherSteer, followAhead: followAhead,
    steerMode: steerMode, followMode: followMode,
  }

  action putView(b: View): bool = all {
    kind' = b.lease.kind, n' = b.lease.n, body' = b.lease.body,
    cancel' = b.lease.cancel, hid' = b.lease.hid, startReq' = b.lease.startReq,
    st' = b.st, why' = b.why, whyN' = b.whyN, forTurn' = b.forTurn,
    wasSteer' = b.wasSteer, local' = b.local, steerAhead' = b.steerAhead,
    otherSteer' = b.otherSteer, followAhead' = b.followAhead,
    steerMode' = b.steerMode, followMode' = b.followMode,
    stepOk' = (stepOk and lineNext(v, b)),
  }

  action init = all {
    kind' = "none", n' = 0, hid' = 0, body' = false, cancel' = false, startReq' = false,
    st' = "unissued", why' = "", whyN' = 0, forTurn' = 0, wasSteer' = false,
    local' = false, steerAhead' = false, otherSteer' = false, followAhead' = false,
    steerMode' = "one", followMode' = "one", stepOk' = true,
  }

  // Others and modes move nondeterministically within lineEnvOk.
  pure def withEnv(b: View, sa: bool, os: bool, fa: bool, sm: str, fm: str): View =
    { ...b, steerAhead: sa and os and b.lease.kind == "turn",
            otherSteer: os and b.lease.kind == "turn",
            followAhead: fa, steerMode: sm, followMode: fm }

  pure def keepAhead(a: View, b: View): View =
    { ...b,
      steerAhead: if (a.st == "steer" and b.st == "steer") (b.steerAhead and a.steerAhead) else b.steerAhead,
      followAhead: if (a.st == "follow" and b.st == "follow") (b.followAhead and a.followAhead) else b.followAhead }

  action move(b: View, sa: bool, os: bool, fa: bool, sm: str, fm: str): bool =
    putView(keepAhead(v, withEnv(b, sa, os, fa, sm, fm)))

  // env: lease steps (never taking this line's queue away from its turn)
  action doLease(lb: Lease, sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    leaseNext(v.lease, lb),
    st == "steer" implies (lb.kind == "turn" and lb.n == n),
    (st == "follow" and not(followAhead)) implies lb.n == n,
    lb.n <= MAX_N, lb.hid <= MAX_H,
    move({ ...v, lease: lb }, sa, os, fa, sm, fm),
  }

  action doAdmit(t: int, sa: bool, os: bool, fa: bool, sm: str, fm: str): bool =
    val isLocal = t == -1
    val steerOk = kind == "turn" and (isLocal or t == n)
    val refuse = (t > 0 and not(steerOk)) or (t == 0 and kind != "none")
    all {
      st == "unissued",
      if (refuse)
        move({ ...v, st: "done", why: "refused", whyN: n, local: isLocal }, sa, os, fa, sm, fm)
      else if (steerOk and t != 0)
        move({ ...v, st: "steer", wasSteer: true, forTurn: if (isLocal) n else t, local: isLocal }, sa, os, fa, sm, fm)
      else
        move({ ...v, st: "follow", local: isLocal }, sa, os, fa, sm, fm),
    }

  action doTakeSteer(sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    st == "steer", kind == "turn", body, steerMode == "all" or not(steerAhead),
    move(lineDone(v, "taken", n), sa, os, fa, sm, fm),
  }

  action doTakeFollow(sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    st == "follow", kind == "turn", body, not(otherSteer),
    followMode == "all" or not(followAhead),
    move(lineDone(v, "taken", n), sa, os, fa, sm, fm),
  }

  action doStart(sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    st == "follow", not(followAhead), kind == "none", startReq, n < MAX_N, hid < MAX_H,
    move({ ...lineDone(v, "started", n + 1), lease: leaseStartTurn(v.lease) }, sa, os, fa, sm, fm),
  }

  action doRelease(sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    st == "steer", body,
    move({ ...lineDone(v, "released", n), lease: leaseRelease(v.lease) }, sa, os, fa, sm, fm),
  }

  action doClear(sa: bool, os: bool, fa: bool, sm: str, fm: str): bool = all {
    st == "steer" or st == "follow",
    move(lineDone(v, "cleared", n), sa, os, fa, sm, fm),
  }

  action step = {
    nondet t = Set(-1, 0).union(1.to(MAX_N)).oneOf()
    nondet sa = Bool.oneOf()
    nondet os = Bool.oneOf()
    nondet fa = Bool.oneOf()
    nondet sm = LINE_MODES.oneOf()
    nondet fm = LINE_MODES.oneOf()
    nondet m = HS.oneOf()
    nondet r = Bool.oneOf()
    nondet k = Set("turn", "exclusive", "release", "cancel", "req").oneOf()
    val lb =
      if (k == "turn") leaseStartTurn(v.lease)
      else if (k == "exclusive") leaseStartExclusive(v.lease)
      else if (k == "release") leaseRelease(v.lease)
      else if (k == "cancel") leaseCancel(v.lease, m)
      else leaseSetStartReq(v.lease, r)
    any {
      doLease(lb, sa, os, fa, sm, fm),
      doAdmit(t, sa, os, fa, sm, fm),
      doTakeSteer(sa, os, fa, sm, fm),
      doTakeFollow(sa, os, fa, sm, fm),
      doStart(sa, os, fa, sm, fm),
      doRelease(sa, os, fa, sm, fm),
      doClear(sa, os, fa, sm, fm),
    }
  }

  // Every step the contract allows, not just the ones `step` generates: L2
  // checks `lineNext`, so the invariants are proved over `lineNext` itself.
  action stepRel = {
    nondet k = LEASE_KINDS.oneOf()
    nondet nn = NS.oneOf()
    nondet hh = HS.oneOf()
    nondet bd = Bool.oneOf()
    nondet cn = Bool.oneOf()
    nondet rq = Bool.oneOf()
    nondet s2 = LINE_STATES.oneOf()
    nondet w = LINE_WHYS.oneOf()
    nondet wn = NS.oneOf()
    nondet ft = NS.oneOf()
    nondet ws = Bool.oneOf()
    nondet lc = Bool.oneOf()
    nondet sa = Bool.oneOf()
    nondet os = Bool.oneOf()
    nondet fa = Bool.oneOf()
    nondet sm = LINE_MODES.oneOf()
    nondet fm = LINE_MODES.oneOf()
    val b = {
      lease: { kind: k, n: nn, hid: hh, body: bd, cancel: cn, startReq: rq },
      st: s2, why: w, whyN: wn, forTurn: ft, wasSteer: ws, local: lc,
      steerAhead: sa, otherSteer: os, followAhead: fa, steerMode: sm, followMode: fm,
    }
    all { lineNext(v, b), putView(b) }
  }

  // ---- Properties ----

  val movesAreAbsSteps = stepOk
  val leaseInvHolds = leaseInv(v.lease)
  val steerBelongsInv = steerBelongs(v)
  val steerAttributedInv = steerAttributed(v)
  val localNotRefusedInv = localNotRefused(v)
  val doneHasWhyInv = doneHasWhy(v)

  val allInvariants = and {
    movesAreAbsSteps,
    leaseInvHolds,
    steerBelongsInv,
    steerAttributedInv,
    localNotRefusedInv,
    doneHasWhyInv,
  }

  val inductiveInv = and {
    kind.in(LEASE_KINDS), n.in(NS), hid.in(HS), n <= hid, body.in(Bool), cancel.in(Bool), startReq.in(Bool),
    st.in(LINE_STATES), why.in(LINE_WHYS), whyN.in(NS), forTurn.in(NS),
    wasSteer.in(Bool), local.in(Bool), steerAhead.in(Bool), otherSteer.in(Bool),
    followAhead.in(Bool), steerMode.in(LINE_MODES), followMode.in(LINE_MODES), stepOk.in(Bool),
    steerAhead implies otherSteer,
    otherSteer implies kind == "turn",
    st == "steer" implies wasSteer,
    st == "unissued" implies (why == "" and whyN == 0 and forTurn == 0 and not(wasSteer) and not(local)),
    st == "done" implies why != "",
    st != "done" implies why == "",
    st == "follow" implies not(wasSteer),
    wasSteer implies forTurn >= 1,
    whyN <= n, forTurn <= n,
    allInvariants,
  }
}
