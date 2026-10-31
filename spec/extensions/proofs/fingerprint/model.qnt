// Proof model: a failed module is retried on the next reload (#625).
//
// Contract: :loaded never hides a broken source the last attempt saw; a
// module's fingerprint is committed only after it reloads successfully (as
// reload-core! already does with reload-core-failures).
//
// Only the state the contract needs: one extension module's source on disk,
// whether its current fingerprint is committed, the status the last reload
// recorded, and (ghost) the source that attempt saw.
//
// Integration model: ../../model.qnt.
module fingerprint {
  const FIXES: Set[str]

  var src: str        // "ok" | "bad" on disk
  var committed: bool // change-summary holds the fingerprint of `src`
  var status: str     // "loaded" | "error"
  var tried: str      // ghost: source seen by the last reload

  action init = all { src' = "ok", committed' = true, status' = "loaded", tried' = "ok" }

  // The developer edits the source; its fingerprint changes.
  action edit(v: str): bool = all {
    src != v, src' = v, committed' = false, status' = status, tried' = tried,
  }

  // clear-reload-modules!: change-summary decides what changed and (today)
  // commits every fingerprint before any module runs. An unchanged module is
  // skipped, and require returns the old table restored in package.loaded.
  action reload = all {
    tried' = src,
    if (committed)
      all { status' = "loaded", committed' = true, src' = src }
    else if (src == "ok")
      all { status' = "loaded", committed' = true, src' = src }
    else
      all { status' = "error", committed' = not(FIXES.contains("625")), src' = src },
  }

  action step = any {
    nondet v = Set("ok", "bad").oneOf()
    edit(v),
    reload,
  }

  // :loaded never hides a broken source seen by the last attempt.
  val loadedStatusTruthful = status == "loaded" implies tried == "ok"

  // Inductive strengthening: a committed fingerprint is one of a good source.
  val fingerprintInductive = and {
    src.in(Set("ok", "bad")), committed.in(Bool), status.in(Set("loaded", "error")),
    tried.in(Set("ok", "bad")),
    committed implies src == "ok",
    loadedStatusTruthful,
  }
}

module current { import fingerprint(FIXES = Set()).* }
module fixed { import fingerprint(FIXES = Set("625")).* }
