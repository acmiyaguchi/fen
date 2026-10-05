;; Bus events the web presenter deliberately ignores instead of rendering as raw `<type>: ...` rows.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local state (require :fen.extensions.web.state))
(local web (require :fen.extensions.web))

(describe "web presenter bus events"
          (fn []
            (before_each (fn []
                           (test-api.reset!)
                           (set state.transcript [])
                           (set state.status-info {})
                           (web.register (test-api.make-runtime-api :web))))
            (after_each (fn [] (test-api.reset!)))
            (it "does not turn hosted web search activity into transcript rows"
                (fn []
                  (events.emit {:type :hosted-tool
                                :phase :start
                                :name "web_search"
                                :id "ws_1"})
                  (events.emit {:type :hosted-tool
                                :phase :end
                                :name "web_search"
                                :id "ws_1"
                                :status "completed"
                                :detail "latest Lua"})
                  (assert.are.equal 0 (length state.transcript))
                  (assert.is_nil state.status-info.running-label)))
            (it "still records ordinary info rows"
                (fn []
                  (events.emit {:type :info :text "hello"})
                  (assert.are.equal 1 (length state.transcript))
                  (assert.are.equal "hello" (. state.transcript 1 :text))))))
