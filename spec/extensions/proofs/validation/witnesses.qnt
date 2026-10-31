// Deterministic witnesses for the registration-validation check.
module witnesses {
  import validation(FIXES = Set()) as C from "./model"
  import validation(FIXES = Set("628")) as F from "./model"

  run reachToolWithExecuteAcceptedTest =
    F::init.expect(F::accepts("tool", true) and not(F::accepts("tool", false))
                   and F::registeredCallablesPresent and F::wellFormedAccepted)
}
