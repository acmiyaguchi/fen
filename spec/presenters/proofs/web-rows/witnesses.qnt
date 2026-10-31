module witnesses {
  import webrows(FIXES = Set("631")) as C from "./model"
  import webrows(FIXES = Set("631")) as F from "./model"

  run reach631RetryDropsAttemptTest =
    C::init.then(C::startStep(true)).then(C::streamToken).then(C::retry)
      .then(C::streamToken).then(C::streamToken).then(C::endStop)
      .expect(C::webRowsSingleAttempt and C::webOkReplyShown and C::webRowsSingleStep)

  // latent #630 in web: an error leaves the row reachable, but the typed
  // next step's :user row stops the join
  run reachCurrentErrorThenTypedNoJoinTest =
    C::init.then(C::startStep(true)).then(C::streamToken).then(C::endFailed)
      .then(C::startStep(true)).then(C::streamToken)
      .expect(C::open and C::reach and C::rowStep == 2 and C::stepInv)

  run reachRetryThenOkTest =
    F::init.then(F::startStep(true)).then(F::streamToken).then(F::retry)
      .then(F::streamToken).then(F::streamToken).then(F::endStop)
      .expect(F::lastOk and F::fixedInv)

  run reachGoalIterationTest =
    F::init.then(F::startStep(true)).then(F::streamToken).then(F::streamToken)
      .then(F::endStop).then(F::startStep(false)).then(F::streamToken)
      .then(F::streamToken).then(F::endToolUse).then(F::streamToken)
      .then(F::streamToken).then(F::endStop)
      .expect(F::iter == 2 and F::calls == 2 and F::fixedInv)

  run reachCancelThenTypedTest =
    F::init.then(F::startStep(true)).then(F::streamToken).then(F::endFailed)
      .then(F::startStep(true)).then(F::streamToken).then(F::streamToken).then(F::endStop)
      .expect(F::fixedInv)
}
