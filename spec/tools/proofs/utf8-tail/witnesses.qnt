// Deterministic witnesses for the utf8-tail proof model.
module witnesses {
  import utf8Tail(FIXES = Set()) as C from "./model"
  import utf8Tail(FIXES = Set("653")) as F from "./model"

  // #653: [L C L C a] cut to its last 4 bytes starts on a continuation byte.
  run w653TailStartsMidCharTest =
    C::init.then(C::cutWith("e", "e", "a"))
      .expect(not(C::noSplitChar) and C::trimmed == ["C", "L", "C", "a"])

  // #653 with a 3-byte character: two orphaned continuation bytes.
  run w653TwoOrphansTest =
    C::init.then(C::cutWith("f", "a", "a"))
      .expect(not(C::noSplitChar) and C::trimmed == ["C", "C", "a", "a"])

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
