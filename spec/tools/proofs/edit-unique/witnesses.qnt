// Deterministic witnesses for the edit-unique proof model.
module witnesses {
  import editUnique(FIXES = Set("658")) as C from "./model"
  import editUnique(FIXES = Set("658")) as F from "./model"



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
