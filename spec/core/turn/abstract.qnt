// Abstract specification of close-turn (#668): the contract a turn owner must
// refine, with no transcript in it.
//
// A turn is open from user input until close. Inside it the model replies
// (possibly with tool calls), and each call is answered in order. A reply is
// only requested when the model is owed one ("awaiting": user text or the last
// result is the newest thing in context, and no call is open). Close ends the
// turn whatever the cause: it pairs every call still open and reports exactly
// one outcome, which must be consistent with how the turn ended.
//
// Pure definitions only, so concrete models can import them and check, at
// every step, that their mapped state moves by one abstract step or stutters
// (see absNext and the monitors in spec/agent-loop/model.qnt).
module turnAbstract {
  type Abs = {
    open: List[int],       // tool calls not yet answered, in order
    turnOpen: bool,        // between user input and close
    awaiting: bool,        // the model is owed a reply
    outcome: str,          // "none" while open; "ok" | "error" | "cancelled" after close
    errSignalled: bool,    // an :error event was emitted in this turn
    replies: bool,         // parity of the model's replies: flips on each reply,
                           // so a reply nobody owed is a visible step, not a stutter
  }

  pure val NONE: List[int] = []
  pure val OUTCOMES: Set[str] = Set("ok", "error", "cancelled")

  pure val absInit: Abs =
    { open: NONE, turnOpen: false, awaiting: false, outcome: "none", errSignalled: false,
      replies: false }

  // b.open is a proper suffix of a.open: the first k >= 1 open calls were
  // answered, in order (a parallel batch answers several in one step).
  pure def answeredPrefix(a: List[int], b: List[int]): bool =
    b.length() < a.length()
      and b == a.slice(a.length() - b.length(), a.length())

  // User input: a new turn, or steering injected inside an open turn. Never
  // while a call is open.
  pure def userInput(a: Abs, b: Abs): bool = and {
    a.open == NONE, b.open == NONE,
    b.turnOpen, b.awaiting, b.outcome == "none",
    b.errSignalled == (a.turnOpen and a.errSignalled),
    b.replies == a.replies,
  }

  // The model replies, with any calls, only when it is owed a reply.
  pure def reply(a: Abs, b: Abs): bool = and {
    a.turnOpen, a.awaiting, a.open == NONE,
    b.turnOpen, not(b.awaiting), b.outcome == "none",
    b.errSignalled == a.errSignalled,
    b.replies != a.replies,
  }

  // One or more open calls are answered, in order. The model is owed a reply
  // once the last one is answered.
  pure def answer(a: Abs, b: Abs): bool = and {
    a.turnOpen, answeredPrefix(a.open, b.open),
    b.turnOpen, b.awaiting == (b.open == NONE), b.outcome == "none",
    b.errSignalled == a.errSignalled,
    b.replies == a.replies,
  }

  // An :error event inside the open turn.
  pure def signalError(a: Abs, b: Abs): bool =
    a.turnOpen and b == { ...a, errSignalled: true }

  // Close: pairs every open call and reports one outcome.
  // - ok only when the model's reply is the newest thing in context (the
  //   model was not owed a reply and no call was open);
  // - error only with an :error event;
  // - after close nothing is open, and the model is owed a reply exactly
  //   when it was before or when close paired calls.
  pure def close(a: Abs, b: Abs): bool = and {
    a.turnOpen, not(b.turnOpen), b.open == NONE,
    OUTCOMES.contains(b.outcome),
    b.outcome == "ok" implies (a.open == NONE and not(a.awaiting)),
    b.outcome == "error" implies b.errSignalled,
    b.errSignalled == (a.errSignalled or b.outcome == "error"),
    b.awaiting == (a.awaiting or a.open != NONE),
    b.replies == a.replies,
  }

  pure def absNext(a: Abs, b: Abs): bool =
    or { a == b, userInput(a, b), reply(a, b), answer(a, b), signalError(a, b), close(a, b) }

  // ---- properties every refining owner inherits ----

  // A closed turn has nothing open.
  pure def closedPaired(a: Abs): bool = not(a.turnOpen) implies a.open == NONE
  // An outcome exists exactly when the turn is closed (after the first turn).
  pure def outcomeWhenClosed(a: Abs): bool =
    (a.outcome == "none") == (a.turnOpen or a == absInit)
  // An error outcome was announced.
  pure def errorAnnounced(a: Abs): bool = a.outcome == "error" implies a.errSignalled
  // The model is never owed a reply while a call is open.
  pure def notAwaitingWithOpen(a: Abs): bool = a.awaiting implies a.open == NONE

  pure def absInv(a: Abs): bool = and {
    closedPaired(a), outcomeWhenClosed(a), errorAnnounced(a), notAwaitingWithOpen(a),
  }
}
