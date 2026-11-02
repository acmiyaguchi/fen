// Proof model: /reload's phases are atomic under cancel and failure.
//
// Invariant: a cancel (or failure) at any point during /reload leaves the
// process on entirely old or entirely new code -- never a mix of swapped and
// unswapped modules, registrations, or registry buckets -- unless the mix is
// recorded for the next reload to retry (`dirty`); and the session holder is
// released on every exit.
//
// Code (extensions/behaviors/actions/sessions/commands/session.fnl):
//   reload-body      yield! raises RELOAD-CANCEL at a CANCEL-POINTS phase
//                    when tasks.cancel-requested?; every other yield (inside
//                    the core and extension passes) never cancels.
//   perform-reload!  pc 1 PRE      yield :reload-start          (fixed order)
//                    pc 2 REC      runtime-recovery.recover!    (clears buckets)
//                    pc 3 START    yield :reload-start          (old order)
//                    pc 4 CORE1    reload-core!: compiler batch, then the
//                    pc 5 CORE2      modules in place, one by one
//                    pc 6 AFTERCORE yield :after-core
//                    pc 7 EXT      load-extensions (per-owner contrib txn)
//                    pc 8 AFTEREXT yield :after-extensions
//                    pc 9 REBUILD  tui, providers, backend, agent rebuild
//                    pc 10 DONE    summary
//   fen.core.tasks   with-holder releases on every body exit (proved in
//                    ../tasks/proofs/holder); here only the release itself.
// What this model abstracts, and where it is proved instead:
//   * per-owner registration atomicity (contrib.begin!/rollback!):
//     ../contrib; here one owner whose module and registrations move together.
//   * failed-module retry (prior-failures, uncommitted fingerprints):
//     ../../extensions (#625); here the `dirty` flag.
//
// FIXES:
//   "early"  the cancel point precedes recovery (cancel after recover! left
//            the registry buckets cleared with nothing re-registered)
//   "atomic" cancel is honored only before the first swap; once a swap has
//            begun the reload runs to its end (cancel at :after-core or
//            :after-extensions left new core with old extensions/agent)
module reload {
  const FIXES: Set[str]

  pure val IDLE = 0
  pure val PRE = 1
  pure val REC = 2
  pure val START = 3
  pure val CORE1 = 4
  pure val CORE2 = 5
  pure val AFTERCORE = 6
  pure val EXT = 7
  pure val AFTEREXT = 8
  pure val REBUILD = 9
  pure val DONE = 10

  var pc: int
  var holder: bool          // tasks holder held by the reload job
  var recover: bool         // /reload --recover registries
  var cancelReq: bool       // tasks.cancel-requested? hid
  var c1: int               // core module 1: 0 old, 1 new
  var c2: int               // core module 2
  var ext: int              // extension owner's modules
  var regv: int             // extension owner's registrations
  var registries: str       // "live" | "cleared" (recover! cleared buckets)
  var dirty: bool           // a failure was recorded for retry
  var outcome: str          // "" | "ok" | "failed" | "cancelled" | "raised"

  action init = all {
    pc' = IDLE, holder' = false, recover' = false, cancelReq' = false,
    c1' = 0, c2' = 0, ext' = 0, regv' = 0, registries' = "live",
    dirty' = false, outcome' = "",
  }

  pure def cancelPoint(p: int, fixes: Set[str]): bool =
    (if (fixes.contains("early")) p == PRE else p == START)
      or (not(fixes.contains("atomic")) and (p == AFTERCORE or p == AFTEREXT))

  // reload-body exit: RELOAD-CANCEL, an error, or a return; with-holder
  // releases the holder on each.
  action finish(o: str): bool = all {
    pc' = IDLE,
    holder' = false,
    outcome' = o,
    recover' = recover, cancelReq' = false,
  }

  // /reload (or a reload request's job) takes the exclusive holder. The
  // versions are relative to this reload: 0 is whatever ran before it.
  action request(rec: bool): bool = all {
    pc == IDLE,
    pc' = PRE, holder' = true, recover' = rec, cancelReq' = false,
    c1' = 0, c2' = 0, ext' = 0, regv' = 0, registries' = "live",
    dirty' = false, outcome' = "",
  }

  // Ctrl-C (tasks.cancel-current!) may arrive at any point of the job.
  action cancel: bool = all {
    holder, not(cancelReq),
    cancelReq' = true,
    pc' = pc, holder' = holder, recover' = recover, c1' = c1, c2' = c2,
    ext' = ext, regv' = regv, registries' = registries, dirty' = dirty,
    outcome' = outcome,
  }

  action keepVersions: bool = all {
    c1' = c1, c2' = c2, ext' = ext, regv' = regv, registries' = registries,
    dirty' = dirty,
  }

  action goto(p: int): bool = all {
    pc' = p, holder' = holder, recover' = recover, cancelReq' = cancelReq,
    outcome' = outcome,
  }

  // One phase step. err: "none" | "exec" (a module raises while executing:
  // it is restored, the failure recorded) | "compile" (the compiler batch
  // fails: no module runs) | "raise" (an uncaught error leaves the body).
  action advance(err: str): bool = all {
    pc != IDLE,
    if (cancelPoint(pc, FIXES) and cancelReq) all { finish("cancelled"), keepVersions }
    else if (pc == PRE) all { goto(REC), keepVersions }
    else if (pc == REC) all {
      goto(START),
      registries' = if (recover) "cleared" else registries,
      c1' = c1, c2' = c2, ext' = ext, regv' = regv, dirty' = dirty,
    }
    else if (pc == START) all { goto(CORE1), keepVersions }
    else if (pc == CORE1)
      if (err == "compile") all {
        goto(AFTERCORE),
        dirty' = true,
        c1' = c1, c2' = c2, ext' = ext, regv' = regv, registries' = registries,
      }
      else all {
        goto(CORE2),
        c1' = if (err == "exec") c1 else 1,
        dirty' = if (err == "exec") true else dirty,
        c2' = c2, ext' = ext, regv' = regv, registries' = registries,
      }
    else if (pc == CORE2) all {
      goto(AFTERCORE),
      c2' = if (err == "exec") c2 else 1,
      dirty' = if (err == "exec") true else dirty,
      c1' = c1, ext' = ext, regv' = regv, registries' = registries,
    }
    else if (pc == AFTERCORE) all { goto(EXT), keepVersions }
    else if (pc == EXT)
      if (err == "exec") all {
        // contrib.rollback! restores the owner's previous registrations and
        // the failing module; the owner is :stale and retried next reload.
        goto(AFTEREXT),
        ext' = 0,
        regv' = 0, dirty' = true,
        c1' = c1, c2' = c2, registries' = registries,
      }
      else all {
        goto(AFTEREXT),
        ext' = 1, regv' = 1, registries' = "live",
        c1' = c1, c2' = c2, dirty' = dirty,
      }
    else if (pc == AFTEREXT) all { goto(REBUILD), keepVersions }
    else if (pc == REBUILD)
      if (err == "raise") all { finish("raised"), keepVersions }
      else all { goto(DONE), keepVersions }
    else all { finish(if (dirty) "failed" else "ok"), keepVersions },
  }

  action step = any {
    nondet rec = Set(true, false).oneOf()
    request(rec),
    cancel,
    nondet err = Set("none", "exec", "compile", "raise").oneOf()
    advance(err),
  }

  // ---- properties ----

  val allOld = c1 == 0 and c2 == 0 and ext == 0 and regv == 0
  val allNew = c1 == 1 and c2 == 1 and ext == 1 and regv == 1
  val mixed = not(allOld) and not(allNew)

  // A cancelled reload ran no swap and cleared no bucket.
  val cancelLeavesOld =
    (pc == IDLE and outcome == "cancelled") implies (allOld and registries == "live" and not(dirty))

  // A clean reload swapped everything.
  val okAllNew = (pc == IDLE and outcome == "ok") implies allNew

  // An ended reload that left a mix recorded it for retry.
  val mixTracked = (pc == IDLE and mixed) implies dirty

  // recover! cleared buckets are re-registered unless a failure is recorded.
  val registriesNotLost = (pc == IDLE and registries == "cleared") implies dirty

  // An owner's registrations always match its modules (contrib transaction).
  val regMatchesModule = regv == ext

  // The holder is held exactly while the job runs.
  val holderReleased = holder == (pc != IDLE)

  val reloadAtomic = and {
    cancelLeavesOld, okAllNew, mixTracked, registriesNotLost,
    regMatchesModule, holderReleased,
  }

  // Inductive strengthening for the fixed design: what each pc implies.
  val reloadInductive = and {
    pc.in(0.to(10)), holder.in(Bool), recover.in(Bool), cancelReq.in(Bool),
    c1.in(0.to(1)), c2.in(0.to(1)), ext.in(0.to(1)), regv.in(0.to(1)),
    registries.in(Set("live", "cleared")), dirty.in(Bool),
    outcome.in(Set("", "ok", "failed", "cancelled", "raised")),
    reloadAtomic,
    pc != IDLE implies outcome == "",
    not(recover) implies registries == "live",
    (pc >= PRE and pc <= CORE1) implies (allOld and not(dirty)),
    (pc >= PRE and pc <= REC) implies registries == "live",
    (pc >= START and pc <= EXT and recover) implies registries == "cleared",
    pc >= AFTEREXT implies (registries == "live" or dirty),
    pc == CORE2 implies (c2 == 0 and ext == 0 and dirty == (c1 == 0)),
    (pc == AFTERCORE or pc == EXT) implies (ext == 0 and (dirty or (c1 == 1 and c2 == 1))),
    pc >= AFTEREXT implies (dirty or allNew),
    pc == IDLE implies (
      (outcome == "" implies (allOld and not(dirty) and registries == "live"))
      and (outcome == "failed" implies dirty)
      and (outcome == "raised" implies (dirty or allNew))
      and (outcome == "ok" implies not(dirty))
    ),
  }
}

module before { import reload(FIXES = Set()).* }
module fixed { import reload(FIXES = Set("early", "atomic")).* }
module current { import reload(FIXES = Set("early", "atomic")).* }
