// Reachability for the replay laws: the logs the laws are about do occur.
module witnesses {
  import replayLaws as R from "./model"
  import turn.* from "../turn/turn"

  // An orphan result is dropped.
  run reachOrphanDroppedTest =
    R::load([eUser, eResult(0)])
      .expect(replayEntries(R::h) == [eUser] and R::allInvariants)

  // A log cut with two calls open is closed in call order.
  run reachCutWithOpenCallsTest =
    R::load([eUser, eAsst([0, 1])])
      .expect(replayEntries(R::h) == [eUser, eAsst([0, 1]), eResult(0), eResult(1)]
              and R::allInvariants)

  // An out-of-order result: the call is closed and the stray result dropped.
  run reachOutOfOrderTest =
    R::load([eUser, eAsst([0, 1]), eResult(1), eResult(0)])
      .expect(not(turnValid(R::h)) and replayRepairs(R::h) > 0 and R::allInvariants)

  // A second writer's turn between a call and its result (#642).
  run reachInterleavedWriterTest =
    R::load([eUser, eAsst([0]), eUser, eAsst([]), eResult(0)])
      .expect(replayEntries(R::h) == [eUser, eAsst([0]), eResult(0), eUser, eAsst([])]
              and R::allInvariants)
}
