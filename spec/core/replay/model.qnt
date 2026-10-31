// Replay laws for the close-turn core (#668), as one-step checks: the log is
// chosen in init, among every list of up to MAX_LEN entries drawn from
// ENTRIES, and the laws are checked on it. No history is built step by step.
//
// Input assumptions: call ids come from {0, 1}; an assistant entry carries
// 0-2 calls, possibly the same id twice; a result names any id. That covers
// orphan results, duplicate results, out-of-order results, reused ids, and
// logs cut while calls are open.
module replayLaws {
  import turn.* from "../turn/turn"

  pure val MAX_LEN = 5
  pure val ENTRIES: Set[Entry] = Set(
    eUser,
    eAsst([]), eAsst([0]), eAsst([1]), eAsst([0, 1]), eAsst([1, 0]), eAsst([0, 0]),
    eResult(0), eResult(1),
  )

  var h: List[Entry]

  action init = {
    nondet len = 0.to(MAX_LEN).oneOf()
    nondet e0 = ENTRIES.oneOf()
    nondet e1 = ENTRIES.oneOf()
    nondet e2 = ENTRIES.oneOf()
    nondet e3 = ENTRIES.oneOf()
    nondet e4 = ENTRIES.oneOf()
    h' = [e0, e1, e2, e3, e4].slice(0, len)
  }

  // For witnesses: start from a given log.
  action load(l: List[Entry]): bool = h' = l

  action step = h' = h

  // ---- laws over any log ----
  val replayValid = turnValid(replayEntries(h))
  val replayKeepsValid = turnValid(h) implies replayEntries(h) == h
  // Follows from the two above (replay's output is valid, and replay leaves
  // valid logs alone), so verify.tsv proves those and this stays a sampled
  // check: replaying a replay is what makes Apalache time out.
  val replayIdempotent = replayEntries(replayEntries(h)) == replayEntries(h)
  val doctorCleanIffValid = (replayRepairs(h) == 0) == turnValid(h)

  // ---- laws over what an agent can leave behind ----
  val closeTurnValid = prefixValid(h) implies turnValid(closeTurn(h))
  val closeTurnIdempotent = prefixValid(h) implies closeTurn(closeTurn(h)) == closeTurn(h)
  // A log cut at any point replays to what close-turn gives in memory: one
  // rule for --continue and for an unwinding step.
  val replayEqualsClose = prefixValid(h) implies replayEntries(h) == closeTurn(h)

  val allInvariants = and {
    replayValid, replayKeepsValid, replayIdempotent, doctorCleanIffValid,
    closeTurnValid, closeTurnIdempotent, replayEqualsClose,
  }
}
