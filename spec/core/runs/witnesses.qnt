// Reachability of the abstract subagent run and mailbox machine (#674).
module witnesses {
  import runsAbstract.* from "./abstract"
  import runsSpec as R from "./model"

  // Blocking run launches, completes, and parent delivers outcome.
  run reachLaunchFinishDeliverTest =
    R::init.then(R::doLaunch("blocking")).then(R::doFinish).then(R::doDeliver)
      .expect(R::a.delivered and not(R::a.alive) and R::a.status == "done" and R::allInvariants)

  // Controls sent are acknowledged and settled.
  run reachControlAckSettlementTest =
    R::init.then(R::doLaunch("background")).then(R::doSendControl).then(R::doAckControl).then(R::doFinish)
      .expect(R::a.ackedCtl == 1 and R::a.sentCtl == 1 and R::allInvariants)

  // A run that transitions to finalizing and is reaped still delivers its completion.
  run reachFinalizeAndReapTest =
    R::init.then(R::doLaunch("background")).then(R::doFinalize).then(R::doReap).then(R::doDeliver)
      .expect(R::a.status == "cancelled" and R::a.delivered and R::allInvariants)

  // Unacknowledged controls are settled automatically when reaped.
  run reachControlSettledOnReapTest =
    R::init.then(R::doLaunch("background")).then(R::doSendControl).then(R::doReap)
      .expect(R::a.ackedCtl == R::a.sentCtl and R::a.mailbox and R::allInvariants)
}
