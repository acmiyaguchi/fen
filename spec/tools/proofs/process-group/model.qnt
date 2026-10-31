// Proof model: the bash process job's group containment (#651).
//
// The `bash` machine of ../../model.qnt on its own, in scalar variables:
// a command leader in its own session plus one more group member sharing the
// pipe (a backgrounded or nested command); either may ignore SIGTERM.  The
// job sends SIGTERM at the deadline, SIGKILL after the grace window, SIGKILL
// on cancel, and finishes once the leader is reaped (EOF or the 150 ms
// post-exit window, shorter than the 200 ms grace).
//
// Code: packages/util/src/fen/util/process/init.fnl (start-captured tick!,
// abort!, send-kill!), packages/util/vendor/fen_process.c.
//
// The #651 fix: on timeout or cancel, SIGKILL the group whether or not the
// leader has been reaped (the pgid cannot be reused while any member lives).
module processGroup {
  const FIXES: Set[str]

  var started: bool
  var leaderAlive: bool
  var memberAlive: bool
  var leaderIgnoresTerm: bool
  var memberIgnoresTerm: bool
  var termSent: bool
  var killSent: bool
  var timedOut: bool
  var cancelled: bool
  var done: bool

  pure def fix651: bool = FIXES.contains("651")
  def groupAlive: bool = leaderAlive or memberAlive

  action unchangedFlags: bool = all {
    started' = started, leaderIgnoresTerm' = leaderIgnoresTerm,
    memberIgnoresTerm' = memberIgnoresTerm,
  }

  action init = all {
    started' = false, leaderAlive' = false, memberAlive' = false,
    leaderIgnoresTerm' = false, memberIgnoresTerm' = false,
    termSent' = false, killSent' = false, timedOut' = false,
    cancelled' = false, done' = false,
  }

  action startWith(li: bool, mi: bool): bool = all {
    not(started),
    started' = true, leaderAlive' = true, memberAlive' = true,
    leaderIgnoresTerm' = li, memberIgnoresTerm' = mi,
    termSent' = termSent, killSent' = killSent, timedOut' = timedOut,
    cancelled' = cancelled, done' = done,
  }

  action start = {
    nondet li = Set(true, false).oneOf()
    nondet mi = Set(true, false).oneOf()
    startWith(li, mi)
  }

  action leaderExit = all {
    started, not(done), leaderAlive,
    leaderAlive' = false, memberAlive' = memberAlive,
    termSent' = termSent, killSent' = killSent, timedOut' = timedOut,
    cancelled' = cancelled, done' = done, unchangedFlags,
  }

  action memberExit = all {
    started, not(done), memberAlive,
    leaderAlive' = leaderAlive, memberAlive' = false,
    termSent' = termSent, killSent' = killSent, timedOut' = timedOut,
    cancelled' = cancelled, done' = done, unchangedFlags,
  }

  // tick!: the deadline passed while the leader is unreaped -> SIGTERM group.
  action deadline = all {
    started, not(done), leaderAlive, not(termSent),
    leaderAlive' = leaderIgnoresTerm,
    memberAlive' = (memberAlive and memberIgnoresTerm),
    termSent' = true, killSent' = killSent, timedOut' = true,
    cancelled' = cancelled, done' = done, unchangedFlags,
  }

  // tick!: the grace elapsed -> SIGKILL group; today only while the leader
  // is unreaped.
  action grace = all {
    started, not(done), termSent, not(killSent),
    if (fix651) groupAlive else leaderAlive,
    leaderAlive' = false, memberAlive' = false,
    termSent' = termSent, killSent' = true, timedOut' = timedOut,
    cancelled' = cancelled, done' = done, unchangedFlags,
  }

  // abort!: cancel raised at a yield; send-kill! is gated on not reaped.
  action cancel = all {
    started, not(done), not(cancelled),
    val kill = if (fix651) groupAlive else leaderAlive
    all {
      leaderAlive' = (leaderAlive and not(kill)),
      memberAlive' = (memberAlive and not(kill)),
      termSent' = termSent, killSent' = (killSent or kill),
      timedOut' = timedOut, cancelled' = true, done' = done, unchangedFlags,
    },
  }

  // Leader reaped and the pipe drained or the post-exit window elapsed.
  action finish = all {
    started, not(done), not(leaderAlive),
    val reap = fix651 and (timedOut or cancelled)
    all {
      leaderAlive' = leaderAlive,
      memberAlive' = (memberAlive and not(reap)),
      termSent' = termSent, killSent' = (killSent or (reap and memberAlive)),
      timedOut' = timedOut, cancelled' = cancelled, done' = true,
      unchangedFlags,
    },
  }

  // The job has returned; nothing else happens (keeps Apalache's deadlock
  // check from flagging the terminal state).
  action stutter = all {
    done,
    leaderAlive' = leaderAlive, memberAlive' = memberAlive,
    termSent' = termSent, killSent' = killSent, timedOut' = timedOut,
    cancelled' = cancelled, done' = done, unchangedFlags,
  }

  action step = any {
    start, leaderExit, memberExit, deadline, grace, cancel, finish, stutter,
  }

  // A timed-out or cancelled call leaves no live process in its group.
  val noLiveProcessAfterAbnormalEnd =
    (done and (timedOut or cancelled)) implies not(memberAlive)

  // SIGKILL is only ever sent for a timeout or cancel.
  val killOnlyOnAbnormalEnd = killSent implies (timedOut or cancelled)

  val BOOLS = Set(true, false)

  // Inductive strengthening of killOnlyOnAbnormalEnd: nothing happens before
  // the start, and SIGTERM is only sent at the deadline.  The `in` conjuncts
  // give Apalache the state space to start from.  Holds today too.
  val killInductiveInv = and {
    started.in(BOOLS), leaderAlive.in(BOOLS), memberAlive.in(BOOLS),
    leaderIgnoresTerm.in(BOOLS), memberIgnoresTerm.in(BOOLS),
    termSent.in(BOOLS), killSent.in(BOOLS), timedOut.in(BOOLS),
    cancelled.in(BOOLS), done.in(BOOLS),
    killOnlyOnAbnormalEnd,
    termSent implies timedOut,
    not(started) implies not(or {
      leaderAlive, memberAlive, termSent, killSent, timedOut, cancelled, done,
    }),
  }

  // Both properties, plus: the job returns only once the leader is reaped.
  val inductiveInv = and {
    killInductiveInv,
    noLiveProcessAfterAbnormalEnd,
    done implies not(leaderAlive),
  }
}

module current { import processGroup(FIXES = Set("651")).* }
module fixed { import processGroup(FIXES = Set("651")).* }
