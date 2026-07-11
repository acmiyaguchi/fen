;; Coroutine construction helpers shared by cooperative runtime work.

(local M {})

;; Keep the opt-in registry outside this reloadable module so active debugger
;; hooks survive source reload. Weak hook keys avoid retaining stopped captures.
(local lua-registry (debug.getregistry))
(local REGISTRY-KEY "fen.util.coroutines.inheritable-hooks")
(when (not (. lua-registry REGISTRY-KEY))
  (tset lua-registry REGISTRY-KEY (setmetatable {} {:__mode :k})))

(fn inheritable-hooks [] (. lua-registry REGISTRY-KEY))

;; @doc fen.util.coroutines.register-inheritable-hook!
;; kind: function
;; signature: (register-inheritable-hook! hook on-create?) -> nil
;; summary: Explicitly allow one debug hook to propagate to fen-owned cooperative child coroutines, optionally observing each child at creation.
;; tags: util coroutine profiler debug
(fn M.register-inheritable-hook! [hook ?on-create]
  (assert (= (type hook) :function) "inheritable debug hook must be a function")
  (tset (inheritable-hooks) hook {:on-create ?on-create}))

;; @doc fen.util.coroutines.unregister-inheritable-hook!
;; kind: function
;; signature: (unregister-inheritable-hook! hook) -> nil
;; summary: Stop propagating a previously registered debug hook to new fen-owned cooperative coroutines.
;; tags: util coroutine profiler debug
(fn M.unregister-inheritable-hook! [hook]
  (when hook (tset (inheritable-hooks) hook nil)))

;; @doc fen.util.coroutines.create
;; kind: function
;; signature: (create fn) -> thread
;; summary: Create a coroutine and propagate only an explicitly registered inheritable debug hook from its caller.
;; tags: util coroutine profiler debug
(fn M.create [f]
  "Create a coroutine, inheriting only debug hooks that opted into fen's
   cooperative-child propagation contract. Ordinary debugger/coverage hooks
   retain Lua's default thread-local behavior."
  (let [(hook mask count) (debug.gethook)
        registration (and hook (. (inheritable-hooks) hook))
        co (coroutine.create f)]
    (when registration
      (debug.sethook co hook mask count)
      (when registration.on-create
        (registration.on-create co)))
    co))

M
