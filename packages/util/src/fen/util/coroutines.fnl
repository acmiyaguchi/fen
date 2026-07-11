;; Coroutine construction helpers shared by cooperative runtime work.

(local M {})

;; @doc fen.util.coroutines.create
;; kind: function
;; signature: (create fn) -> thread
;; summary: Create a coroutine and propagate the caller's active debug hook so opt-in profilers and debuggers observe cooperative child work.
;; tags: util coroutine profiler debug
(fn M.create [f]
  "Create a coroutine that inherits the current thread's debug hook.

   Lua does not propagate hooks to new coroutines. Copying the active hook here
   keeps cooperative turns, reloads, and tool tasks visible to an opt-in
   profiler without coupling their owners to a profiler extension. With no
   active hook this is equivalent to coroutine.create."
  (let [(hook mask count) (debug.gethook)
        co (coroutine.create f)]
    (when hook
      (debug.sethook co hook mask count))
    co))

M
