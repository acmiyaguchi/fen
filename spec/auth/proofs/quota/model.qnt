// Proof model: the Codex quota cache (usage.fnl), GET snapshot vs a later
// usage_limit_reached (429) observation. Only the state this contract needs,
// all finite:
//
//   server       the account is exhausted upstream
//   shown        what M.status renders: none | avail | exhausted
//   fresh        the snapshot's status is :fresh
//   sampled      a usage GET in flight and the value it sampled
//                (none | avail | exhausted)
//   obsSinceGet  a 429 was recorded after the in-flight GET was sent
//   resetSinceGet  reset-at passed after the in-flight GET was sent
//   obsNewer     ghost: the shown value predates a recorded 429
//
// The two processes of the integration model meet only through the cache
// file, so they are folded into one: a 429 recorded by either one is a q429
// step here (record-limit holds the cache lock; the GET's apply does not).
//
// FIXES: 616 applies the GET result under the cache lock and keeps windows
// whose 429 observation is newer than the GET's send time.
module quota {
  const FIXES: Set[str]

  pure val VALS = Set("none", "avail", "exhausted")

  val F616 = FIXES.contains("616")

  var server: bool
  var shown: str
  var fresh: bool
  var sampled: str
  var obsSinceGet: bool
  var resetSinceGet: bool
  var obsNewer: bool
  var lastAction: str

  action init = all {
    server' = false, shown' = "none", fresh' = false, sampled' = "none",
    obsSinceGet' = false, resetSinceGet' = false, obsNewer' = false,
    lastAction' = "init",
  }

  // claim-attempt succeeded; the GET goes out and samples the server.
  action sendGet = all {
    sampled == "none",
    sampled' = if (server) "exhausted" else "avail",
    obsSinceGet' = false, resetSinceGet' = false,
    server' = server, shown' = shown, fresh' = fresh, obsNewer' = obsNewer,
    lastAction' = "sendGet",
  }

  // Other usage exhausts the account upstream.
  action exhaust = all {
    not(server),
    server' = true,
    shown' = shown, fresh' = fresh, sampled' = sampled, obsSinceGet' = obsSinceGet,
    resetSinceGet' = resetSinceGet, obsNewer' = obsNewer,
    lastAction' = "exhaust",
  }

  // A completion gets usage_limit_reached: record-limit marks the window
  // exhausted under the cache lock and keeps retrieved-at.
  action rec429 = all {
    server,
    shown' = "exhausted", obsNewer' = false,
    fresh' = (fresh or shown == "none"),
    obsSinceGet' = (sampled != "none"),
    server' = server, sampled' = sampled, resetSinceGet' = resetSinceGet,
    lastAction' = "rec429",
  }

  // The GET returns. Today its windows replace the shown ones wholesale and
  // retrieved-at = now. A sampled exhausted window whose reset-at has passed
  // renders as 100%.
  action getReturn = all {
    sampled != "none",
    val sample = if (sampled == "exhausted" and resetSinceGet) "avail" else sampled
    val keepObs = F616 and obsSinceGet
    all {
      shown' = if (keepObs) shown else sample,
      fresh' = if (keepObs) fresh else true,
      obsNewer' = if (keepObs) obsNewer else obsSinceGet,
    },
    sampled' = "none",
    server' = server, obsSinceGet' = obsSinceGet, resetSinceGet' = resetSinceGet,
    lastAction' = "getReturn",
  }

  // reset-at passes: the server resets; M.remaining shows 100 and the
  // snapshot turns stale.
  action reset = all {
    server' = false,
    shown' = if (shown == "exhausted") "avail" else shown,
    fresh' = false, obsNewer' = false,
    resetSinceGet' = (sampled != "none"),
    sampled' = sampled, obsSinceGet' = obsSinceGet,
    lastAction' = "reset",
  }

  // 60 s pass: the snapshot is no longer fresh.
  action age = all {
    fresh' = false,
    server' = server, shown' = shown, sampled' = sampled, obsSinceGet' = obsSinceGet,
    resetSinceGet' = resetSinceGet, obsNewer' = obsNewer,
    lastAction' = "age",
  }

  action step = any { sendGet, exhaust, rec429, getReturn, reset, age }

  // ---- properties ----

  // Quota is never shown exhausted once the window has reset.
  val quotaNoStaleExhausted = shown == "exhausted" implies server

  // A fresh "available" never hides a 429 recorded after the shown data was
  // sampled.
  val quotaFreshNotContradicted = not(fresh and shown == "avail" and obsNewer)

  val typeOk = and {
    server.in(Set(true, false)),
    shown.in(VALS),
    fresh.in(Set(true, false)),
    sampled.in(VALS),
    obsSinceGet.in(Set(true, false)),
    resetSinceGet.in(Set(true, false)),
    obsNewer.in(Set(true, false)),
    lastAction.in(Set("init", "sendGet", "exhaust", "rec429", "getReturn", "reset", "age")),
  }

  // An exhausted sample is still true upstream unless a reset intervened.
  val sampleTracksServer = (sampled == "exhausted" and not(resetSinceGet)) implies server

  // Today and with the fix: a reset-at that passed is never shown exhausted.
  val noStaleExhaustedInductive = and { typeOk, sampleTracksServer, quotaNoStaleExhausted }

  // With the fix: no shown value ever predates a recorded 429.
  val quotaInductive = and {
    typeOk, sampleTracksServer, quotaNoStaleExhausted, not(obsNewer), quotaFreshNotContradicted,
  }
}

// Since #605 today's code carries the fixes, so `current` matches `fixed`.
module current { import quota(FIXES = Set("616")).* }
module fixed { import quota(FIXES = Set("616")).* }
