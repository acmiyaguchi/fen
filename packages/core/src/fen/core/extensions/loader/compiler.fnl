;; One-shot compiler worker for development-overlay core reloads.
;;
;; This deliberately has no cache or persistent worker.  The parent resolves
;; concrete .fnl files, the child compiles the whole batch, and only a complete
;; successful response is eligible for application in the long-lived VM.

(local process (require :fen.util.process))
(local runtime (require :fen.runtime))

(local M {})

;; Keep the worker self-contained so `fen eval` needs no temporary script.
;; Records are length-framed because generated Lua can contain arbitrary bytes.
(local WORKER
"local fennel=require('fennel')
local function read(path) local f,err=io.open(path,'rb'); assert(f,err); local s=f:read('*a'); f:close(); return s end
for i=1,#arg,2 do
  local mod,path=arg[i],arg[i+1]
  local ok,lua=pcall(fennel.compileString,read(path),{filename=path})
  if not ok then io.stderr:write(path..': '..tostring(lua)..'\\n'); os.exit(1) end
  io.write('FEN-COMPILE\\t',#mod,'\\t',#path,'\\t',#lua,'\\n',mod,path,lua)
end")

(fn parse-output [text expected]
  (let [out {}
        n (length text)]
    (var pos 1)
    (while (<= pos n)
      (let [newline (string.find text "\n" pos true)]
        (when (not newline) (error "compiler worker returned an incomplete header"))
        (let [header (string.sub text pos (- newline 1))
              (ml pl ll) (string.match header "^FEN%-COMPILE\t(%d+)\t(%d+)\t(%d+)$")
              _header (when (not ml) (error "compiler worker returned an invalid header"))
              mod-len (tonumber ml)
              path-len (tonumber pl)
              lua-len (tonumber ll)
              body-start (+ newline 1)
              mod-end (+ body-start mod-len -1)
              path-start (+ mod-end 1)
              path-end (+ path-start path-len -1)
              lua-start (+ path-end 1)
              lua-end (+ lua-start lua-len -1)]
          (when (> lua-end n) (error "compiler worker returned a truncated record"))
          (let [mod (string.sub text body-start mod-end)
                path (string.sub text path-start path-end)
                compiled-lua (string.sub text lua-start lua-end)]
            (when (or (not (. expected mod))
                      (not= (. expected mod) path))
              (error (.. "compiler worker returned an unexpected module " mod)))
            (when (. out mod) (error (.. "compiler worker returned duplicate module " mod)))
            (tset out mod {:module mod :path path :lua compiled-lua})
            (set pos (+ lua-end 1))))))
    out))

;; @doc fen.core.extensions.loader.compiler.compile!
;; kind: function
;; signature: (compile! candidates yield!) -> CompilerBatch
;; summary: Cooperatively run one fresh fen compiler subprocess for concrete development-overlay Fennel files, returning all generated Lua only when the complete batch succeeds.
;; tags: extensions reload compiler cooperative
(fn M.compile! [candidates ?yield!]
  "Candidates are ordered {:module :path} records. Unsupported when this
   process cannot identify its own executable; callers retain normal require
   fallback in that case. A nonzero worker exit is a batch failure, never a
   partial result."
  (if (= (length (or candidates [])) 0)
      {:status :ok :outputs {} :duration-ms 0}
      (let [binary (runtime.binary-path)]
        (if (not binary)
            {:status :unsupported :reason "fen executable unavailable"}
            (let [argv [binary :eval WORKER]
                  expected {}]
              (each [_ candidate (ipairs candidates)]
                (table.insert argv candidate.module)
                (table.insert argv candidate.path)
                (tset expected candidate.module candidate.path))
              ;; Keep process failures as batch failures, but do not let this
              ;; classification boundary consume cooperative control flow.
              ;; `run-captured` already aborts/reaps before rethrowing a
              ;; yield error; mark errors originating in the callback so they
              ;; can continue to the caller unchanged.
              (let [started (process.monotonic-ms)
                    yield-error {}
                    (ok? result-or-err)
                    (pcall process.run-captured
                           {:argv argv :max-bytes (* 16 1024 1024)
                            :max-lines 100000 :spill? false}
                           (fn []
                             (when ?yield!
                               (let [(yield-ok? yield-result)
                                     (pcall ?yield! {:phase :compiler-poll})]
                                 (when (not yield-ok?)
                                   (tset yield-error :value yield-result)
                                   (error yield-error))))))
                    elapsed (- (process.monotonic-ms) started)]
                (if (and (not ok?) (= result-or-err yield-error))
                    (error yield-error.value)
                    (if (not ok?)
                        {:status :failed :duration-ms elapsed
                         :error (tostring result-or-err)}
                    (let [result result-or-err]
                      (if (or result.cancelled? result.timed-out?
                              (not= result.exit-code 0))
                          {:status :failed :duration-ms elapsed
                           :error (or result.output "compiler worker failed")
                           :cancelled? result.cancelled?
                           :timed-out? result.timed-out?}
                          (let [(parsed? parsed-or-err)
                                (pcall parse-output result.output expected)]
                            (if (not parsed?)
                                {:status :failed :duration-ms elapsed
                                 :error (tostring parsed-or-err)}
                                (let [outputs parsed-or-err
                                      missing (accumulate [name nil _ candidate (ipairs candidates)]
                                                (or name
                                                    (and (not (. outputs candidate.module))
                                                         candidate.module)))]
                                  (if missing
                                      {:status :failed :duration-ms elapsed
                                       :error (.. "compiler worker omitted " missing)}
                                      {:status :ok :outputs outputs
                                       :duration-ms elapsed}))))))))))))))

M
