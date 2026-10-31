// Proof model: extension contributions and their rollback (#624, #626).
//
// Contract: the registry is a pure function of (load order, the serving
// owners); a reload swaps one owner's contributions atomically, keeps the
// previous ones when it fails, and a /reload pass visits every owner.
//
// Only the state the contract needs, all finite: two owners in discovery
// order A, B (A owns /reload, as the sessions extension does), each owner's
// status and source, and the registry as four scalars: the winner of the
// shared command `dup`, the owners of `reload` and `bcmd`, and the order of
// the array buckets (tools, hooks, bus subscriptions and prompt fragments
// all move together, so one order stands for all of them).
//
// Integration model: ../../model.qnt (fingerprints, turns, bus, validation).
module contrib {
  const FIXES: Set[str]

  // bucket order: "" | "A" | "B" | "AB" | "BA"
  type Reg = { dup: str, reload: str, bcmd: str, order: str }

  pure def dropOwner(order: str, o: str): str =
    if (order == "AB" or order == "BA") (if (o == "A") "B" else "A")
    else if (order == o) "" else order

  pure def pushOwner(order: str, o: str): str =
    val d = dropOwner(order, o)
    if (d == "") o else if (d == "A") "AB" else "BA"

  // register: singleton kinds are last-writer-wins, arrays append.
  pure def registerOwner(r: Reg, o: str): Reg =
    if (o == "A") { ...r, dup: "A", reload: "A", order: pushOwner(r.order, "A") }
    else { ...r, dup: "B", bcmd: "B", order: pushOwner(r.order, "B") }

  // unregister-by-owner removes only records tagged with the owner.
  pure def unregisterOwner(r: Reg, o: str): Reg =
    { dup: if (r.dup == o) "" else r.dup,
      reload: if (r.reload == o) "" else r.reload,
      bcmd: if (r.bcmd == o) "" else r.bcmd,
      order: dropOwner(r.order, o) }

  pure val EMPTY: Reg = { dup: "", reload: "", bcmd: "", order: "" }

  pure def serves(st: str): bool = st == "loaded" or st == "stale"

  // What a fresh start of the serving owners gives.
  pure def view(a: bool, b: bool): Reg =
    val ra = if (a) registerOwner(EMPTY, "A") else EMPTY
    if (b) registerOwner(ra, "B") else ra

  // status: "loaded" | "stale" | "error" | "none" | "disabled"
  type O = { st: str, src: str }
  type P = { a: O, b: O, r: Reg, aborted: bool, visA: bool, visB: bool }

  pure def own(p: P, o: str): O = if (o == "A") p.a else p.b
  pure def withOwn(p: P, o: str, x: O): P = if (o == "A") { ...p, a: x } else { ...p, b: x }
  pure def viewOf(p: P): Reg = view(serves(p.a.st), serves(p.b.st))

  // One owner through load-module-spec! with :reload? true.
  pure def reloadStep(p: P, o: str): P =
    if (p.aborted) p
    else
      val x = own(p, o)
      val p1 = if (o == "A") { ...p, visA: true } else { ...p, visB: true }
      val derive = FIXES.contains("626")
      if (x.src == "ok")
        val p2 = withOwn(p1, o, { ...x, st: "loaded" })
        { ...p2, r: if (derive) viewOf(p2) else registerOwner(unregisterOwner(p.r, o), o) }
      else if (FIXES.contains("624"))
        // staged reload under pcall: keep the previous contributions
        val p2 = withOwn(p1, o, { ...x, st: if (serves(x.st)) "stale" else "error" })
        { ...p2, r: if (derive) viewOf(p2) else p.r }
      else if (x.src == "badRegister")
        val p2 = withOwn(p1, o, { ...x, st: "error" })
        { ...p2, r: if (derive) viewOf(p2) else unregisterOwner(p.r, o) }
      else
        // badModule: unregister-by-owner ran first, the record went with it,
        // and the raise escapes the pass.
        val p2 = withOwn(p1, o, { ...x, st: "none" })
        { ...p2, r: if (derive) viewOf(p2) else unregisterOwner(p.r, o), aborted: true }

  // Scalar state variables (Apalache's induction step binds each one by a
  // finite domain); `a`, `b`, `reg` and `p` are the record views.
  var stA: str
  var srcA: str
  var stB: str
  var srcB: str
  var rDup: str
  var rReload: str
  var rBcmd: str
  var rOrder: str
  var pass: str         // /reload in progress: the next owner, or ""
  var visA: bool        // ghost: the current or last /reload pass attempted A
  var visB: bool
  var passDone: bool    // ghost: the last action ended a /reload pass

  val a: O = { st: stA, src: srcA }
  val b: O = { st: stB, src: srcB }
  val reg: Reg = { dup: rDup, reload: rReload, bcmd: rBcmd, order: rOrder }
  val p: P = { a: a, b: b, r: reg, aborted: false, visA: false, visB: false }

  // Owners and registry from a step result; the pass bookkeeping is set by
  // each action.
  action setOwners(q: P): bool = all {
    stA' = q.a.st, srcA' = q.a.src, stB' = q.b.st, srcB' = q.b.src,
    rDup' = q.r.dup, rReload' = q.r.reload, rBcmd' = q.r.bcmd, rOrder' = q.r.order,
  }
  action keepPass = all { pass' = pass, visA' = visA, visB' = visB, passDone' = false }

  action init = all {
    stA' = "loaded", srcA' = "ok", stB' = "loaded", srcB' = "ok",
    rDup' = "B", rReload' = "A", rBcmd' = "B", rOrder' = "AB",
    pass' = "", visA' = false, visB' = false, passDone' = false,
  }

  action edit(o: str, v: str): bool = all {
    pass == "", own(p, o).src != v,
    setOwners(withOwn(p, o, { ...own(p, o), src: v })), keepPass,
  }

  // /reload: dispatched by name, so it needs the command. load! then reloads
  // the owners in discovery order, one `passStep` each (no other action
  // interleaves: /reload runs at idle and completes before the next key).
  action reloadAll = all {
    pass == "", reg.reload != "",
    pass' = "A", visA' = false, visB' = false, passDone' = false,
    setOwners(p),
  }

  action passStep = all {
    pass != "",
    val q = reloadStep(p, pass)
    val nextOwner = if (q.aborted or pass == "B") "" else "B"
    all {
      setOwners(q),
      pass' = nextOwner, passDone' = (nextOwner == ""),
      visA' = (visA or pass == "A"), visB' = (visB or pass == "B"),
    },
  }

  // /reload-extension <o>
  action reloadOne(o: str): bool = all {
    pass == "", own(p, o).st != "disabled", setOwners(reloadStep(p, o)), keepPass,
  }

  // /extensions disable B (A owns the recovery commands; disabling it is refused)
  action disableB = all {
    pass == "", serves(b.st),
    val q = { ...p, b: { ...b, st: "disabled" } }
    setOwners({ ...q, r: if (FIXES.contains("626")) viewOf(q) else unregisterOwner(reg, "B") }),
    keepPass,
  }

  action step = any {
    nondet o = Set("A", "B").oneOf()
    nondet v = Set("ok", "badModule", "badRegister").oneOf()
    edit(o, v),
    reloadAll, passStep,
    nondet o = Set("A", "B").oneOf()
    reloadOne(o),
    disableB,
  }

  // ---- properties ----

  // The registry is what a fresh start of the serving owners gives.
  val registryMatchesFreshStart = reg == viewOf(p)

  // A /reload pass attempts every extension.
  val reloadVisitsEveryOwner = passDone implies (visA and visB)

  // A loaded extension keeps a status record.
  val attemptedOwnerListed = a.st != "none" and b.st != "none"

  // The recovery command survives any reload.
  val reloadCommandAvailable = reg.reload != ""

  pure val STATUSES = Set("loaded", "stale", "error", "none", "disabled")
  pure val SRCS = Set("ok", "badModule", "badRegister")
  pure val OWNERS_OR_NONE = Set("", "A", "B")

  // The initial registry is a fresh start of both owners.
  val initIsFreshStart = view(true, true) == { dup: "B", reload: "A", bcmd: "B", order: "AB" }

  // Inductive strengthening: the domains, A always serving (it can only go
  // stale), a pass at B has visited A, and the four properties.
  val contribInductive = and {
    stA.in(STATUSES), srcA.in(SRCS), stB.in(STATUSES), srcB.in(SRCS),
    rDup.in(OWNERS_OR_NONE), rReload.in(OWNERS_OR_NONE), rBcmd.in(OWNERS_OR_NONE),
    rOrder.in(Set("", "A", "B", "AB", "BA")),
    pass.in(Set("", "A", "B")), visA.in(Bool), visB.in(Bool), passDone.in(Bool),
    serves(a.st), b.st != "none",
    pass == "B" implies visA, pass == "A" implies not(passDone),
    registryMatchesFreshStart, reloadVisitsEveryOwner, attemptedOwnerListed,
    reloadCommandAvailable,
  }
}

module current { import contrib(FIXES = Set("624", "626")).* }
module fixed { import contrib(FIXES = Set("624", "626")).* }
module fix624 { import contrib(FIXES = Set("624")).* }
module fix626 { import contrib(FIXES = Set("626")).* }
