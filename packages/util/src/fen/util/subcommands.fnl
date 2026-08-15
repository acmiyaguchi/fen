;; Declarative subcommand tables: uniform dispatch, generated `/cmd help`, completion descriptors.
;; Handlers get (rest-args run-state); :default handles bare invocations, and with :default-takes-args?
;; also any unrecognized first word (so free-form commands like `/resume <target>` keep working).
;;
;; RELOADABLE: every export is a field on M, so hot reload is picked up on the next call.

(local args-util (require :fen.util.args))
(local trim (. (require :fen.util.text) :trim))

(local M {})

;; `help` is reserved unless the command declares its own subcommand of that name.
(local HELP-WORD "help")

(fn cmd-label [name]
  "Slash-prefixed command label for help/usage/error text."
  (.. "/" (tostring (or name "command"))))

(fn assert-handler! [name handler]
  (when (not= (type handler) :function)
    (error (.. "subcommands.build requires handler fn for :" name))))

(fn normalize-entry [name entry]
  "Coerce one raw subcommand entry into {:name :description :handler}."
  (let [name (string.lower (tostring name))]
    (when (= name "")
      (error "subcommands.build requires named subcommands"))
    (if (= (type entry) :function)
        {:name name :description "" :handler entry}
        (= (type entry) :table)
        (do
          (assert-handler! name entry.handler)
          {:name name
           :description (tostring (or entry.description ""))
           :handler entry.handler})
        (error (.. "subcommands.build subcommand :" name
                   " must be a function or table")))))

(fn collect-subcommands [raw]
  "Return subcommands as a name->entry map plus a name-sorted list. Accepts a
   map keyed by name, or a list of {:name ...} entries."
  (let [by-name {}]
    (when (and raw (not= (type raw) :table))
      (error "subcommands.build :subcommands must be a table"))
    (when (= (type raw) :table)
      (if (> (length raw) 0)
          (each [_ entry (ipairs raw)]
            (let [norm (normalize-entry (or entry.name "") entry)]
              (when (and norm (not= norm.name ""))
                (tset by-name norm.name norm))))
          (each [name entry (pairs raw)]
            (let [norm (normalize-entry name entry)]
              (when (and norm (not= norm.name ""))
                (tset by-name norm.name norm))))))
    (let [ordered []]
      (each [_ entry (pairs by-name)]
        (table.insert ordered entry))
      (table.sort ordered (fn [a b] (< a.name b.name)))
      (values by-name ordered))))

(fn parse [args]
  "Split a raw argument string into (subcommand-word rest). The word is trimmed
   and lowercased; rest is the remaining argument string, trimmed. Returns
   (nil \"\") when there is no argument."
  (let [word (args-util.first-arg args)]
    (values (and word (string.lower word))
            (args-util.rest-args args))))

(fn M.help-lines [descriptor]
  "Render the help table for `descriptor` as a list of plain strings."
  (let [name (or descriptor.name "command")
        label (cmd-label name)
        lines []
        rows []]
    (each [_ entry (ipairs descriptor.subcommands)]
      (table.insert rows {:name entry.name :description entry.description}))
    (when (not descriptor.has-help-subcommand?)
      (table.insert rows {:name HELP-WORD :description "show this help"}))
    (table.insert lines
      (if (and descriptor.summary (not= descriptor.summary ""))
          (.. label " — " descriptor.summary)
          label))
    (when (and descriptor.usage (not= descriptor.usage ""))
      (table.insert lines (.. "usage: " descriptor.usage)))
    (when (> (length rows) 0)
      (table.insert lines "")
      (var name-w 0)
      (each [_ row (ipairs rows)]
        (set name-w (math.max name-w (length row.name))))
      (each [_ row (ipairs rows)]
        (let [pad (string.rep " " (math.max 1 (- (+ name-w 2) (length row.name))))]
          (table.insert lines
            (if (= row.description "")
                (.. "  " row.name)
                (.. "  " row.name pad row.description))))))
    lines))

;; @doc fen.util.subcommands.help-text
;; kind: function
;; signature: (help-text descriptor) -> string
;; summary: Join the generated help lines for a subcommand descriptor into a single newline-delimited string.
;; tags: util subcommands help
(fn M.help-text [descriptor]
  (table.concat (M.help-lines descriptor) "\n"))

(fn default-usage [name ordered has-default? has-help-subcommand?]
  "Compact `/cmd [a|b|help]` usage string generated from the subcommand names."
  (let [parts []]
    (each [_ entry (ipairs ordered)]
      (table.insert parts entry.name))
    (when (not has-help-subcommand?)
      (table.insert parts HELP-WORD))
    (let [inner (table.concat parts "|")]
      (if (= inner "")
          (cmd-label name)
          (if has-default?
              (.. (cmd-label name) " [" inner "]")
              (.. (cmd-label name) " <" inner ">"))))))

(fn M.build [spec]
  "Turn a declarative subcommand spec into command hooks.

   spec fields:
     :name               command name, used in help/usage/error text (required)
     :emit               event emitter, e.g. api.emit (required)
     :summary            optional one-line description shown atop help
     :usage              optional usage override; generated when omitted
     :default            optional handler for the bare (no-argument) call, and —
                         with :default-takes-args? — for unmatched first words
     :default-takes-args? route unrecognized first words to :default instead of
                         emitting the unknown-argument fallback
     :subcommands        map (or list) of {name -> {:description :handler}}

   Returns {:handler :complete :descriptor :usage :help-text}. Wire :handler and
   :complete onto the `:command` spec; :descriptor/:usage are presenter-agnostic
   data for the completion overlay and /help."
  (when (or (not spec) (not spec.name))
    (error "subcommands.build requires {:name ...}"))
  (when (not= (type spec.emit) :function)
    (error "subcommands.build requires {:emit fn}"))
  (when (and spec.default (not= (type spec.default) :function))
    (error "subcommands.build :default must be a function"))
  (let [name (tostring spec.name)
        emit spec.emit
        default spec.default
        default-takes-args? (and default spec.default-takes-args?)
        (by-name ordered) (collect-subcommands spec.subcommands)
        has-help-subcommand? (not= (. by-name HELP-WORD) nil)
        usage (or spec.usage (default-usage name ordered (not= default nil)
                                            has-help-subcommand?))
        descriptor {:name name
                    :summary (or spec.summary "")
                    :usage usage
                    :has-help-subcommand? has-help-subcommand?
                    :subcommands ordered}
        help-text (M.help-text descriptor)
        show-help (fn [] (emit {:type :info :text (M.help-text descriptor)}))
        unknown (fn [word]
                  (emit {:type :error
                         :error (.. (cmd-label name) ": unknown subcommand: "
                                    (tostring word))})
                  (show-help))
        handler (fn [args run-state]
                  (let [(word rest) (parse args)]
                    (if (= word nil)
                        (if default
                            (default (or (and args (trim args)) "") run-state)
                            (show-help))
                        (and (= word HELP-WORD) (not has-help-subcommand?))
                        (show-help)
                        (let [entry (. by-name word)]
                          (if entry
                              (entry.handler rest run-state)
                              default-takes-args?
                              (default (trim (or args "")) run-state)
                              (unknown word))))))
        complete (fn [arg-prefix _ctx]
                   (let [choices []]
                     (each [_ entry (ipairs ordered)]
                       (table.insert choices
                         {:label entry.name
                          :value entry.name
                          :description entry.description}))
                     (when (not has-help-subcommand?)
                       (table.insert choices
                         {:label HELP-WORD :value HELP-WORD
                          :description "show this help"}))
                     choices))]
    {:handler handler
     :complete complete
     :descriptor descriptor
     :usage usage
     :help-text help-text}))

M
