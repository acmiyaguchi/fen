// Core primitive: close-turn (#668).
//
// One rule for tool-call pairing, shared by everything that hands history to a
// provider: the agent loop when a step unwinds (in memory), and session replay
// when a log is loaded (on disk). Today the rule is re-implemented at about six
// exits in agent.fnl, privately in each OpenAI converter, and differently in
// `session doctor`; the Anthropic converter does not repair at all.
//
// The rule: every assistant's tool calls are answered right after it, in call
// order, exactly once, before anything else; no result without a pending call.
//
// Pure definitions only (no state), so domain models can import them:
//   import turn.* from "../core/turn/turn"
// A domain projects its own message type to `Entry` and either checks the rule
// (`turnValid`), asks which calls a step left open (`openCalls`), or rebuilds
// its own list from a replay plan (`replayPlan`).
module turn {
  // role: "user" (user text, steering, summaries) | "asst" | "result"
  // Error and empty :aborted assistants are not entries: build-context drops
  // them before any provider sees the history.
  type Entry = { role: str, calls: List[int], cid: int }

  pure val NOCALLS: List[int] = []
  pure val eUser: Entry = { role: "user", calls: NOCALLS, cid: -1 }
  pure def eAsst(cs: List[int]): Entry = { role: "asst", calls: cs, cid: -1 }
  pure def eResult(c: int): Entry = { role: "result", calls: NOCALLS, cid: c }

  // The provider rule.
  pure def turnValid(h: List[Entry]): bool =
    val r = h.foldl({ pending: NOCALLS, ok: true }, (acc, e) =>
      if (e.role == "result")
        if (acc.pending.length() > 0 and acc.pending[0] == e.cid)
          { pending: acc.pending.tail(), ok: acc.ok }
        else { pending: acc.pending, ok: false }
      else
        { pending: if (e.role == "asst") e.calls else NOCALLS,
          ok: acc.ok and acc.pending.length() == 0 })
    r.ok and r.pending.length() == 0

  // Calls still waiting for a result, in order, if the history stopped here.
  // Keyed by what was actually appended, not by where the code unwound.
  pure def openCalls(h: List[Entry]): List[int] =
    h.foldl(NOCALLS, (pending, e) =>
      if (e.role == "result")
        if (pending.length() > 0 and pending[0] == e.cid) pending.tail() else pending
      else if (e.role == "asst") e.calls
      else NOCALLS)

  // close-turn: whatever way a step ends (done, cancelled, crashed, truncated),
  // pair every open call with a synthetic result before the history is used.
  pure def closeTurn(h: List[Entry]): List[Entry] =
    openCalls(h).foldl(h, (acc, c) => acc.append(eResult(c)))

  // Replay plan for a log that may have been cut anywhere, or interleaved by
  // another writer: keep entries in order, insert a synthetic result for every
  // call that is not answered next, and drop results that answer nothing.
  // A step is `{ src: i }` (keep entry i) or `{ src: -1, call: c }` (synthetic).
  type Step = { src: int, call: int }
  pure val NOSTEPS: List[Step] = []

  pure def closeAll(out: List[Step], pending: List[int]): List[Step] =
    pending.foldl(out, (acc, c) => acc.append({ src: -1, call: c }))

  pure def replayPlan(h: List[Entry]): List[Step] =
    // foldl with an index counter, not range(0, n): Apalache needs constant
    // range bounds.
    val r = h.foldl({ out: NOSTEPS, pending: NOCALLS, i: 0 }, (st, e) =>
      if (e.role == "result")
        if (st.pending.length() > 0 and st.pending[0] == e.cid)
          { out: st.out.append({ src: st.i, call: e.cid }), pending: st.pending.tail(), i: st.i + 1 }
        else { ...st, i: st.i + 1 }               // orphan, duplicate, or out of order
      else
        { out: closeAll(st.out, st.pending).append({ src: st.i, call: -1 }),
          pending: if (e.role == "asst") e.calls else NOCALLS, i: st.i + 1 })
    closeAll(r.out, r.pending)

  pure val NOENTRIES: List[Entry] = []

  pure def replayEntries(h: List[Entry]): List[Entry] =
    replayPlan(h).foldl(NOENTRIES, (acc, s) => acc.append(if (s.src >= 0) h[s.src] else eResult(s.call)))

  // What `session doctor` should report: how far the log is from its replay.
  pure def replayRepairs(h: List[Entry]): int =
    val p = replayPlan(h)
    val synth = p.select(s => s.src < 0).length()
    synth + (h.length() - (p.length() - synth))

  // The one terminal outcome a step reports (#609, #610): read, never inferred
  // from the last message. A crash is an error.
  pure def outcomeOf(result: str): str =
    if (result == "crash") "error" else result
}
