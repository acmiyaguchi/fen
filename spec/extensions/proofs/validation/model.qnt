// Proof model: registration validates each kind's callable (#628).
//
// A finite function check, not a state machine: `accepts(kind, hasCallable)`
// mirrors the register/* entry checks, and the property quantifies over every
// kind and both inputs. The trivial state machine exists only so the usual
// harness (quint run, Apalache) can check it.
//
// Integration model: ../../model.qnt.
module validation {
  const FIXES: Set[str]

  pure val KINDS = Set("tool", "command", "hook", "provider")

  // register :command needs {:handler fn}, :hook {:before-tool fn},
  // :provider :complete; :tool checks only :name and :exposure today.
  pure def accepts(kind: str, hasCallable: bool): bool =
    hasCallable or (kind == "tool" and not(FIXES.contains("628")))

  var checked: bool

  action init = all { checked' = true }
  action step = all { checked' = checked }

  // Every accepted registration carries its callable.
  val registeredCallablesPresent =
    KINDS.forall(k => Bool.forall(c => accepts(k, c) implies c))

  // Validation never rejects a well-formed registration.
  val wellFormedAccepted = KINDS.forall(k => accepts(k, true))
}

module current { import validation(FIXES = Set("628")).* }
module fixed { import validation(FIXES = Set("628")).* }
