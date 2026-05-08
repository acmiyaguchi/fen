;; Persistent web-presenter state. Not listed in the web manifest's
;; reload-modules so browser clients/transcript survive /reload.

;; @doc fen.extensions.web.state.server
;; kind: data
;; signature: server|nil
;; summary: Active web server handle, kept outside reloadable modules so the listening socket can survive behavior reloads.
;; tags: web state server reload

;; @doc fen.extensions.web.state.host
;; kind: data
;; signature: string
;; summary: Interface address used by the web presenter when binding its HTTP/SSE server.
;; tags: web state server config

;; @doc fen.extensions.web.state.port
;; kind: data
;; signature: number
;; summary: TCP port used by the web presenter server and advertised browser URL.
;; tags: web state server config

;; @doc fen.extensions.web.state.clients
;; kind: data
;; signature: [client]
;; summary: Connected web client records tracked by the presenter server for lifecycle and cleanup.
;; tags: web state clients

;; @doc fen.extensions.web.state.sse-clients
;; kind: data
;; signature: [client]
;; summary: Active Server-Sent Events client connections receiving transcript/status snapshots.
;; tags: web state clients sse

;; @doc fen.extensions.web.state.pending-inputs
;; kind: data
;; signature: [string]
;; summary: User inputs submitted by browser clients and queued for the presenter loop to hand to the agent.
;; tags: web state input queue

;; @doc fen.extensions.web.state.quit?
;; kind: data
;; signature: boolean
;; summary: Presenter loop shutdown flag set by web controls when the browser requests session termination.
;; tags: web state lifecycle

;; @doc fen.extensions.web.state.last-snapshot
;; kind: data
;; signature: string
;; summary: Last serialized browser snapshot used to avoid redundant SSE broadcasts when visible state has not changed.
;; tags: web state sse cache

;; @doc fen.extensions.web.state.last-broadcast
;; kind: data
;; signature: number
;; summary: Timestamp/counter of the last web snapshot broadcast used to pace browser updates.
;; tags: web state sse cache

;; @doc fen.extensions.web.state.client-reload-seq
;; kind: data
;; signature: number
;; summary: Monotonic sequence bumped to tell browser clients that frontend assets or presenter behavior should reload.
;; tags: web state reload clients

;; @doc fen.extensions.web.state.select-seq
;; kind: data
;; signature: number
;; summary: Monotonic id counter for active web select prompts so browser replies can be matched to the current prompt.
;; tags: web state select input

;; @doc fen.extensions.web.state.active-select
;; kind: data
;; signature: table|nil
;; summary: Currently active browser select prompt, including choices and response bookkeeping for presenter UI APIs.
;; tags: web state select input

;; @doc fen.extensions.web.state.presenter-ctx
;; kind: data
;; signature: table|nil
;; summary: Current web presenter runtime context captured for server handlers that need to submit input or request cancellation.
;; tags: web state presenter

;; @doc fen.extensions.web.state.transcript
;; kind: data
;; signature: [PresenterEvent]
;; summary: Persistent web transcript event log used to build browser snapshots after reloads or client reconnects.
;; tags: web state transcript

;; @doc fen.extensions.web.state.status-info
;; kind: data
;; signature: table
;; summary: Web status metadata for provider/model, context estimates, queues, running tool, thinking, cancellation, and turn timing.
;; tags: web state status

{:server nil
 :host "127.0.0.1"
 :port 8765
 :clients []
 :sse-clients []
 :pending-inputs []
 :quit? false
 :last-snapshot ""
 :last-broadcast 0
 :client-reload-seq 0
 :select-seq 0
 :active-select nil
 :presenter-ctx nil
 :transcript []
 :status-info {:provider nil
               :model nil
               :last-input 0
               :approx-context 0
               :steering-queued 0
               :follow-up-queued 0
               :running-label nil
               :thinking? false
               :cancelling? false
               :turn-start 0
               :spin-frame 0}}
