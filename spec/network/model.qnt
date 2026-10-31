// Model of fen's provider network path for one session, as it works today.
//
//   agent.step-loop  -> llm-start
//   shared/streaming -> retry.with-retry over attempts; each attempt gets a
//                       fresh SSE parser/state, but deltas go straight to the
//                       event bus as they arrive (no buffering per attempt)
//   retry            -> transient failure (429/5xx/transient curl code/2xx
//                       stream without terminal event) and attempts left:
//                       emit :provider-retry, back off (cancellable), retry
//   finalize-stream  -> assistant message built from the LAST attempt only
//   agent            -> llm-end, append message, then
//                       ok:    assistant-stream-end {:final? true}
//                       error: :error   (no stream-end)
//   cancel           -> CANCEL-MARKER at a yield (stream tick or backoff):
//                       aborted assistant appended, :cancelled (no llm-end,
//                       no stream-end)
//
// The TUI side is `ingest`, a pure (tui, event) -> tui step that mirrors
// extensions/adapters/presenters/tui/ingest.fnl. FIXED selects a candidate
// fix so the same invariants can be checked against both.
module network {
  const FIXED: bool

  pure val MAX_TURNS = 2
  pure val REPLY_LEN = 2
  pure val MAX_ATTEMPTS = 2

  // A streamed token remembers which turn and attempt produced it (ghost data).
  type Tok = { turn: int, attempt: int, idx: int }

  type Event =
    | User
    | LlmStart
    | TextDelta(Tok)
    | HostedStart
    | HostedEnd
    | ProviderRetry
    | LlmEnd
    | StreamEnd
    | Error
    | Cancelled

  type Row = { kind: str, toks: List[Tok], streaming: bool }

  // tui.state slice: transcript rows, the open streaming row
  // (streaming-assistant-rows, one content index), hosted tools, retry flag.
  type Tui = { rows: List[Row], open: int, hosted: bool, retrying: bool }

  type Msg = { turn: int, outcome: str, toks: List[Tok] }

  pure def closeOpen(t: Tui): Tui =
    if (t.open < 0) t
    else { ...t,
           rows: t.rows.replaceAt(t.open, { ...t.rows[t.open], streaming: false }),
           open: -1 }

  pure def pushRow(t: Tui, kind: str): Tui =
    { ...t, rows: t.rows.append({ kind: kind, toks: [], streaming: false }) }

  pure def ingest(t: Tui, e: Event): Tui = match e {
    | User => t.pushRow("user")
    | LlmStart => { ...t, retrying: false }
    | TextDelta(tok) =>
        if (t.open < 0)
          { ...t,
            rows: t.rows.append({ kind: "assistant", toks: [tok], streaming: true }),
            open: t.rows.length() }
        else
          { ...t,
            rows: t.rows.replaceAt(t.open,
                    { ...t.rows[t.open], toks: t.rows[t.open].toks.append(tok) }) }
    | HostedStart => { ...t, hosted: true }
    | HostedEnd => { ...t, hosted: false }.pushRow("info") // hosted-tool-row
    | ProviderRetry =>
        // today: clear hosted tools (#574) and show retrying; streamed text kept
        val base = { ...t, hosted: false, retrying: true }
        if (FIXED and base.open >= 0)
          { ...base,
            rows: base.rows.replaceAt(base.open, { ...base.rows[base.open], toks: [] }) }
        else base
    | LlmEnd => { ...t, hosted: false, retrying: false }
    | StreamEnd => { ...closeOpen(t), hosted: false, retrying: false }
    | Error =>
        val base = { ...t, hosted: false, retrying: false }
        (if (FIXED) closeOpen(base) else base).pushRow("error")
    | Cancelled =>
        val base = { ...t, hosted: false, retrying: false }
        (if (FIXED) closeOpen(base) else base).pushRow("cancelled")
  }

  pure def emitAll(t: Tui, evs: List[Event]): Tui =
    evs.foldl(t, (acc, e) => ingest(acc, e))

  // ---- state ----
  var phase: str          // "idle" | "streaming" | "backoff"
  var turn: int
  var attempt: int
  var buf: List[Tok]      // latest attempt's stream state (latest.state)
  var hostedOpen: bool
  var visible: bool       // complete-once stream-state.visible?
  var history: List[Msg]  // agent.messages (assistant side)
  var finalAttempt: int -> int
  var tui: Tui
  var lastAction: str
  var emitted: List[Event] // ghost: every bus event, for trace replay

  action init = all {
    phase' = "idle", turn' = 0, attempt' = 0, buf' = [], hostedOpen' = false,
    visible' = false, history' = [], finalAttempt' = Map(),
    tui' = { rows: [], open: -1, hosted: false, retrying: false },
    lastAction' = "init", emitted' = [],
  }

  action startTurn = all {
    phase == "idle", turn < MAX_TURNS,
    phase' = "streaming", turn' = turn + 1, attempt' = 1, buf' = [],
    hostedOpen' = false, visible' = false,
    history' = history, finalAttempt' = finalAttempt,
    tui' = tui.emitAll([User, LlmStart]), emitted' = emitted.concat([User, LlmStart]),
    lastAction' = "startTurn",
  }

  action streamToken = all {
    phase == "streaming", buf.length() < REPLY_LEN,
    val tok = { turn: turn, attempt: attempt, idx: buf.length() }
    all {
      buf' = buf.append(tok), visible' = true,
      tui' = tui.ingest(TextDelta(tok)), emitted' = emitted.append(TextDelta(tok)),
      phase' = phase, turn' = turn, attempt' = attempt, hostedOpen' = hostedOpen,
      history' = history, finalAttempt' = finalAttempt,
      lastAction' = "streamToken",
    }
  }

  action hosted(start: bool): bool = all {
    phase == "streaming", hostedOpen != start,
    hostedOpen' = start,
    tui' = tui.ingest(if (start) HostedStart else HostedEnd), emitted' = emitted.append(if (start) HostedStart else HostedEnd),
    phase' = phase, turn' = turn, attempt' = attempt, buf' = buf,
    visible' = visible, history' = history, finalAttempt' = finalAttempt,
    lastAction' = if (start) "hostedStart" else "hostedEnd",
  }

  // One HTTP attempt finishes. "transient" covers 429, 5xx, transient curl
  // codes, and a 2xx stream that ended without its terminal event.
  action attemptEnd(outcome: str): bool = all {
    phase == "streaming",
    outcome != "complete" or buf.length() == REPLY_LEN,
    turn' = turn, hostedOpen' = false, visible' = visible,
    lastAction' = outcome,
    if (outcome == "transient" and attempt < MAX_ATTEMPTS)
      all {
        phase' = "backoff", attempt' = attempt, buf' = buf,
        history' = history, finalAttempt' = finalAttempt,
        tui' = tui.ingest(ProviderRetry), emitted' = emitted.append(ProviderRetry),
      }
    else if (outcome == "complete")
      all {
        phase' = "idle", attempt' = attempt, buf' = buf,
        history' = history.append({ turn: turn, outcome: "ok", toks: buf }),
        finalAttempt' = finalAttempt.put(turn, attempt),
        tui' = tui.emitAll([LlmEnd, StreamEnd]), emitted' = emitted.concat([LlmEnd, StreamEnd]),
      }
    else
      all {
        phase' = "idle", attempt' = attempt, buf' = buf,
        history' = history.append({ turn: turn, outcome: "error", toks: [] }),
        finalAttempt' = finalAttempt.put(turn, attempt),
        tui' = tui.emitAll([LlmEnd, Error]), emitted' = emitted.concat([LlmEnd, Error]),
      }
  }

  action backoffDone = all {
    phase == "backoff",
    phase' = "streaming", attempt' = attempt + 1, buf' = [], hostedOpen' = false,
    turn' = turn, visible' = visible, history' = history,
    finalAttempt' = finalAttempt, tui' = tui, emitted' = emitted,
    lastAction' = "backoffDone",
  }

  // Ctrl-C / deadline / finalize lands at the next cooperative yield.
  action cancel = all {
    phase == "streaming" or phase == "backoff",
    phase' = "idle", turn' = turn, attempt' = attempt, buf' = buf,
    hostedOpen' = false, visible' = visible,
    history' = history.append({ turn: turn, outcome: "aborted", toks: [] }),
    finalAttempt' = finalAttempt.put(turn, attempt),
    tui' = tui.ingest(Cancelled), emitted' = emitted.append(Cancelled),
    lastAction' = "cancel",
  }

  action step = any {
    startTurn,
    streamToken,
    hosted(true),
    hosted(false),
    nondet o = Set("complete", "transient", "permanent").oneOf()
    attemptEnd(o),
    backoffDone,
    cancel,
  }

  // ---- properties ----
  pure def assistantRows(t: Tui): List[Row] =
    t.rows.select(r => r.kind == "assistant")

  // Once a turn is over, nothing is still streaming into the transcript.
  val noOpenRowWhenIdle = phase == "idle" implies tui.open < 0

  // Text from an attempt that retry threw away is never on screen.
  val noSupersededText =
    phase == "idle" implies
      tui.assistantRows().foldl(true, (ok, r) =>
        ok and r.toks.foldl(true, (ok2, k) =>
          ok2 and (finalAttempt.keys().contains(k.turn)
                   implies k.attempt == finalAttempt.get(k.turn))))

  // An assistant row never mixes text from two turns.
  val rowsSingleTurn =
    tui.assistantRows().foldl(true, (ok, r) =>
      ok and r.toks.foldl(true, (ok2, k) => ok2 and k.turn == r.toks[0].turn))

  // Every successful reply is shown exactly as it was persisted.
  val okReplyDisplayed =
    history.foldl(true, (ok, m) =>
      ok and (m.outcome == "ok" implies
        tui.assistantRows().foldl(false, (found, r) => found or r.toks == m.toks)))

  // #574 regression: no hosted tool outlives its turn.
  val noHostedWhenIdle = phase == "idle" implies not(tui.hosted)

  val boundedAttempts = attempt <= MAX_ATTEMPTS

  val allInvariants = and {
    noOpenRowWhenIdle, noSupersededText, rowsSingleTurn, okReplyDisplayed,
    noHostedWhenIdle, boundedAttempts,
  }
}

module current { import network(FIXED = false).* }
module fixed { import network(FIXED = true).* }
