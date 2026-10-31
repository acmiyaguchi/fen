// Deterministic witnesses for the utf8-tail proof model.
module witnesses {
  import utf8Tail(FIXES = Set("653")) as C from "./model"
  import utf8Tail(FIXES = Set("653")) as F from "./model"



  run reachSkipOneTest =
    F::init.then(F::cutWith("e", "e", "a"))
      .expect(F::trimmed == ["L", "C", "a"] and F::noSplitChar and F::dropsLessThanAChar)

  run reachSkipTwoTest =
    F::init.then(F::cutWith("f", "a", "a"))
      .expect(F::trimmed == ["a", "a"] and F::noSplitChar and F::dropsLessThanAChar)

  run reachCutOnBoundaryTest =
    F::init.then(F::cutWith("e", "e", "e"))
      .expect(F::trimmed == ["L", "C", "L", "C"] and F::noSplitChar)

  run reachUntrimmedTest =
    F::init.then(F::cutWith("f", "none", "none"))
      .expect(F::trimmed == ["L", "C", "C"] and F::noSplitChar)
}
