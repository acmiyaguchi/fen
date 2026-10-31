// Export the model's wire_session tables as data so scripts/spec/conform-wire.fnl
// can compare them, pair by pair, with packages/util/src/fen/util/wire_session.fnl.
module conform {
  import wire(FIXED = false) as W from "./model"

  pure val STATES = ["starting", "ready", "running", "closing", "finalizing",
                     "done", "cancelled", "failed", "timed-out"]
  pure val KINDS = ["prompt", "steer", "finalize", "close", "cancel"]
  pure val EVENTS = ["started", "turn-done", "final-turn-done", "deadline"]

  type DRow = { st: str, kind: str, status: str, act: str, next: str }
  type ARow = { st: str, ev: str, ok: bool, act: str, next: str }

  var decideRows: List[DRow]
  var advanceRows: List[ARow]

  pure val D: List[DRow] = STATES.foldl([], (acc, s) =>
    KINDS.foldl(acc, (a, k) =>
      val en = W::decide(s, k, false)
      a.append({ st: s, kind: k, status: en.status, act: en.act, next: en.next })))

  pure val A: List[ARow] = STATES.foldl([], (acc, s) =>
    EVENTS.foldl(acc, (a, e) =>
      val ad = W::advance(s, e)
      a.append({ st: s, ev: e, ok: ad.ok, act: ad.act, next: ad.next })))

  action init = all { W::init, decideRows' = D, advanceRows' = A }
  action step = all { W::step, decideRows' = decideRows, advanceRows' = advanceRows }
}
