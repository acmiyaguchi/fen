// Reachability of the abstract usage ledger machine (#672).
module witnesses {
  import ledgerAbstract.* from "./abstract"
  import ledgerSpec as L from "./model"

  // Appending entries folds into session total.
  run reachAppendAndFoldTest =
    L::init.then(L::doAppend(1)).then(L::doAppend(2))
      .expect(sessionTotal(L::a) == 3 and L::allInvariants)

  // Taking a mark allows calculating the exact delta from that point.
  run reachTakeMarkDeltaTest =
    L::init.then(L::doAppend(1)).then(L::doTakeMark).then(L::doAppend(2))
      .expect(deltaFrom(L::a, 1) == 2 and L::allInvariants)

  // History rewrite watermark advances while log entries remain append-only.
  run reachRewriteWatermarkTest =
    L::init.then(L::doAppend(1)).then(L::doRewrite).then(L::doAppend(2))
      .expect(L::a.watermark == 1 and L::a.log[0].epoch == 0 and L::a.log[1].epoch == 1 and L::allInvariants)

  // A mark at the tip has zero delta.
  run reachZeroDeltaTipTest =
    L::init.then(L::doAppend(1)).then(L::doTakeMark)
      .expect(deltaFrom(L::a, 1) == 0 and L::allInvariants)
}
