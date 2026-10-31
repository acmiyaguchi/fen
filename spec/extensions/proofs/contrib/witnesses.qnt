// Deterministic witnesses for the contribution proof model.
module witnesses {
  import contrib(FIXES = Set()) as C from "./model"
  import contrib(FIXES = Set("624", "626")) as F from "./model"

  // ---- reachability of the fixed design ----

  run reachFailedReloadRollsBackTest =
    F::init.then(F::edit("A", "badModule")).then(F::reloadAll).then(F::passStep).then(F::passStep)
      .expect(F::a.st == "stale" and F::visB and F::reg.reload == "A" and F::contribInductive)

  run reachRepairTest =
    F::init.then(F::edit("B", "badRegister")).then(F::reloadOne("B"))
      .then(F::edit("B", "ok")).then(F::reloadAll).then(F::passStep).then(F::passStep)
      .expect(F::b.st == "loaded" and F::reg.dup == "B" and F::contribInductive)

  run reachDisableExposesClaimTest =
    F::init.then(F::disableB).then(F::reloadOne("A"))
      .expect(F::reg.dup == "A" and F::reg.order == "A" and F::contribInductive)
}
