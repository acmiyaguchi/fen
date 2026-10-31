// Deterministic witnesses for the edit-unique proof model.
module witnesses {
  import editUnique(FIXES = Set()) as C from "./model"
  import editUnique(FIXES = Set("658")) as F from "./model"

  // #658: "aaabbb" has two overlapping "aa"; find-all reports one, so the
  // edit is applied instead of rejected as not unique.
  run w658OverlapCountedOnceTest =
    C::init.then(C::runWith(["a", "a", "a", "b", "b", "b"], ["a", "a"]))
      .expect(not(C::uniqueMatchIsUnique) and C::found == 1 and C::actual == 2)

  // #658 with a longer pattern, the `}\n}` shape: "ababab" with "aba"
  // (matches at 0 and 2).
  run w658OverlapLongerPatternTest =
    C::init.then(C::runWith(["a", "b", "a", "b", "a", "b"], ["a", "b", "a"]))
      .expect(not(C::uniqueMatchIsUnique) and C::found == 1 and C::actual == 2)

  run reachOverlapRejectedTest =
    F::init.then(F::runWith(["a", "a", "a", "b", "b", "b"], ["a", "a"]))
      .expect(F::found == 2 and F::countIsExact)

  run reachUniqueAcceptedTest =
    F::init.then(F::runWith(["a", "b", "a", "b", "b", "b"], ["a", "b", "a"]))
      .expect(F::found == 1 and F::uniqueMatchIsUnique)

  run reachOverlapLongerPatternTest =
    F::init.then(F::runWith(["a", "b", "a", "b", "a", "b"], ["a", "b", "a"]))
      .expect(F::found == 2 and F::countIsExact)
}
