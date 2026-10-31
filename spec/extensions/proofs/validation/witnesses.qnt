// Deterministic witnesses for the registration-validation check.
module witnesses {
  import validation(FIXES = Set()) as C from "./model"
  import validation(FIXES = Set("628")) as F from "./model"

  run w628ToolWithoutExecuteAcceptedTest =
    C::init.expect(not(C::registeredCallablesPresent) and C::accepts("tool", false)
                   and not(C::accepts("command", false)))

  run reachToolWithExecuteAcceptedTest =
    F::init.expect(F::accepts("tool", true) and not(F::accepts("tool", false))
                   and F::registeredCallablesPresent and F::wellFormedAccepted)
}
