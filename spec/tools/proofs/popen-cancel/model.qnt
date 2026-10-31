// Proof model: cancelling grep/find/ls (#659).
//
// The `popen` machine of ../../model.qnt on its own.  The tools run the
// command with io.popen and read it with read-pipe-coop, yielding on EAGAIN.
// A cancel raised at that yield reaches read-pipe-close, whose pipe:close()
// is pclose(3): a wait for the shell that does not yield, so the presenter and
// every other coroutine stall until the child exits on its own.
//
// Code: extensions/behaviors/kernel/builtin-tools/{grep,find,ls}.fnl,
// packages/util/src/fen/util/process/init.fnl (read-pipe-coop,
// read-pipe-close).
//
// The #659 fix: run them through process.start-captured with :argv; its
// abort SIGKILLs the group before the bounded cleanup.
module popenCancel {
  const FIXES: Set[str]

  // phase: idle | reading | closing | done
  var phase: str
  var childAlive: bool
  var killed: bool
  var result: str     // none | ok | cancelled

  action init = all {
    phase' = "idle", childAlive' = false, killed' = false, result' = "none",
  }

  action start = all {
    phase == "idle",
    phase' = "reading", childAlive' = true, killed' = killed, result' = result,
  }

  action childExit = all {
    childAlive,
    phase' = phase, childAlive' = false, killed' = killed, result' = result,
  }

  action eof = all {
    phase == "reading", not(childAlive),
    phase' = "done", childAlive' = childAlive, killed' = killed, result' = "ok",
  }

  // Cancel at the EAGAIN yield.  Today: close the FILE* and pclose.
  action cancel = all {
    phase == "reading",
    val kill = FIXES.contains("659")
    all {
      phase' = "closing", killed' = kill,
      childAlive' = (childAlive and not(kill)), result' = result,
    },
  }

  // pclose returns once the shell has exited.
  action closeReturns = all {
    phase == "closing", not(childAlive),
    phase' = "done", childAlive' = childAlive, killed' = killed,
    result' = "cancelled",
  }

  action stutter = all {
    phase == "done",
    phase' = phase, childAlive' = childAlive, killed' = killed, result' = result,
  }

  action step = any { start, childExit, eof, cancel, closeReturns, stutter }

  // The tool thread never sits in a non-yielding wait on a child that has not
  // been told to die.  (A per-state safety property: it says nothing about
  // how long a killed child takes to exit.)
  val noUnboundedBlockingWait = (phase == "closing" and childAlive) implies killed

  // A cancelled call reports "cancelled" and an EOF reports "ok".
  val resultMatchesPath = and {
    result == "cancelled" implies (phase == "done"),
    result == "ok" implies (phase == "done" and not(killed)),
  }

  val inductiveInv = and {
    phase.in(Set("idle", "reading", "closing", "done")),
    childAlive.in(Set(true, false)), killed.in(Set(true, false)),
    result.in(Set("none", "ok", "cancelled")),
    noUnboundedBlockingWait,
    resultMatchesPath,
    phase == "reading" implies not(killed),
    phase == "idle" implies (result == "none" and not(killed)),
  }
}

module current { import popenCancel(FIXES = Set("659")).* }
module fixed { import popenCancel(FIXES = Set("659")).* }
