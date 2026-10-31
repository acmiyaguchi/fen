// Reachability: the logs the sessions replay laws are about do occur, and
// the abortedAfterPairing assumption is needed (a log breaking it makes
// replay and the provider view disagree).
module witnesses {
  import sessionsReplay as R from "./model"
  import sessions(FIXES = Set("639", "643"), OTHER_WRITER = false) as S from "../../model"

  // A crash left a call unanswered (#639): replay closes it.
  run reachCrashedCallClosedTest =
    R::load([{ mid: 1, role: "user", call: -1 }, { mid: 3, role: "call", call: 0 }])
      .expect(not(S::contextValid(R::ms)) and R::sessionsReplayValid)

  // A second writer's turn between a call and its result (#642/#643): the
  // doctor reports it and --repair output is valid.
  run reachInterleavedDoctorTest =
    R::load([{ mid: 1, role: "user", call: -1 }, { mid: 3, role: "call", call: 0 },
             { mid: 1, role: "user", call: -1 }, { mid: 5, role: "result", call: 0 }])
      .expect(S::doctorIssuesCore(R::lines(R::ms)) > 0 and R::sessionsDoctorRepairValid)

  // The assumption is needed: an :aborted marker between a call and its
  // result is valid for the provider but replay closes the call first.
  run reachAssumptionNeededTest =
    R::load([{ mid: 3, role: "call", call: 0 }, { mid: 7, role: "aborted", call: -1 },
             { mid: 5, role: "result", call: 0 }])
      .expect(not(R::assumptionNeeded) and R::sessionsReplayKeepsValid)
}
