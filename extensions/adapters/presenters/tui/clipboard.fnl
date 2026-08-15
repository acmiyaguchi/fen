;; OSC 52 clipboard export: SGR mouse reporting disables terminal-native copy,
;; and OSC 52 reaches the *local* terminal's clipboard even over SSH/mosh.
;; Hot-reload: RELOADABLE; the only side effect is the injectable M.write!.

(local base64 (require :fen.util.base64))

(local M {})

;; @doc fen.extensions.tui.clipboard.max-bytes
;; kind: data
;; signature: number
;; summary: Maximum pre-encode selection size copied via OSC 52 before the payload is refused, guarding slow terminals and terminal input buffers.
;; tags: tui clipboard osc52 limits
;;
;; 100 KB pre-encode. Many terminals cap the OSC 52 payload (xterm's default
;; is far smaller) and a multi-megabyte paste can wedge slow ARM terminals,
;; so refuse rather than truncate silently past this bound.
(set M.max-bytes 100000)

(fn M.osc52 [text]
  "Return the OSC 52 escape string that sets the system clipboard (selection
   `c`) to `text`, or nil when `text` is empty or exceeds M.max-bytes. The
   sequence is terminated with BEL (\\a), the widely supported OSC terminator."
  (let [s (or text "")]
    (if (or (= s "") (> (length s) M.max-bytes))
        nil
        (.. "\27]52;c;" (base64.encode-standard s) "\a"))))

(fn M.write! [s]
  "Default writer: emit `s` to the terminal. init.fnl uses the same
   io.write + io.flush convention for bracketed-paste escapes. Reassign
   M.write! in tests to capture the payload instead of touching the tty."
  (io.write s)
  (io.flush))

(fn M.copy [text]
  "Copy `text` to the clipboard via OSC 52. Returns a result table:
     {:ok? true  :bytes N}                on success
     {:ok? false :bytes 0 :reason :empty} when there was nothing to copy
     {:ok? false :bytes N :reason :too-large} when over M.max-bytes
     {:ok? false :bytes N :reason :write-error} when the writer threw
   The write goes through M.write! so it is injectable for tests."
  (let [s (or text "")]
    (if (= s "")
        {:ok? false :bytes 0 :reason :empty}
        (> (length s) M.max-bytes)
        {:ok? false :bytes (length s) :reason :too-large}
        (let [seq (M.osc52 s)
              (ok? err) (pcall M.write! seq)]
          (if ok?
              {:ok? true :bytes (length s)}
              {:ok? false :bytes (length s) :reason :write-error
               :error (tostring err)})))))

M
