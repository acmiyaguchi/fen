;; Persistent goal companion state. Not reloadable.

{:status :idle        ; :idle | :running | :done | :blocked | :stopped | :error | :cap-reached
 :visible? true
 :objective nil
 :iteration-count 0
 :max-iterations 3
 :last-result nil
 :last-error nil
 :last-reason nil
 :last-marker nil
 :started-at nil
 :updated-at nil
 :version 0
 :cached-rows nil
 :cached-w -1
 :cached-version -1}
