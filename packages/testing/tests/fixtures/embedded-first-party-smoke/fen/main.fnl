;; Stand-in for fen.main used by Nix smoke checks. It verifies that the raw
;; single-file binary can discover and load embedded first-party extensions
;; without FEN_EXTENSION_ROOT / source-checkout overlays.

(local loader (require :fen.core.extensions.loader))
(local state (require :fen.core.extensions.state))

(fn count-pairs [t]
  (var n 0)
  (each [_ _v (pairs (or t {}))]
    (set n (+ n 1)))
  n)

(fn fail! [msg]
  (io.stderr:write (.. "EMBEDDED-FIRST-PARTY-FAIL: " msg "\n"))
  (os.exit 1))

(let [(ok? summary-or-err) (pcall loader.load! {:presenter :print} {:interactive? true})]
  (when (not ok?)
    (fail! (tostring summary-or-err)))
  (let [summary summary-or-err
        providers (count-pairs state.providers)
        tools (length state.tools-extra)
        commands (count-pairs state.commands-extra)
        session-backends (count-pairs state.session-backends)
        prompt-fragments (length state.prompt-fragments)
        presenters (length state.presenters)]
    (when (< summary.loaded 10)
      (fail! (.. "loaded too few extensions: " (tostring summary.loaded))))
    (when (< providers 4)
      (fail! (.. "providers=" (tostring providers))))
    (when (< tools 8)
      (fail! (.. "tools=" (tostring tools))))
    (when (< commands 10)
      (fail! (.. "commands=" (tostring commands))))
    (when (< session-backends 1)
      (fail! (.. "session_backends=" (tostring session-backends))))
    (when (< prompt-fragments 3)
      (fail! (.. "prompt_fragments=" (tostring prompt-fragments))))
    (when (< presenters 1)
      (fail! (.. "presenters=" (tostring presenters))))
    (io.write
      (string.format
        "EMBEDDED-FIRST-PARTY-OK loaded=%d providers=%d tools=%d commands=%d session_backends=%d prompt_fragments=%d presenters=%d\n"
        summary.loaded providers tools commands session-backends prompt-fragments presenters))
    (os.exit 0)))
