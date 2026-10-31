// Proof model: tools.execute dispatch and tool policy (no open bugs).
//
// The `disp` machine of ../../model.qnt on its own.  One call (in the initial state) picks a CLI
// policy (--tools / --denied-tools / --no-tools / none), a path (a direct
// call, the side chat, a subagent child with or without a configured tool
// list), a tool name (or an unknown one), a before-tool hook outcome, and
// whether the arguments validate; dispatch then runs policy -> hook ->
// validate -> execute.
//
// Code: packages/fen/src/fen/tool_policy.fnl (policy, narrow),
// packages/core/src/fen/core/tools.fnl (execute, check-before-tool),
// packages/core/src/fen/core/extensions/register/hook.fnl (run-before-tool),
// extensions/adapters/presenters/tui/side_chat.fnl (safe-side-opts),
// extensions/behaviors/companions/subagent/init.fnl (child-tool-policy).
module dispatch {
  pure val TOOLS = Set("read", "grep", "bash", "edit", "subagent")
  pure val READ_ONLY = Set("read", "grep")
  pure val KINDS = Set("none", "allow", "deny", "notools")
  pure val PATHS = Set("direct", "sidechat", "subagent")
  pure val HOOKS = Set("allow", "block", "throw")

  var ran: bool
  var kind: str
  var path: str
  var name: str
  var hook: str
  var argsValid: bool
  var parentAllowed: Set[str]
  var executed: bool

  // fen.tool_policy.policy -> agent.tools (the executable registry).
  pure def registry(k: str, names: Set[str]): Set[str] =
    if (k == "none") TOOLS
    else if (k == "notools") Set()
    else if (k == "allow") TOOLS.intersect(names)
    else TOOLS.exclude(names)

  // fen.tool_policy.narrow (side chat's read-only set).
  pure def narrow(cands: Set[str], k: str, names: Set[str]): Set[str] =
    if (k == "notools") Set()
    else if (k == "allow") cands.intersect(names)
    else if (k == "deny") cands.exclude(names)
    else cands

  // subagent child-tool-policy -> the child's registry.
  pure def childRegistry(k: str, names: Set[str], cfgSet: bool,
                         cfg: Set[str]): Set[str] =
    if (k == "none") (if (cfgSet) cfg else TOOLS)
    else if (k == "notools") Set()
    else if (k == "allow") (if (cfgSet) cfg.intersect(names) else names.intersect(TOOLS))
    else (if (cfgSet) cfg.exclude(names) else TOOLS.exclude(names))

  // One dispatch, chosen in the initial state; the property is then checked
  // over all choices at once.
  action callWith(k: str, names: Set[str], p: str, n: str, h: str, v: bool,
                  cfgSet: bool, cfg: Set[str]): bool = all {
    // The CLI rejects --tools/--denied-tools naming nothing.
    (k == "allow" or k == "deny") implies names != Set(),
    val parent = registry(k, names)
    val reach =
      if (p == "direct") parent
      else if (p == "sidechat") narrow(READ_ONLY, k, names)
      else childRegistry(k, names, cfgSet, cfg)
    all {
      ran' = true, kind' = k, path' = p, name' = n, hook' = h, argsValid' = v,
      parentAllowed' = parent,
      executed' = (reach.contains(n) and h == "allow" and v),
    },
  }

  action init = {
    nondet k = KINDS.oneOf()
    nondet names = TOOLS.powerset().oneOf()
    nondet p = PATHS.oneOf()
    nondet n = TOOLS.union(Set("unknown")).oneOf()
    nondet h = HOOKS.oneOf()
    nondet v = Set(true, false).oneOf()
    nondet cfgSet = Set(true, false).oneOf()
    nondet cfg = TOOLS.powerset().oneOf()
    callWith(k, names, p, n, h, v, cfgSet, cfg)
  }

  action stutter = all {
    ran,
    ran' = ran, kind' = kind, path' = path, name' = name, hook' = hook,
    argsValid' = argsValid, parentAllowed' = parentAllowed, executed' = executed,
  }

  action step = stutter

  // Tools outside the parent's policy are unreachable on every path.
  val deniedUnreachable = executed implies parentAllowed.contains(name)

  // A blocking or failing before-tool hook always prevents execution.
  val hookVetoFinal = (ran and hook != "allow") implies not(executed)

  // Nothing runs on arguments that failed schema validation.
  val validatedBeforeEffect = executed implies argsValid

  // The side chat only ever runs read-only tools.
  val sideChatReadOnly = (executed and path == "sidechat") implies READ_ONLY.contains(name)
}

module current { import dispatch.* }
