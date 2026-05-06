;; Persistent extension runtime state. Not reloadable.

{:version 1
 :handlers {}
 :tools-extra []
 :commands-extra {}
 :controls-extra []
 :status-extra []
 :panel-extra []
 :presenters []
 :providers {}
 :auth-backends {}
 :session-backends {}
 :session {:active-name nil :backend nil :info nil}
 :hooks {:before-tool []}
 :prompt-fragments []
 :prompt-next-seq 0
 :extensions {}
 :reload-fingerprints {}
 :errors []
 :error-log-path nil
 :ui {:slot nil}}
