// Deterministic witnesses for the output-envelope proof model.
module witnesses {
  import outputEnvelope(FIXES = Set()) as C from "./model"
  import outputEnvelope(FIXES = Set("652")) as F from "./model"

  // #652: two escaped bytes fill the cap; the trailer is cut.
  run w652ExitTagCutTest =
    C::init.then(C::emitWith("x", "x", "none"))
      .expect(not(C::exitStatusVisible) and C::kept == ["x", "x"])

  run reachTagKeptBodyCutTest =
    F::init.then(F::emitWith("x", "x", "none"))
      .expect(F::kept == ["x", "T"] and F::exitStatusVisible and F::withinLimit)

  run reachFitsWholeTest =
    F::init.then(F::emitWith("a", "x", "a"))
      .expect(F::kept == ["a", "x", "a", "T"] and F::fitsSentWhole)
}
