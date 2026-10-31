// Properties of the close-turn primitive (#668) on its own, before any domain
// uses it. Two histories evolve side by side:
//
//   agentH  built only by moves the agent loop makes (user text, an assistant
//           with 0-2 calls, the next pending result), and cut at any point by
//           an unwind (cancel, crash, :length truncation, process kill), which
//           applies closeTurn.
//   logH    any sequence at all: what a session log can hold after crashes,
//           torn writes, or a second writer interleaving its turns.
//
// The invariants say: closing a turn at any point gives a provider-valid
// history; loading a log cut at that point gives the same history; and replay
// turns any log into a valid one, leaves valid logs alone, and reports zero
// repairs exactly when the log is already valid (what `session doctor` needs).
module turnModel {
  import turn.* from "./turn"

  pure val MAX_LEN = 7
  pure val MAX_CALLS = 2

  var agentH: List[Entry]
  var logH: List[Entry]
  var nextCall: int

  action init = all { agentH' = [], logH' = [], nextCall' = 0 }

  // n consecutive call ids (n <= MAX_CALLS), spelled out for Apalache.
  pure def callsFrom(start: int, n: int): List[int] =
    if (n == 0) NOCALLS else if (n == 1) [start] else [start, start + 1]

  // ---- agent moves ----
  action agentUser = all {
    agentH.length() < MAX_LEN, openCalls(agentH) == NOCALLS,
    agentH' = agentH.append(eUser), logH' = logH, nextCall' = nextCall,
  }

  action agentAsst(n: int): bool = all {
    agentH.length() < MAX_LEN, openCalls(agentH) == NOCALLS,
    agentH' = agentH.append(eAsst(callsFrom(nextCall, n))),
    nextCall' = nextCall + n, logH' = logH,
  }

  action agentResult = all {
    agentH.length() < MAX_LEN, openCalls(agentH) != NOCALLS,
    agentH' = agentH.append(eResult(openCalls(agentH)[0])),
    logH' = logH, nextCall' = nextCall,
  }

  action agentUnwind = all {
    openCalls(agentH) != NOCALLS,
    agentH' = closeTurn(agentH), logH' = logH, nextCall' = nextCall,
  }

  // ---- arbitrary log ----
  action logAppend(kind: str, n: int, c: int): bool = all {
    logH.length() < MAX_LEN,
    logH' = logH.append(
      if (kind == "user") eUser
      else if (kind == "asst") eAsst(callsFrom(nextCall, n))
      else eResult(c)),
    nextCall' = if (kind == "asst") nextCall + n else nextCall,
    agentH' = agentH,
  }

  action step = any {
    agentUser,
    nondet n = 0.to(MAX_CALLS).oneOf()
    agentAsst(n),
    agentResult,
    agentUnwind,
    nondet kind = Set("user", "asst", "result").oneOf()
    nondet n2 = 0.to(MAX_CALLS).oneOf()
    nondet c = 0.to(3).oneOf()
    logAppend(kind, n2, c),
  }

  // ---- properties ----

  // Wherever a step stops, closing the turn yields a provider-valid history.
  val closeTurnValid = turnValid(closeTurn(agentH))

  // Closing twice is closing once.
  val closeTurnIdempotent = closeTurn(closeTurn(agentH)) == closeTurn(agentH)

  // A log cut at any point replays to exactly what close-turn gives in
  // memory: one rule for --continue and for an unwinding step.
  val replayEqualsClose = replayEntries(agentH) == closeTurn(agentH)

  // Replay makes any log provider-valid ...
  val replayValid = turnValid(replayEntries(logH))

  // ... leaves a valid log untouched ...
  val replayKeepsValid = turnValid(logH) implies replayEntries(logH) == logH

  // ... is idempotent ...
  val replayIdempotent = replayEntries(replayEntries(logH)) == replayEntries(logH)

  // ... and the doctor is clean exactly when the log needs no repair.
  val doctorCleanIffValid = (replayRepairs(logH) == 0) == turnValid(logH)

  val allInvariants = and {
    closeTurnValid, closeTurnIdempotent, replayEqualsClose,
    replayValid, replayKeepsValid, replayIdempotent, doctorCleanIffValid,
  }
}
