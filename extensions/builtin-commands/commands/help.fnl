;; /help command.

(local extensions (require :fen.core.extensions))

(local M {})

(fn item-name [item]
  (tostring item.name))

(fn owner-name [item]
  (or item.owner :unknown))

(fn owner-title [owner]
  (tostring owner))

(fn compare-owners [a b]
  (< (owner-title a.owner) (owner-title b.owner)))

(fn compare-items [a b]
  (let [oa (or a.order 1000)
        ob (or b.order 1000)]
    (if (= oa ob)
        (< (item-name a) (item-name b))
        (< oa ob))))

(fn grouped-by-owner [items]
  (let [by-owner {}
        groups []]
    (each [_ item (ipairs items)]
      (let [owner (owner-name item)]
        (when (not (. by-owner owner))
          (let [group {:owner owner :items []}]
            (tset by-owner owner group)
            (table.insert groups group)))
        (table.insert (. by-owner owner :items) item)))
    (table.sort groups compare-owners)
    (each [_ group (ipairs groups)]
      (table.sort group.items compare-items))
    groups))

(fn command-width [commands]
  (var width 0)
  (each [_ cmd (ipairs commands)]
    (set width (math.max width (length (.. "/" (item-name cmd))))))
  width)

(fn command-line [cmd width]
  (let [name (.. "/" (item-name cmd))
        suffix (if cmd.idle-only? " (idle only)" "")
        desc (or cmd.description "")]
    (.. "  " (string.format (.. "%-" (tostring width) "s") name)
        " " desc suffix)))

(fn keys-text [control]
  (table.concat (or control.keys [control.name]) ", "))

(fn control-width [controls]
  (var width 0)
  (each [_ control (ipairs controls)]
    (set width (math.max width (length (keys-text control)))))
  width)

(fn control-line [control width]
  (.. "  " (string.format (.. "%-" (tostring width) "s") (keys-text control))
      " " (or control.description "")))

(fn append-owner-groups [lines groups line-fn]
  (each [_ group (ipairs groups)]
    (table.insert lines (.. "\n" (owner-title group.owner)))
    (each [_ item (ipairs group.items)]
      (table.insert lines (line-fn item)))))

(fn format-help []
  (let [commands (extensions.list :commands)
        controls (extensions.list :controls)
        command-w (command-width commands)
        control-w (control-width controls)
        lines ["Commands"]]
    (if (= (length commands) 0)
        (table.insert lines "  none")
        (append-owner-groups lines (grouped-by-owner commands)
                             #(command-line $1 command-w)))
    (table.insert lines "\nControls")
    (if (= (length controls) 0)
        (table.insert lines "  none")
        (append-owner-groups lines (grouped-by-owner controls)
                             #(control-line $1 control-w)))
    (table.concat lines "\n")))

;; @doc fen.extensions.builtin_commands.commands.help.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /help command that lists available slash commands and controls grouped by extension owner.
;; tags: commands help register
(fn M.register [api]
  (api.register :command
    {:name :help
     :order 1000
     :description "Show available commands and controls"
     :handler (fn [_args _state]
                (extensions.emit {:type :assistant-text
                                  :text (format-help)}))}))

M
