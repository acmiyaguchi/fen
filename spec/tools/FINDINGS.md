# Tool execution

Integration model: [`model.qnt`](model.qnt), with witnesses in [`witnesses.qnt`](witnesses.qnt) and mutants in [`mutants.tsv`](mutants.tsv).
Proof models: [`proofs/`](proofs/), one per contract (see [Proof models](#proof-models)).
Scope: tool execution below the agent loop.
Eight small machines run side by side, and each step advances one of them:

- `bash`: the subprocess job. The command leader runs in its own session, plus one more group member that shares the pipe (a backgrounded or nested command). Either one may ignore SIGTERM. The job sends SIGTERM at the deadline, SIGKILL after the grace window, and SIGKILL on cancel, and it finishes on EOF or when the post-exit window ends.
- `popen`: grep, find, and ls cancelled at a yield.
- `write`: chunked write with a yield after each chunk, and the disk may fill.
- `edit`: one file, with two kinds of concurrent writer: another fen process (a sibling subagent's `edit`/`write`), which today's in-process file mutex does not order, and an outside writer (the user's editor, `sed -i` from bash), which takes no fen lock at all.
- `batch`: a multi-file `edit` cancelled between files, or killed (crash, SIGKILL) at any point.
- `out`: bash's tail cap, then the exit tag, then the provider-side scrub/cap.
- `ov`: edit's uniqueness count for `old_string`.
- `disp`: `tools.execute` dispatch covering policy filters, the side-chat narrowing, the subagent child policy, before-tool hooks, and schema validation.

Pairing results with calls, cancel at loop yields, parallel batches, `:tool-choice :none`, and malformed edit args crashing `same-turn-edit-conflicts` are covered in [agent-loop](../agent-loop/FINDINGS.md) and are not repeated here.

Code: `packages/core/src/fen/core/tools.fnl` (`execute`, `check-before-tool`, `scrub-result`), `packages/core/src/fen/core/extensions/register/hook.fnl` (`run-before-tool`), `packages/util/src/fen/util/process/init.fnl` (`start-captured`, `run-captured`, `read-pipe-close`), `packages/util/vendor/fen_process.c`, `packages/util/src/fen/util/text.fnl` (`scrub-tool-text`), `packages/util/src/fen/util/file_mutex.fnl`, `extensions/behaviors/kernel/builtin-tools/{bash,write,edit,grep,find,ls,read,truncate}.fnl`, `packages/fen/src/fen/tool_policy.fnl`, `extensions/adapters/presenters/tui/side_chat.fnl` (`safe-side-opts`), `extensions/behaviors/companions/subagent/init.fnl` (`child-tool-policy`), `packages/core/src/fen/core/agent.fnl` (`parallel-safe-tool-call?`).

All bugs below were first confirmed with one throwaway Busted probe that drove the real registry through `fen.testing.tools` `execute` / `execute-coop`.
Those probes are now kept as `known-bug` tests, one per issue, in `extensions/behaviors/kernel/builtin-tools/tests/issue_<n>_*_test.fnl` (listed under each bug).
They use temp dirs only, kill every process they spawn, and each runs in well under a second.
A probe "cancel" is a `yield-fn` that raises, which is what the agent's `make-yield` does with CANCEL-MARKER.
Candidate fixes are named by issue (`FIXES.contains("657")`); `fixed` enables all of them and `fix<n>` one at a time.

## Input assumptions

What the environment actions of the integration model can and cannot produce:

- bash: one leader and one extra group member; either may ignore SIGTERM. Members never call `setsid()` (those are outside the documented containment). The deadline, grace, and post-exit window are events, not clocks; the model relies only on the post-exit window being shorter than the grace, as in the code (150 ms < 200 ms).
- popen: one child that may or may not exit on its own; cancel is raised only at the read loop's yield.
- write: two chunks; the write may fail (ENOSPC/EIO) on a chunk or on close, chosen at the start. No partial-rename or rename failure is modelled.
- edit: at most `MAX_EXTERNAL = 2` concurrent writes per call, each either a fen-process write or an outside write. In-process coroutine writers are not modelled: the file mutex already orders them (and `subagent` is the only parallel-safe tool, and it runs its children in other processes). Concurrent writers act only while the call is between its read and its commit.
- batch: two files; a crash is the process dying (SIGKILL, OOM, a crash of fen itself). Power loss is out of scope: surviving it would also need `fsync` of the temp before the rename and of the directory after.
- out: three output tokens (ASCII, a 2-byte character, a control byte, or nothing); the integration model has no 3-byte characters (the utf8-tail proof does).
- ov: 4-byte contents over `{a, b}` with `old_string` `aa`.
- disp: every policy kind, name set, path, tool name (plus one unknown), hook outcome, validity, and subagent tool configuration.

## Five guarantees for file writes

An earlier version of this write-up treated "check the file is unchanged, then rename" as one atomic step and said compare-and-rename "also covers writers outside fen".
That was wrong.
Not yielding only keeps other Lua coroutines (and cancel, which is raised at a yield) out of a stretch of code; other processes, including the user's editor and other fen processes, run whenever they like.
A re-read followed by `rename(2)` is not a filesystem compare-and-swap, and several renames are not crash-atomic.
The model now keeps the check and the rename as separate steps, lets both kinds of writer act between them, and separates five guarantees:

| | Guarantee | Today | Candidate fix | Invariant (evidence) |
| --- | --- | --- | --- | --- |
| G1 | Atomic replacement of one file: a reader, or the disk after the process dies, sees the old or the new content, never a prefix | no (#654) | provided by a temp file in the same directory plus one `rename(2)` (#654); a temp whose write or close failed is discarded | `noTornTarget`, `noTornFile` (sampled; inductive in `proofs/file-commit`) |
| G2 | Cancellation shielding: a `[cancelled]` result means nothing changed | no (#656) | provided by never yielding from the commit point to the return, and (batch) staging every file before the first rename (#656) | `cancelledMeansUnchanged`, `batchAllOrNothing` (sampled; inductive in `proofs/file-commit`, `proofs/multi-file-commit`) |
| G3 | Serialization among fen's own writers: no fen `edit`/`write` overwrites another's commit | only between coroutines of one process (the file mutex) | provided by a kernel lock on the path (e.g. `flock` on a lock file) held by every fen `edit`/`write` in every fen process, from the read to the return (#657) | `noLostFenUpdate` (sampled; inductive in `proofs/file-commit`) |
| G4 | Detection of a change made since the file was read | no (#657) | best effort: re-read (or compare size+mtime/hash) just before the rename and fail with "file changed since read". An outside write that lands between the check and the rename is still lost | `outsideLossOnlyInWindow` holds, `noLostUpdate` is violated under `fixed` (counterexample: `w657FixedCheckRenameWindowTest`) |
| G5 | Crash-atomic multi-file commit | no | not provided: the commit is one rename per file, and the process can die between them. It would need a commit record replayed at startup | `batchCrashAtomic` is violated under `fixed` (counterexample: `w656FixedCrashBetweenRenamesTest`) |

So the `fixed` instance's `allInvariants` contains G1–G4 and not `noLostUpdate` or `batchCrashAtomic`; those two stay `violated` rows of `fixed`, recording what the fix does not provide.
The mutants check that each part is load-bearing: dropping the re-check breaks `outsideLossOnlyInWindow`, dropping the kernel lock breaks `noLostFenUpdate` (a sibling fen write lands in the check/rename window), and a yield between the renames breaks `batchAllOrNothing`.
Bash commands are outside writers even when fen runs them: `sed -i` in a sibling subagent takes no fen lock, so for it only G4's best-effort detection applies.

## What holds

These stay as regression properties.

Evidence: sampled in the integration model, and bounded-safe over every input in `proofs/dispatch` (the initial states are all inputs, so the bound is exhaustive).

- `deniedUnreachable`: a tool outside the parent policy is unreachable on every modelled path.
  The paths are a direct call by any name (including an unknown one), the side chat (`narrow` over `read,grep,find,ls`), and a subagent child (`child-tool-policy` never widens).
  `agent.tools` is the filtered list itself.
  `tool_search` only searches `agent.tools`, and every agent rebuild (`/model`, `/thinking`, handoff, session) goes back through `make-agent-from-opts`, which re-applies the policy.
- `hookVetoFinal`: a before-tool hook that blocks always prevents execution, and so does a hook that throws (`run-before-tool` fails closed).
- `validatedBeforeEffect`: `tools.execute` runs restriction, then hooks, then schema validation, and only then `execute`.
- `killOnlyOnAbnormalEnd`: SIGKILL is sent only on timeout or cancel, and never after the leader is reaped, so a recycled pid is never signalled.
  Inductive for today's code (`proofs/process-group`, `current.killInductiveInv`).
- Not modelled, checked by reading the code: a reload while a tool runs.
  Hook unregister and register is synchronous, with no yield between them.
  A running tool keeps its old closures.
  File-mutex state and coroutine hooks live in non-reloadable state modules.
  No hazard was found.

## Bugs

### #651: A timed-out bash call leaves a live process in its own process group

**Fixed in #605: `process.run` signals the whole process group once on timeout or cancel, then reaps with a bounded wait (`fen_process.c` gained the group signal; `util/process/init.fnl`).**

Evidence: counterexample (`w651TermIgnoringMemberSurvivesTest`; in `proofs/process-group` also `w651CancelAfterReapMissesMemberTest`); confirmed by `issue_651_group_member_survives_test.fnl` (both the timeout and the cancel-after-reap paths, with a 0.2 s process timeout).

Counterexample (`noLiveProcessAfterAbnormalEnd`): `bStart(memberIgnoresTerm) → bDeadline → bFinish`.
At the deadline, `tick!` sends SIGTERM to the group.
The leader dies of it, but a group member that ignores TERM survives.
SIGKILL escalation is gated on `(not reaped?)`, and `abort!` → `send-kill!` has the same gate.
The post-exit drain window (150 ms) is also shorter than the kill grace (200 ms).
So once the leader is reaped, the job closes the pipe and returns `[timeout: process group signaled after 1s]`, and the TERM-ignoring member keeps running in fen's own group.
The member has not escaped with `setsid()`, so this is inside the containment that `docs/tools.md` promises.
A cancel that lands in the post-exit window misses the member in the same way.

Probe:

```
bash {:cmd "sh -c 'trap \"\" TERM; echo $$ > PID; exec sleep 30' & wait" :timeout 1}
K1 timed-out?= true signal= 15 ms= 1174 member pid= 245166 alive after return= true
```

### #652: The provider-side cap drops bash's exit/timeout tag

**Fixed in #605: bash keeps the exit/timeout tag when the cap cuts the output (`bash.fnl`, `util.fnl`).**

Evidence: counterexample (`w652ExitTagCutTest`, here and in `proofs/output-envelope`); confirmed by `issue_652_exit_tag_cut_test.fnl`.

Counterexample (`exitStatusVisible`): `oRun` with raw `[L C x a]`.
After trimming and appending the tag, the sanitized size is over the cap.
Bash caps output at 50 KB and appends `[exit N]` / `[timeout …]` as the last line.
`scrub-result` then escapes every control or invalid byte as a 4-byte `\xNN` and keeps the head up to `FEN_TOOL_RESULT_MAX_BYTES` (64 KiB).
Binary-ish output (or a lowered env cap) pushes the sanitized text over the cap, and the trailing status line is cut.
The model then sees no exit status.
It is only in `details`, which providers never receive.

```
bash {:cmd "head -c 30000 /dev/zero | tr '\\000' '\\001'; exit 7"}
K2 details.exit-code= 7 is-error?= true content bytes= 65661 has [exit 7]= false
   tail= …tput sanitized: 30000 unsafe bytes escaped]
         [fen: tool output truncated: kept 65536 of 120009 sanitized bytes]
```

### #653: Bash's tail cap starts the output inside a UTF-8 character

**Fixed in #605: the tail cap skips every leading continuation byte (`util/process`, truncation).**

Evidence: counterexample (`w653TailStartsMidCharTest`; `proofs/utf8-tail` adds `w653TwoOrphansTest` for 3-byte characters); confirmed by `issue_653_tail_splits_char_test.fnl`.

Counterexample (`noSplitChar`): raw `[L C L C]` trims to `[C L C]`.
`trim-tail` does `(string.sub out (- max-bytes))`, which counts bytes, not characters.
The orphaned continuation byte is escaped by the scrubber, which also adds a misleading "sanitized" note.

```
bash {:cmd "yes é | head -n 30000 | tr -d '\\n'; echo"}
K3 head of body= \xA9éééé sanitized note= true
```

### #654: Cancelling `write` mid-file leaves a torn file, and the original is lost

**Fixed in #605: `write` stages into a temp file in the same directory and renames (`commit.fnl`, `write.fnl`).**

Evidence: counterexample (`w654CancelLeavesTornFileTest`, `w654ReaderSeesPrefixTest`; `proofs/file-commit` `w654FirstChunkTearsTargetTest`); confirmed by `issue_654_cancel_tears_write_test.fnl`.

Counterexample (`noTornFile`): `wStart → wChunk1 → wCancel`.
`write` truncates the target with `io.open path :w`, then writes 16 KiB chunks with a yield after each one.
A cancel at a chunk yield unwinds through the `xpcall`, which closes the file and re-raises.

```
original "ORIGINAL CONTENT\n"; write 40000 bytes; yield-fn raises on its 4th call
K4 ok?= false err= …file_mutex… file bytes= 32768 original kept= false
```

### #655: `write` (and `edit`) report success when the write fails

**Fixed in #605: the write is checked and a failure is reported as an error, and the temp file is removed.**

Evidence: counterexample (`w655FailedWriteReportsOkTest`, here and in `proofs/file-commit`); confirmed by `issue_655_write_error_reported_ok_test.fnl` (Linux `/dev/full`). The `edit` half is confirmed by line trace only: `edit` must read the file first, and `/dev/full` reads as endless zeros.

Counterexample (`okMeansWritten`): `wStart(ioErr) → wChunk1 → wChunk2 → wClose → wReturn`.
`write-content` ignores what `f:write` returns, and both tools ignore what `f:close` returns.
`edit`'s `write-edit-file` follows the same pattern, checked by reading the code.
On ENOSPC or EIO the target is left truncated, and the tool says it succeeded.

```
write {:path "/dev/full" :content (100 bytes)}
K5 is-error?= false text= wrote 100 bytes to /dev/full
```

### #656: A cancelled multi-file `edit` applies some files and reports "cancelled"

**Fixed in #605: `edit` stages every file and renames with no yield between files or between commit and return (cancel-atomic, not crash-atomic: `batchCrashAtomic` stays violated).**

Evidence: counterexample (`w656BatchCancelBetweenFilesTest`, `w656CancelAfterCommitTest`; `proofs/multi-file-commit` `w656CancelBetweenFilesTest`; `proofs/file-commit` `w656CancelAfterCommitTest`); confirmed by `issue_656_cancel_after_commit_test.fnl` (both the batch and the single-file case).

Counterexamples: `batchAllOrNothing` is `bfStart → bfWriteA → bfCancel`, and `cancelledMeansUnchanged` is also violated, for example by `eStart → eWrite → eCancel` or by a `wCancel` after `wClose`.
This is guarantee G2 (cancellation shielding); see [Five guarantees](#five-guarantees-for-file-writes).
The batch is validated all-or-nothing, but files are then written one per lock, with yields between them.
A cancel between files leaves earlier files changed.
The tool description admits this only for "a rare write failure", but cancel lands at every yield.
More generally, `edit` and `write` both yield *after* their commit point.
A cancel there turns a completed mutation into a `[cancelled]` tool result.
The model is told nothing changed, so it may retry and hit `old_string not found`.
The fix makes the batch atomic with respect to cancel, not to a crash (G5): `fixed.batchCrashAtomic` stays violated.

```
files [{a foo→bar} {b foo→bar}]; yield-fn raises once a == "bar\n"
K6 ok?= false err= CANCEL a= bar  b= foo
```

### #657: `edit` overwrites changes made while it yielded (lost update)

**Fixed in #605 (mitigated): a per-path `file_mutex` across fen processes plus a re-check before the rename; `noLostUpdate` stays violated for an outside writer in the check/rename window.**

Evidence: counterexample (`w657OutsideWriteRevertedTest`, `w657FenWriteRevertedTest`, here and in `proofs/file-commit`); confirmed by `issue_657_edit_lost_update_test.fnl`, which writes the file from the edit's first yield. A second OS process racing the edit is the real-world shape; the yield-time write is the closest deterministic stand-in and exercises the same code path (no re-read before the write).

Counterexamples: `noLostUpdate` and `outsideLossOnlyInWindow` by `eStart → eOutsideWrite → eWrite`, and `noLostFenUpdate` by `eStart → eFenWrite → eWrite`.
`edit` reads a snapshot and then yields several times: after the read, during validation, and before it opens the file for writing.
It then writes `apply-edits(snapshot)` without re-reading.
The file mutex only orders `edit` and `write` in this process.
Anything else that writes the file during those yields is silently reverted: a `bash` `sed -i` or a `write` in a sibling subagent, or the user's editor.
`subagent` is the one tool marked `:parallel-safe?`, and its children run `bash`, `edit`, and `write` in separate processes, so two subagents in one batch are exactly this interleaving.
Two guarantees are missing here, and they need different fixes: serialization among fen's own writers (G3) and detection of other writers' changes (G4).

```
file "x = 1\ny = 2\n"; edit x = 1 → x = 10; first yield appends "z = 3\n"
K7 is-error?= false text= applied 1 edit(s) to …/f final= "x = 10\ny = 2\n"
```

### #658: `edit` accepts an `old_string` that occurs twice when the occurrences overlap

**Fixed in #605: `edit` counts overlapping matches (`edit.fnl`).**

Evidence: counterexample (`w658OverlapCountedOnceTest`; `proofs/edit-unique` adds `w658OverlapLongerPatternTest`); confirmed by `issue_658_overlapping_match_test.fnl`.

Counterexample (`uniqueMatchIsUnique`): content `aaab`, `old_string` `aa`. `find-all` finds 1 hit, but there are 2.
`find-all` resumes the search at `pos + #old`, so overlapping occurrences are not counted.
The edit is applied at the first one instead of returning "not unique" with match sites.
This is realistic with repeated closing lines such as `}\n}`.
pi-mono counts with `split`, which is also non-overlapping, so the port inherited this bug.

```
file "}\n}\n}\n"; edit "}\n}" → "X"
K8 is-error?= false text= applied 1 edit(s) to …/f final= "X\n}\n"
```

### #659: A cancelled `grep`/`find`/`ls` freezes the whole process until the child exits

**Fixed in #605: cancelling `grep`/`find`/`ls` kills the child and does not block on `pclose` (`util/process`, `grep.fnl`, `find.fnl`, `ls.fnl`).**

Evidence: counterexample (`w659CancelBlocksInPcloseTest`, here and in `proofs/popen-cancel`); confirmed by `issue_659_cancel_blocks_in_pclose_test.fnl` (a FIFO writer after 300 ms; the probe kills the writer afterwards).

Counterexample (`noUnboundedBlockingWait`): `pStart → pCancel`.
These tools use `io.popen` and `read-pipe-close`.
On a cancel raised at a yield, `read-pipe-close` calls `pipe:close()`, which is `pclose`, which waits for the shell.
Nothing kills the child, and the wait does not yield, so the presenter and every other coroutine stall.
A silent `grep -r` or `find /` can take minutes.
These tools also have no timeout.

```
grep {:pattern "x" :path FIFO}; a writer opens the FIFO after 2 s; yield-fn raises on first call
K9 ok?= false yields= 1 ms blocked in cancel= 2003
```

## Candidate fixes (named; all of them are `fixed`)

- #651: on timeout or cancel, SIGKILL the group whether or not the leader has been reaped, before closing the pipe.
  `kill(-pgid)` is safe while any member lives, because the pgid cannot be reused until the group is empty.
  Do this as well as, or instead of, making the post-exit window longer than the grace.
- #652: the provider cap reserves the result's trailer (the exit/timeout tag).
  Alternatively, bash budgets its tail in *sanitized* bytes, or puts the status first.
- #653: after the byte cut, skip *all* leading continuation bytes (`[\x80-\xBF]*`, up to 3).
  Skipping only one is enough for 2-byte characters but not 3-byte ones (`proofs/utf8-tail` mutant).
- #654 (G1): write to a temp file in the same directory and `os.rename` it over the target; discard a temp whose write or close failed.
  For power loss as well as process death, `fsync` the temp before the rename.
- #655: check every `write` and `close` result, and report an error, not ok, on failure.
- #656 (G2): stage every file of a batch to a temp file, then rename them all with no yield in between; more generally, never yield between a tool's commit point and its return.
  This is cancel-atomic, not crash-atomic (G5 is not provided).
- #657 (G3 and G4): every fen `edit`/`write` takes a kernel lock on the path (in every fen process) from the read to the return; and just before the rename, re-read (or compare size+mtime/hash) and fail with "file changed since read" if it differs.
  The lock covers fen's own writers only; the check covers everyone else on a best-effort basis, with a window between the check and the rename that only a filesystem compare-and-swap could close.
- #658: resume `find-all` at `pos + 1`.
- #659: run grep/find/ls through `process.start-captured` with `:argv`.
  Its abort SIGKILLs the group and its cleanup is bounded.
  This also gets them a timeout and lets the `io.popen` drain helpers be deleted.

Under `fixed`, `allInvariants` holds (sampled); `noLostUpdate` (#657) and `batchCrashAtomic` (#656) stay violated, as the table above explains.
Each `fix<n>` instance makes its own issue's invariant hold on its own (sampled rows in `checks.tsv`).

## Proof models

Each contract has a small proof model under `proofs/<name>/` with its own `checks.tsv`, `verify.tsv`, witnesses, and mutants.
They model the target design (`fixed`) and today's design (`current`), so each bug is also a counterexample there.
Measured with `SPEC_VERIFY_JOBS=1 JVM_ARGS=-Xmx3g` on a loaded machine (load average around 20); the whole set takes about 17 s.

| Proof | Contract (issues) | Obligation | Result | Time |
| --- | --- | --- | --- | --- |
| [`process-group`](proofs/process-group/model.qnt) | bash group kill on timeout/cancel (#651) | `fixed.inductiveInv` | inductive | 1 s |
| | | `current.killInductiveInv` (SIGKILL only on timeout/cancel, today) | inductive | 1 s |
| [`output-envelope`](proofs/output-envelope/model.qnt) | result cap keeps the trailer (#652) | `fixed`: `exitStatusVisible withinLimit trailerLast fitsSentWhole` | bounded-safe, 2 steps (exhaustive: one-shot) | 0 s |
| [`utf8-tail`](proofs/utf8-tail/model.qnt) | tail cut on a character boundary, 1–3 byte characters (#653) | `fixed`: `noSplitChar withinCap dropsLessThanAChar` | bounded-safe, 2 steps (exhaustive) | 1 s |
| [`file-commit`](proofs/file-commit/model.qnt) | one-file write/edit commit, G1–G4 (#654, #655, #656, #657) | `fixed.inductiveInv` | inductive | 2 s |
| | | `fixed.guarantees` | bounded-safe, 10 steps (every run ends within 8) | 1 s |
| [`multi-file-commit`](proofs/multi-file-commit/model.qnt) | batch cancel-atomicity, G2; G5 not provided (#656) | `fixed.inductiveInv` | inductive | 1 s |
| [`edit-unique`](proofs/edit-unique/model.qnt) | `old_string` uniqueness count over all 6-byte contents and three patterns (#658) | `fixed`: `uniqueMatchIsUnique countIsExact`; `current.countNeverOver` | bounded-safe, 2 steps (exhaustive) | 2 s, 1 s |
| [`popen-cancel`](proofs/popen-cancel/model.qnt) | grep/find/ls cancel never waits on an unkilled child (#659) | `fixed.inductiveInv` | inductive | 1 s |
| [`dispatch`](proofs/dispatch/model.qnt) | policy → hook → validate → execute, side chat, subagent child policy | `current`: `deniedUnreachable hookVetoFinal validatedBeforeEffect sideChatReadOnly` | bounded-safe, 2 steps (the initial states are every input) | 2 s |

The proof models restate the integration model's rules in Apalache-friendly form (scalar variables, constant-bound folds) rather than importing them, so they can drift from it; the bug witnesses replay the same counterexample shapes in both, which is the only cross-check today.
`noUnboundedBlockingWait` is a per-state safety property (no wait on an *unkilled* child); it says nothing about how long a killed child takes to exit, which would be a liveness claim.

## Open questions

- A subagent child is SIGKILLed as a process group (`job.handle:abort`), but the child's own bash commands run under `setsid` in *their own* sessions.
  A hard-killed subagent therefore cannot reap a running bash grandchild, and a silent one (`sleep`, a server) outlives the cancel.
  The graceful `cancel` control normally lets the child clean up first, so this needs a real child run to confirm the kill-after-grace path.
- With no timeout, a background `&` process that keeps the pipe open is abandoned after the 150 ms post-exit window and keeps running.
  That is presumably intended (servers), but it is not written down.
- `write` runs `mkdir -p` on the parent before `io.open`, so a write that then fails (ENAMETOOLONG, EISDIR) still leaves new directories behind.
- `check-before-tool` hands hooks a *shallow* copy of the arguments.
  A hook can still mutate nested tables (`edits`, `files`) that `execute` then uses.
- The mutex treats the main thread as owner `nil`, so a synchronous main-thread mutation looks "unlocked" to a concurrent coroutine.
  No caller that does this was found.

## Core

Tool execution needs three primitives.
1. **Process job**: spawn argv in a fresh group; give it a bounded non-blocking `resume`; a terminal `abort` that SIGKILLs the group regardless of who has been reaped. Every tool that runs a program uses it.
2. **File commit**: a kernel lock per path held by every fen writer (G3); write a temp, check every write and close, re-check the file against the snapshot, and rename the temp over it with no yield from the check to the return (G1, G2, best-effort G4).
   It is not compare-and-swap (an outside write between check and rename is lost), and a multi-file commit is cancel-atomic, not crash-atomic.
3. **Result envelope**: a status trailer that truncation can never cut.

On top of these, the ordering already in `tools.execute` (policy → hook → validate → run) is sound and should stay as it is.
What could go: `read-pipe-coop` / `read-pipe-close` and every `io.popen` in grep/find/ls (replaced by the job), the per-path in-process FIFO mutex for edit/write (subsumed by the cross-process kernel lock, which orders fen's own writers only; writers outside fen are covered by the best-effort re-check alone), the separate `truncate.fnl` spill writer next to the process spill, and the yields placed after commit points.
