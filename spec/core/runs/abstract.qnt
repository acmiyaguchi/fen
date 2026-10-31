// Abstract specification of subagent run table and mailbox (#674):
// subagent run lifecycle, per-run delivery mailbox, and control ack settlement.
//
// A run progresses from unlaunched (none) to live (running, finalizing) and
// reaches a terminal status (done, cancelled) at most once. The process is alive
// exactly while in a live status.
//
// Mailbox delivery ensures:
// 1. Completion is delivered to the parent at most once (via tool result, wait,
//    or turn-top follow-up).
// 2. A terminal run guarantees the outcome is either in the mailbox or already
//    delivered.
//
// Control ack settlement ensures:
// 1. Every control sent by the parent receives at most one acknowledgment.
// 2. On termination/settlement, every control sent is accounted for (no orphaned
//    unacked controls).
//
// Pure definitions only, so concrete models can import them.
module runsAbstract {
  type Abs = {
    mode: str,         // "none" | "blocking" | "background"
    status: str,       // "none" | "running" | "finalizing" | "done" | "cancelled"
    alive: bool,       // process alive
    mailbox: bool,     // outcome available in mailbox
    delivered: bool,   // outcome consumed by parent
    sentCtl: int,      // controls sent by parent
    ackedCtl: int,     // controls acknowledged by run
  }

  pure def live(st: str): bool = st == "running" or st == "finalizing"
  pure def terminal(st: str): bool = st == "done" or st == "cancelled"

  pure val absInit: Abs = {
    mode: "none",
    status: "none",
    alive: false,
    mailbox: false,
    delivered: false,
    sentCtl: 0,
    ackedCtl: 0,
  }

  // Parent launches run.
  pure def launch(a: Abs, b: Abs, m: str): bool = and {
    a.status == "none",
    m != "none",
    b.mode == m,
    b.status == "running",
    b.alive,
    not(b.mailbox),
    not(b.delivered),
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.ackedCtl,
  }

  // Parent sends a control (steer, prompt, etc.) to the run.
  pure def sendControl(a: Abs, b: Abs): bool = and {
    a.alive,
    b.mode == a.mode,
    b.status == a.status,
    b.alive == a.alive,
    b.mailbox == a.mailbox,
    b.delivered == a.delivered,
    b.sentCtl == a.sentCtl + 1,
    b.ackedCtl == a.ackedCtl,
  }

  // Run acknowledges a received control.
  pure def ackControl(a: Abs, b: Abs): bool = and {
    a.alive,
    a.ackedCtl < a.sentCtl,
    b.mode == a.mode,
    b.status == a.status,
    b.alive == a.alive,
    b.mailbox == a.mailbox,
    b.delivered == a.delivered,
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.ackedCtl + 1,
  }

  // Run transitions to finalizing (e.g. tool budget reached).
  pure def finalize(a: Abs, b: Abs): bool = and {
    a.alive,
    a.status == "running",
    b.mode == a.mode,
    b.status == "finalizing",
    b.alive,
    b.mailbox == a.mailbox,
    b.delivered == a.delivered,
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.ackedCtl,
  }

  // Run exits normally (done): outcome placed in mailbox, controls settled.
  pure def finish(a: Abs, b: Abs): bool = and {
    a.alive,
    live(a.status),
    b.mode == a.mode,
    b.status == "done",
    not(b.alive),
    b.mailbox,
    b.delivered == a.delivered,
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.sentCtl,
  }

  // Parent cancels / reaps the run: outcome placed in mailbox, controls settled.
  pure def reap(a: Abs, b: Abs): bool = and {
    a.alive,
    live(a.status),
    b.mode == a.mode,
    b.status == "cancelled",
    not(b.alive),
    b.mailbox,
    b.delivered == a.delivered,
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.sentCtl,
  }

  // Parent consumes the completion outcome from the mailbox (wait, tool result, or turn top).
  pure def deliver(a: Abs, b: Abs): bool = and {
    terminal(a.status),
    a.mailbox,
    not(a.delivered),
    b.mode == a.mode,
    b.status == a.status,
    b.alive == a.alive,
    not(b.mailbox),
    b.delivered,
    b.sentCtl == a.sentCtl,
    b.ackedCtl == a.ackedCtl,
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    launch(a, b, "blocking"),
    launch(a, b, "background"),
    sendControl(a, b),
    ackControl(a, b),
    finalize(a, b),
    finish(a, b),
    reap(a, b),
    deliver(a, b),
  }

  // ---- properties ----

  // Process alive exactly matches live status.
  pure def statusMatchesProcess(a: Abs): bool =
    live(a.status) == a.alive

  // Unlaunched run has no outcome and no live process.
  pure def unlaunchedEmpty(a: Abs): bool =
    a.status == "none" implies (not(a.alive) and not(a.mailbox) and not(a.delivered) and a.mode == "none")

  // Terminal run outcome is either in mailbox or already delivered.
  pure def toldOrPending(a: Abs): bool =
    terminal(a.status) implies (a.mailbox or a.delivered)

  // Outcome cannot be both in mailbox and delivered.
  pure def mailboxDeliveredDisjoint(a: Abs): bool =
    not(a.mailbox and a.delivered)

  // Mailbox holds an outcome only when the run is terminal.
  pure def mailboxOnlyWhenTerminal(a: Abs): bool =
    a.mailbox implies terminal(a.status)

  // Delivered outcome implies run has reached terminal status.
  pure def deliveredOnlyWhenTerminal(a: Abs): bool =
    a.delivered implies terminal(a.status)

  // Acknowledged controls are bounded by sent controls.
  pure def controlsAckedBounded(a: Abs): bool =
    0 <= a.ackedCtl and a.ackedCtl <= a.sentCtl

  // On exit/termination, all sent controls are settled.
  pure def controlsSettledAtTerminal(a: Abs): bool =
    terminal(a.status) implies a.ackedCtl == a.sentCtl

  pure def absInv(a: Abs): bool = and {
    statusMatchesProcess(a),
    unlaunchedEmpty(a),
    toldOrPending(a),
    mailboxDeliveredDisjoint(a),
    mailboxOnlyWhenTerminal(a),
    deliveredOnlyWhenTerminal(a),
    controlsAckedBounded(a),
    controlsSettledAtTerminal(a),
  }
}
