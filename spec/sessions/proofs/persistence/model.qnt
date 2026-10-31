// Proof model: session persistence (torn tail #640, flush cursor #641).
//
//   packages/fen/src/fen/session_lifecycle.fnl   make-flush: append mem[saved+1..]
//                                                one by one; today the cursor
//                                                advances whether or not the
//                                                append returned an entry
//   extensions/adapters/session-backends/jsonl/session.fnl
//                                                append-entry: one `json .. "\n"`
//                                                write; a failed write logs and
//                                                returns nil; a partial last line
//                                                is not terminated first, so the
//                                                next entry lands on it
//                                                open-existing / load: resume
//
// Contract: a message counts as saved only once its entry is readable, and
// after a complete flush the readable log is exactly what the process holds.
//
// Only the state that contract needs: message ids are allocated in order, so
// the in-memory history is a set of ids and the flush cursor is the highest
// id handed to append; the log is the set of ids `load` can read plus whether
// it ends in a partial line. No transcript, no roles, no tool pairing (those
// are the integration model's and the replay obligation's).
module persistence {
  const FIXES: Set[str]

  pure val MAXID = 5
  pure val IDS = 1.to(MAXID)

  var up: bool              // the writing process is alive
  var nextId: int             // next message id
  var saved: int            // flush cursor: ids <= saved were handed to append
  var mem: Set[int]         // agent.messages of the live process
  var readable: Set[int]    // entries load can parse
  var acked: Set[int]       // entries append returned an entry id for (ghost)
  var torn: bool            // the file ends in a partial line
  var failNext: bool        // the next write fails (ENOSPC, EIO, ...)

  action init = all {
    up' = true, nextId' = 1, saved' = 0, mem' = Set(), readable' = Set(), acked' = Set(),
    torn' = false, failNext' = false,
  }

  // agent.append-message!
  action produce = all {
    up, nextId <= MAXID,
    mem' = mem.union(Set(nextId)), nextId' = nextId + 1,
    up' = up, saved' = saved, readable' = readable, acked' = acked, torn' = torn,
    failNext' = failNext,
  }

  // One append of the first unsaved message.
  action flush = all {
    up, saved < nextId - 1,
    val id = saved + 1
    if (failNext)
      if (FIXES.contains("641"))
        // fix: the cursor stays, so the next flush retries this message
        all { failNext' = false, saved' = saved, acked' = acked, readable' = readable,
              torn' = torn }
      else
        all { failNext' = false, saved' = id, acked' = acked.union(Set(id)),
              readable' = readable, torn' = torn }
    else if (torn)
      // today: the entry is glued onto the partial line; load skips both,
      // yet append returned an entry id
      all { failNext' = false, saved' = id, acked' = acked.union(Set(id)),
            readable' = readable, torn' = false }
    else
      all { failNext' = false, saved' = id, acked' = acked.union(Set(id)),
            readable' = readable.union(Set(id)), torn' = false },
    up' = up, nextId' = nextId, mem' = mem,
  }

  action failAppend = all {
    not(failNext),
    failNext' = true,
    up' = up, nextId' = nextId, saved' = saved, mem' = mem, readable' = readable,
    acked' = acked, torn' = torn,
  }

  // Killed at any point; with tornWrite it dies inside the write of the
  // first unsaved message (stdio splits long lines into several write(2)s).
  action crash(tornWrite: bool): bool = all {
    up,
    not(tornWrite) or saved < nextId - 1,
    up' = false, mem' = Set(), torn' = (torn or tornWrite),
    nextId' = nextId, saved' = saved, readable' = readable, acked' = acked,
    failNext' = failNext,
  }

  // fen --continue: load, open-existing, cursor = #replayed. Fix #640:
  // open-existing terminates (or truncates) a partial last line first.
  action resume = all {
    not(up),
    up' = true, mem' = readable, saved' = nextId - 1,
    torn' = if (FIXES.contains("640")) false else torn,
    nextId' = nextId, readable' = readable, acked' = acked, failNext' = failNext,
  }

  action step = any {
    produce, flush, failAppend, crash(true), crash(false), resume,
  }

  // ---- properties ----

  // A message a writer counted as saved is readable.
  val ackedReadable = acked.subseteq(readable)

  // After a flush the cursor considers complete, the readable log is
  // exactly the live process's history.
  val replayMatchesMemory = (up and saved == nextId - 1) implies readable == mem

  val allInvariants = ackedReadable and replayMatchesMemory

  // Inductive strengthening for the fixed design: variable domains first
  // (Apalache reads them as the initial states of the induction step), then
  // what the step needs. Every readable id was allocated; the live process
  // holds every readable entry, every message up to the cursor is readable,
  // every message past it is still in memory, and no partial line is ever
  // open under a live writer.
  val persistInductive = and {
    up.in(Set(true, false)),
    nextId.in(1.to(MAXID + 1)),
    saved.in(0.to(MAXID)),
    mem.in(IDS.powerset()),
    readable.in(IDS.powerset()),
    acked.in(IDS.powerset()),
    torn.in(Set(true, false)),
    failNext.in(Set(true, false)),
    saved < nextId,
    readable.forall(i => i < nextId),
    acked.subseteq(readable),
    up implies and {
      not(torn),
      mem.forall(i => i < nextId),
      readable.subseteq(mem),
      mem.forall(i => i <= saved implies readable.contains(i)),
      IDS.forall(i => (saved < i and i < nextId) implies mem.contains(i)),
    },
    allInvariants,
  }
}

module current { import persistence(FIXES = Set()).* }
module fix640 { import persistence(FIXES = Set("640")).* }
module fix641 { import persistence(FIXES = Set("641")).* }
module fixed { import persistence(FIXES = Set("640", "641")).* }
