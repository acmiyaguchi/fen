// Deterministic witnesses for the output-envelope proof model.
module witnesses {
  import outputEnvelope(FIXES = Set("652")) as C from "./model"
  import outputEnvelope(FIXES = Set("652")) as F from "./model"


  run reachTagKeptBodyCutTest =
    F::init.then(F::emitWith("x", "x", "none"))
      .expect(F::kept == ["x", "T"] and F::exitStatusVisible and F::withinLimit)

  run reachFitsWholeTest =
    F::init.then(F::emitWith("a", "x", "a"))
      .expect(F::kept == ["a", "x", "a", "T"] and F::fitsSentWhole)
}
