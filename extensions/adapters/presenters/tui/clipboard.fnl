;; OSC 52 clipboard export for the TUI.
;;
;; The terminal-native "select with the mouse to copy" path stops working
;; once we enable SGR mouse reporting for wheel scrolling (the terminal
;; forwards click-drag to fen instead of selecting text). Rather than force
;; users to choose, fen owns selection itself (selection.fnl) and copies the
;; selected text to the system clipboard with the OSC 52 escape sequence:
;;
;;     ESC ] 52 ; c ; <base64 payload> BEL
;;
;; OSC 52 is the right primitive for our targets (foot locally, and SSH/mosh
;; into Blink on iOS) because the escape travels from the remote process out
;; to the *local* terminal, which then updates the local clipboard — no
;; remote clipboard daemon or X/Wayland forwarding required.
;;
;; Hot-reload note: RELOADABLE. Pure string building plus one injectable
;; writer (M.write!) so tests can capture output without a real terminal and
;; so init.fnl's io.write path stays the single place that talks to the tty.

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

;; @doc fen.extensions.tui.clipboard.osc52
;; kind: function
;; signature: (osc52 text) -> string|nil
;; summary: Build the OSC 52 set-clipboard escape sequence for text, or nil when empty or over the byte cap.
;; tags: tui clipboard osc52 encoding
(fn M.osc52 [text]
  "Return the OSC 52 escape string that sets the system clipboard (selection
   `c`) to `text`, or nil when `text` is empty or exceeds M.max-bytes. The
   sequence is terminated with BEL (\\a), the widely supported OSC terminator."
  (let [s (or text "")]
    (if (or (= s "") (> (length s) M.max-bytes))
        nil
        (.. "\27]52;c;" (base64.encode-standard s) "\a"))))

;; @doc fen.extensions.tui.clipboard.write!
;; kind: data
;; signature: function
;; summary: Injectable terminal writer used to emit clipboard escape sequences; swappable in tests to capture output without a tty.
;; tags: tui clipboard osc52 io
(fn M.write! [s]
  "Default writer: emit `s` to the terminal. init.fnl uses the same
   io.write + io.flush convention for bracketed-paste escapes. Reassign
   M.write! in tests to capture the payload instead of touching the tty."
  (io.write s)
  (io.flush))

;; @doc fen.extensions.tui.clipboard.copy
;; kind: function
;; signature: (copy text) -> table
;; summary: Copy text to the system clipboard via OSC 52, returning an {ok? bytes reason} result describing success or why it was skipped.
;; tags: tui clipboard osc52 copy
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
