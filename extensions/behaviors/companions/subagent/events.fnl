;; Subagent progress stream and transcript helpers.
;;
;; Children append JSONL records while the parent drains them cooperatively into
;; persistent subagent run state. Event normalization, transport bounds, and
;; draining live in fen.util.wire. Keep this module reloadable; durable identity
;; lives in fen.extensions.subagent.state.

(local json (require :fen.util.json))
(local text (require :fen.util.text))
(local types (require :fen.core.types))
(local wire (require :fen.util.wire))

(local M {})

(fn blank->nil [s]
  (text.blank->nil (tostring (or s ""))))

(fn env-meta []
  {:run-id (blank->nil (os.getenv :FEN_SUBAGENT_RUN_ID))
   :agent (blank->nil (os.getenv :FEN_SUBAGENT_NAME))
   :requested-cwd (blank->nil (os.getenv :FEN_SUBAGENT_REQUESTED_CWD))
   :cwd (blank->nil (os.getenv :FEN_SUBAGENT_CWD))
   :physical-cwd (blank->nil (os.getenv :FEN_SUBAGENT_PHYSICAL_CWD))})

(fn M.append! [path ev]
  "Append EV to the child progress stream at PATH, normalized by fen.util.wire
   with run metadata from the FEN_SUBAGENT_* environment. Returns true, or nil
   plus an error."
  (wire.append! path ev (env-meta)))

;; ----------------------------------------------------------------
;; Canonical transcript sidecar
;; ----------------------------------------------------------------
;;
;; The progress stream above is display-oriented and bounded. Restarts need the
;; child's complete canonical conversation instead, so a child launched with
;; FEN_SUBAGENT_TRANSCRIPT_PATH appends every canonical message as one JSONL
;; line, the parent repairs that file after stopping an attempt, and the next
;; attempt replays it before its steering prompt.

(local INTERRUPTED-TOOL-TEXT
       "[interrupted] The parent stopped this subagent attempt before the tool returned; no result is available.")
(local TRANSCRIPT-YIELD-LINES 64)

(fn maybe-yield-every [n ?yield-fn]
  (when (and ?yield-fn (= 0 (% n TRANSCRIPT-YIELD-LINES)))
    (?yield-fn)))

(fn storable-message [msg]
  "Copy MSG without in-memory `__` metadata fields."
  (let [out {}]
    (each [k v (pairs msg)]
      (when (not= (string.sub (tostring k) 1 2) "__")
        (tset out k v)))
    out))

(fn encode-transcript-message [msg]
  "Encode one canonical message. Presenter-only tool details are dropped when
   they are the only non-encodable part. Returns encoded or nil plus an error."
  (let [m (storable-message msg)
        (ok? encoded) (pcall json.encode m)]
    (if ok?
        (values encoded nil)
        (do
          (set m.details nil)
          (let [(ok2? encoded2) (pcall json.encode m)]
            (if ok2?
                (values encoded2 nil)
                (values nil (tostring encoded2))))))))

(fn write-lines! [path mode lines]
  (let [(f err) (io.open path mode)]
    (if (not f)
        (values nil (tostring err))
        (let [(ok? werr) (pcall #(each [_ line (ipairs lines)]
                                   (assert (f:write line "\n"))))]
          (f:close)
          (if ok? true (values nil (tostring werr)))))))

(fn M.append-transcript-message! [path msg]
  "Append canonical MSG to the transcript at PATH. A message that cannot be
   encoded is recorded as a gap marker so the reader reports partial context
   rather than silently presenting an incomplete conversation as whole.
   Returns true, or nil plus an error."
  (let [(encoded encode-err) (encode-transcript-message msg)
        line (or encoded (json.encode {:transcript-gap (or encode-err "not encodable")}))
        (ok? write-err) (write-lines! path :a [line])]
    (if (not ok?) (values nil write-err)
        encoded true
        (values nil encode-err))))

(fn M.read-transcript [path ?yield-fn]
  "Read canonical messages from the transcript at PATH.

   Returns messages plus stats {:status :ok|:missing :malformed n :gaps n}.
   Malformed lines (for example a record cut short when the child was killed
   mid-write) and gap markers are skipped and counted. ?yield-fn is called
   every few lines; the file handle is closed before any error unwinds."
  (let [(f err) (io.open path :r)]
    (if (not f)
        (values [] {:status :missing :malformed 0 :gaps 0 :error (tostring err)})
        (let [messages []
              stats {:status :ok :malformed 0 :gaps 0}
              (ok? read-err)
              (pcall
                (fn []
                  (var n 0)
                  (each [line (f:lines)]
                    (when (not= line "")
                      (let [(dok? decoded) (pcall json.decode line)]
                        (if (and dok? (= (type decoded) :table) decoded.role)
                            (table.insert messages decoded)
                            (and dok? (= (type decoded) :table) decoded.transcript-gap)
                            (set stats.gaps (+ stats.gaps 1))
                            (set stats.malformed (+ stats.malformed 1)))))
                    (set n (+ n 1))
                    (maybe-yield-every n ?yield-fn))))]
          (f:close)
          (when (not ok?) (error read-err 0))
          (values messages stats)))))

(fn assistant-tool-calls [msg]
  "Tool calls a provider will see for MSG. Error turns are excluded from
   provider context, so their calls need no results."
  (let [out []]
    (when (and (= msg.role :assistant)
               (not= msg.stop-reason :error)
               (= (type msg.content) :table))
      (each [_ block (ipairs msg.content)]
        (when (and (= (type block) :table) (= block.type :tool-call) block.id)
          (table.insert out block))))
    out))

(fn M.repair-transcript [messages ?yield-fn]
  "Return a provider-valid copy of MESSAGES plus repair stats.

   An attempt stopped around a tool call can leave an assistant tool call with
   no result. Each such call gets a synthetic error result placed with its
   group, and tool results that answer no pending call are dropped, so every
   provider sees paired tool-call/tool-result history. ?yield-fn is called
   periodically for large transcripts."
  (let [out []
        stats {:interrupted-tool-calls 0 :orphan-tool-results 0}]
    (var pending nil)
    (var n 0)
    (fn close-pending! []
      (when pending
        (each [_ call (ipairs pending.calls)]
          (when (not (. pending.answered (tostring call.id)))
            (set stats.interrupted-tool-calls (+ stats.interrupted-tool-calls 1))
            (table.insert out (types.tool-result-message
                                {:tool-call-id call.id
                                 :tool-name call.name
                                 :content [(types.text-block INTERRUPTED-TOOL-TEXT)]
                                 :is-error? true
                                 :details {:synthetic? true :interrupted? true}}))))
        (set pending nil)))
    (each [_ m (ipairs (or messages []))]
      (set n (+ n 1))
      (maybe-yield-every n ?yield-fn)
      (if (= m.role :tool-result)
          (let [id (tostring m.tool-call-id)]
            (if (and pending (. pending.ids id) (not (. pending.answered id)))
                (do (tset pending.answered id true)
                    (table.insert out m))
                (set stats.orphan-tool-results (+ stats.orphan-tool-results 1))))
          (do
            (close-pending!)
            (table.insert out m)
            (let [calls (assistant-tool-calls m)]
              (when (> (length calls) 0)
                (let [ids {}]
                  (each [_ call (ipairs calls)]
                    (tset ids (tostring call.id) true))
                  (set pending {:calls calls :ids ids :answered {}})))))))
    (close-pending!)
    (values out stats)))

(fn M.write-transcript! [path messages ?yield-fn]
  "Replace the transcript at PATH with MESSAGES, truncating the existing file
   in place so its private permissions are kept. Returns true, or nil plus an
   error (including when a message cannot be encoded). ?yield-fn is called
   periodically while encoding; the file is only opened after encoding."
  (let [lines []]
    (var err nil)
    (each [i m (ipairs (or messages []))]
      (maybe-yield-every i ?yield-fn)
      (let [(encoded encode-err) (encode-transcript-message m)]
        (if encoded
            (table.insert lines encoded)
            (set err (or err encode-err)))))
    (if err
        (values nil err)
        (write-lines! path :w lines))))

(fn M.truncate-transcript! [path]
  "Empty the transcript at PATH in place, keeping the private temp file's
   inode and permissions rather than removing and recreating a known path."
  (let [f (io.open path :w)]
    (when f (f:close))
    (not (not f))))

(set M.INTERRUPTED-TOOL-TEXT INTERRUPTED-TOOL-TEXT)

M
