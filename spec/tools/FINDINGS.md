# Tool execution

Model: [`model.qnt`](model.qnt).
Scope: tool execution below the agent loop.
Eight small machines run side by side, and each step advances one of them:

- `bash`: the subprocess job. The command leader runs in its own session, plus one more group member that shares the pipe (a backgrounded or nested command). Either one may ignore SIGTERM. The job sends SIGTERM at the deadline, SIGKILL after the grace window, and SIGKILL on cancel, and it finishes on EOF or when the post-exit window ends.
- `popen`: grep, find, and ls cancelled at a yield.
- `write`: chunked write with a yield after each chunk, and the disk may fill.
- `edit`: one file, with outside writers that skip fen's file mutex.
- `batch`: a multi-file `edit` cancelled between files.
- `out`: bash's tail cap, then the exit tag, then the provider-side scrub/cap.
- `ov`: edit's uniqueness count for `old_string`.
- `disp`: `tools.execute` dispatch covering policy filters, the side-chat narrowing, the subagent child policy, before-tool hooks, and schema validation.

Pairing results with calls, cancel at loop yields, parallel batches, `:tool-choice :none`, and malformed edit args crashing `same-turn-edit-conflicts` are covered in [agent-loop](../agent-loop/FINDINGS.md) and are not repeated here.

Code: `packages/core/src/fen/core/tools.fnl` (`execute`, `check-before-tool`, `scrub-result`), `packages/core/src/fen/core/extensions/register/hook.fnl` (`run-before-tool`), `packages/util/src/fen/util/process/init.fnl` (`start-captured`, `run-captured`, `read-pipe-close`), `packages/util/vendor/fen_process.c`, `packages/util/src/fen/util/text.fnl` (`scrub-tool-text`), `packages/util/src/fen/util/file_mutex.fnl`, `extensions/behaviors/kernel/builtin-tools/{bash,write,edit,grep,find,ls,read,truncate}.fnl`, `packages/fen/src/fen/tool_policy.fnl`, `extensions/adapters/presenters/tui/side_chat.fnl` (`safe-side-opts`), `extensions/behaviors/companions/subagent/init.fnl` (`child-tool-policy`), `packages/core/src/fen/core/agent.fnl` (`parallel-safe-tool-call?`).

All bugs below were confirmed with one throwaway Busted probe, `extensions/behaviors/kernel/builtin-tools/tests/zz_probe_tools_all_test.fnl`, which drove the real registry through `fen.testing.tools` `execute` / `execute-coop`.
It used temp dirs only, killed the process it leaked, and was deleted afterwards.
A probe "cancel" is a `yield-fn` that raises, which is what the agent's `make-yield` does with CANCEL-MARKER.

## What holds

These stay as regression properties.

- `deniedUnreachable`: a tool outside the parent policy is unreachable on every modelled path.
  The paths are a direct call by any name (including an unknown one), the side chat (`narrow` over `read,grep,find,ls`), and a subagent child (`child-tool-policy` never widens).
  `agent.tools` is the filtered list itself.
  `tool_search` only searches `agent.tools`, and every agent rebuild (`/model`, `/thinking`, handoff, session) goes back through `make-agent-from-opts`, which re-applies the policy.
- `hookVetoFinal`: a before-tool hook that blocks always prevents execution, and so does a hook that throws (`run-before-tool` fails closed).
- `validatedBeforeEffect`: `tools.execute` runs restriction, then hooks, then schema validation, and only then `execute`.
- `killOnlyOnAbnormalEnd`: SIGKILL is sent only on timeout or cancel, and never after the leader is reaped, so a recycled pid is never signalled.
- Not modelled, checked by reading the code: a reload while a tool runs.
  Hook unregister and register is synchronous, with no yield between them.
  A running tool keeps its old closures.
  File-mutex state and coroutine hooks live in non-reloadable state modules.
  No hazard was found.

## Bugs

### #651: A timed-out bash call leaves a live process in its own process group

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

Counterexample (`noSplitChar`): raw `[L C L C]` trims to `[C L C]`.
`trim-tail` does `(string.sub out (- max-bytes))`, which counts bytes, not characters.
The orphaned continuation byte is escaped by the scrubber, which also adds a misleading "sanitized" note.

```
bash {:cmd "yes é | head -n 30000 | tr -d '\\n'; echo"}
K3 head of body= \xA9éééé sanitized note= true
```

### #654: Cancelling `write` mid-file leaves a torn file, and the original is lost

Counterexample (`noTornFile`): `wStart → wChunk1 → wCancel`.
`write` truncates the target with `io.open path :w`, then writes 16 KiB chunks with a yield after each one.
A cancel at a chunk yield unwinds through the `xpcall`, which closes the file and re-raises.

```
original "ORIGINAL CONTENT\n"; write 40000 bytes; yield-fn raises on its 4th call
K4 ok?= false err= …file_mutex… file bytes= 32768 original kept= false
```

### #655: `write` (and `edit`) report success when the write fails

Counterexample (`okMeansWritten`): `wStart(ioErr) → wChunk1 → wChunk2 → wClose → wReturn`.
`write-content` ignores what `f:write` returns, and both tools ignore what `f:close` returns.
`edit`'s `write-edit-file` follows the same pattern, checked by reading the code.
On ENOSPC or EIO the target is left truncated, and the tool says it succeeded.

```
write {:path "/dev/full" :content (100 bytes)}
K5 is-error?= false text= wrote 100 bytes to /dev/full
```

### #656: A cancelled multi-file `edit` applies some files and reports "cancelled"

Counterexamples: `batchAllOrNothing` is `bfStart → bfWriteA → bfCancel`, and `cancelledMeansUnchanged` is also violated, for example by `eStart → eWrite → eCancel` or by a `wCancel` after `wClose`.
The batch is validated all-or-nothing, but files are then written one per lock, with yields between them.
A cancel between files leaves earlier files changed.
The tool description admits this only for "a rare write failure", but cancel lands at every yield.
More generally, `edit` and `write` both yield *after* their commit point.
A cancel there turns a completed mutation into a `[cancelled]` tool result.
The model is told nothing changed, so it may retry and hit `old_string not found`.

```
files [{a foo→bar} {b foo→bar}]; yield-fn raises once a == "bar\n"
K6 ok?= false err= CANCEL a= bar  b= foo
```

### #657: `edit` overwrites changes made while it yielded (lost update)

Counterexample (`noLostUpdate`): `eStart → eExternalWrite → eWrite`.
`edit` reads a snapshot and then yields several times: after the read, during validation, and before it opens the file for writing.
It then writes `apply-edits(snapshot)` without re-reading.
The file mutex only orders `edit` and `write` in this process.
Anything else that writes the file during those yields is silently reverted: a `bash` `sed -i` or a `write` in a sibling subagent, or the user's editor.
`subagent` is the one tool marked `:parallel-safe?`, and its children run `bash`, `edit`, and `write`, so two subagents in one batch are exactly this interleaving.

```
file "x = 1\ny = 2\n"; edit x = 1 → x = 10; first yield appends "z = 3\n"
K7 is-error?= false text= applied 1 edit(s) to …/f final= "x = 10\ny = 2\n"
```

### #658: `edit` accepts an `old_string` that occurs twice when the occurrences overlap

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

## Candidate fix (modelled as `fixed`)

- #651: on timeout or cancel, SIGKILL the group whether or not the leader has been reaped, before closing the pipe.
  `kill(-pgid)` is safe while any member lives, because the pgid cannot be reused until the group is empty.
  Do this as well as, or instead of, making the post-exit window longer than the grace.
- #652: the provider cap reserves the result's trailer (the exit/timeout tag).
  Alternatively, bash budgets its tail in *sanitized* bytes, or puts the status first.
- #653: after the byte cut, skip leading continuation bytes (`[\x80-\xBF]`).
- #654/#655: write to a temp file in the same directory and check each `write` and `close` result, then `os.rename` it over the target.
  Report an error, not ok, on failure.
- #656: stage every file of a batch to a temp file, then commit them all (renames) in one non-yielding step.
  More generally, never yield between a tool's commit point and its return.
- #657: in the same non-yielding step as the write, re-read the file (or compare size+mtime/hash) and fail with "file changed since read" if it differs.
- #658: resume `find-all` at `pos + 1`.
- #659: run grep/find/ls through `process.start-captured` with `:argv`.
  Its abort SIGKILLs the group and its cleanup is bounded.
  This also gets them a timeout and lets the `io.popen` drain helpers be deleted.

All invariants hold under `fixed` (`fixed.allInvariants`).

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
2. **Atomic file commit**: read a snapshot, compute, then in one non-yielding step check that the file is unchanged and rename a checked temp file over it.
3. **Result envelope**: a status trailer that truncation can never cut.

On top of these, the ordering already in `tools.execute` (policy → hook → validate → run) is sound and should stay as it is.
What could go: `read-pipe-coop` / `read-pipe-close` and every `io.popen` in grep/find/ls (replaced by the job), the per-path FIFO mutex for edit/write (replaced by compare-and-rename, which also covers writers outside fen), the separate `truncate.fnl` spill writer next to the process spill, and the yields placed after commit points.
