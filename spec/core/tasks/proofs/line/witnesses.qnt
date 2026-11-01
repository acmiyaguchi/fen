// Reachability for one representative line (L1).
module witnesses {
  import lineSpec as V from "./model"

  run reachSteerReturnedToItsTurnTest =
    V::init.then(V::doLease({ kind: "none", n: 0, hid: 0, body: false, cancel: false, startReq: true, exReq: false }, false, false, false, "one", "one"))
      .then(V::doLease({ kind: "turn", n: 1, hid: 1, body: true, cancel: false, startReq: false, exReq: false }, false, false, false, "one", "one"))
      .then(V::doAdmit(-1, false, false, false, "one", "one"))
      .then(V::doRelease(false, false, false, "one", "one"))
      .expect(V::why == "released" and V::whyN == 1 and V::allInvariants)

  run reachFollowUpStartsTurnTest =
    V::init.then(V::doAdmit(-1, false, false, false, "one", "one"))
      .then(V::doLease({ kind: "none", n: 0, hid: 0, body: false, cancel: false, startReq: true, exReq: false }, false, false, false, "one", "one"))
      .then(V::doStart(false, false, false, "one", "one"))
      .expect(V::why == "started" and V::whyN == 1 and V::kind == "turn" and V::allInvariants)

  run reachStaleOfferRefusedTest =
    V::init.then(V::doLease({ kind: "none", n: 0, hid: 0, body: false, cancel: false, startReq: true, exReq: false }, false, false, false, "one", "one"))
      .then(V::doLease({ kind: "turn", n: 1, hid: 1, body: true, cancel: false, startReq: false, exReq: false }, false, false, false, "one", "one"))
      .then(V::doAdmit(2, false, false, false, "one", "one"))
      .expect(V::why == "refused" and V::allInvariants)
}
