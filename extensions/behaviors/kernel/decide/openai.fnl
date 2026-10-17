;; OpenAI Decisions API client.
;;
;; The only module that knows the OpenAI Decisions endpoint URL and wire shapes.
;; Translates service questions (:noul, :choice) to OpenAI predicate/choice
;; schemas and normalizes OpenAI answers back to the existing service shapes.

(local http (require :fen.util.http))
(local json (require :fen.util.json))

(local M {})

(local URL "https://api.openai.com/v1/decisions")
(local MAX-CONNECT-TIMEOUT-MS 2000)
(local MAX-ERROR-CHARS 200)

(fn predicate-instructions [q]
  (let [t (?. q :criteria :true)
        f (?. q :criteria :false)]
    (if (and t f) (.. q.instructions "\nTrue if: " t "\nFalse if: " f)
        t (.. q.instructions "\nTrue if: " t)
        f (.. q.instructions "\nFalse if: " f)
        q.instructions)))

(fn choice-options [q]
  (let [keys []]
    (each [k _ (pairs q.criteria)]
      (table.insert keys (tostring k)))
    (table.sort keys)
    (let [choices []]
      (each [_ k (ipairs keys)]
        (table.insert choices {:value k :description (. q.criteria k)}))
      choices)))

;; @doc fen.extensions.decide.openai.encode-request
;; kind: function
;; signature: (encode-request model state questions) -> string
;; summary: Encode an OpenAI Decisions API request body for one state and a map of validated noul/choice questions; raises when state is not JSON-encodable or a question type is unsupported.
;; tags: decide openai
(fn M.encode-request [model state questions]
  (let [ids []]
    (each [id _ (pairs questions)]
      (table.insert ids (tostring id)))
    (table.sort ids)
    (let [qs []]
      (each [_ id (ipairs ids)]
        (let [q (. questions id)]
          (if (= q.type :noul)
              (table.insert qs
                            {:type "predicate"
                             :name id
                             :instructions (predicate-instructions q)})
              (= q.type :choice)
              (table.insert qs
                            {:type "choice"
                             :name id
                             :instructions q.instructions
                             :choices (choice-options q)})
              (error (.. "unsupported question type: " (tostring q.type))))))
      (let [input (if (= (type state) :string)
                      state
                      (if (= state nil)
                          ""
                          (json.encode state)))]
        (json.encode {: model : input :questions qs})))))

;; @doc fen.extensions.decide.openai.post
;; kind: function
;; signature: (post body api-key timeout-ms ?yield) -> {:status :body :headers}|{:error}
;; summary: POST an encoded request to the OpenAI Decisions API through fen.util.http with an overall timeout and a connect timeout capped at 2s; errors raised by ?yield propagate.
;; tags: decide openai http
(fn M.post [body api-key timeout-ms ?yield]
  (http.request {:method :POST
                 :url URL
                 :headers {:authorization (.. "Bearer " api-key)
                           :content-type "application/json"
                           :accept "application/json"}
                 :body body
                 :timeout-ms timeout-ms
                 :connect-timeout-ms (math.min timeout-ms
                                               MAX-CONNECT-TIMEOUT-MS)
                 :yield ?yield}))

(fn error-message [body]
  (let [(ok? decoded) (pcall json.decode (or body ""))
        msg (and ok? (= (type decoded) :table) (= (type decoded.error) :table)
                 decoded.error.message)]
    (string.sub (if (= (type msg) :string) msg (tostring (or body ""))) 1
                MAX-ERROR-CHARS)))

(fn unit? [v]
  (and (= (type v) :number) (>= v 0) (<= v 1)))

(fn parse-probabilities [raw-probs criteria]
  (when (and (= (type raw-probs) :table) (not= (next raw-probs) nil))
    (let [out {}]
      (var ok? true)
      (if (not= (. raw-probs 1) nil)
          (each [_ item (ipairs raw-probs)]
            (if (and ok? (= (type item) :table) (= (type item.value) :string)
                     (. criteria item.value) (unit? item.probability)
                     (= (. out item.value) nil))
                (tset out item.value item.probability)
                (set ok? false)))
          (each [k v (pairs raw-probs)]
            (if (and ok? (= (type k) :string) (. criteria k) (unit? v))
                (tset out k v)
                (set ok? false))))
      (when ok? out))))

(fn parse-answer [q raw]
  "Strict: the answer's type must match the question's, and every field the
   answer shape promises must be present and in range; otherwise nil."
  (when (= (type raw) :table)
    (if (= q.type :noul)
        (let [p (or raw.probability raw.noul)]
          (when (and (or (= raw.type "predicate") (= raw.type "noul"))
                     (unit? p))
            {:type :noul :noul p}))
        (= q.type :choice)
        (when (and (= raw.type "choice") (= (type raw.choice) :string)
                   (. q.criteria raw.choice)
                   (or (= raw.confidence nil) (unit? raw.confidence)))
          (let [probs (parse-probabilities raw.probabilities q.criteria)]
            (when probs
              {:type :choice
               :choice raw.choice
               :probabilities probs
               :confidence raw.confidence}))))))

;; @doc fen.extensions.decide.openai.parse-response
;; kind: function
;; signature: (parse-response resp questions) -> (answers usage)|(nil reason)
;; summary: Map an OpenAI Decisions HTTP response to answers keyed by question id ({:type :noul :noul p} or {:type :choice :choice opt :probabilities tbl :confidence c}) plus raw usage; transport errors, non-200, malformed bodies, refusals, duplicate answers, or missing/mistyped answers return nil and a reason.
;; tags: decide openai
(fn M.parse-response [resp questions]
  (if (= resp nil)
      (values nil "no response")
      resp.error
      (values nil (.. "transport: " (tostring resp.error)))
      (not= resp.status 200)
      (values nil (.. "HTTP " (tostring resp.status) ": "
                      (error-message resp.body)))
      (let [(ok? decoded) (pcall json.decode (or resp.body ""))]
        (if (not (and ok? (= (type decoded) :table)
                      (= (type decoded.answers) :table)))
            (values nil "malformed response")
            (let [raw-list (if (not= (. decoded.answers 1) nil)
                               decoded.answers
                               (let [list []]
                                 (each [k v (pairs decoded.answers)]
                                   (when (= (type v) :table)
                                     (when (not v.name) (tset v :name k))
                                     (table.insert list v)))
                                 list))
                  out {}
                  seen-names {}]
              (var failure nil)
              (each [_ raw (ipairs raw-list) &until failure]
                (if (not= (type raw) :table)
                    (set failure "malformed response")
                    (= raw.type "refusal")
                    (set failure
                         (.. "refusal for " (tostring (or raw.name "unknown"))))
                    (let [name raw.name]
                      (if (not= (type name) :string)
                          (set failure "malformed response")
                          (. seen-names name)
                          (set failure (.. "duplicate answer for " name))
                          (let [q (. questions name)]
                            (if (not q)
                                (set failure (.. "unexpected answer for " name))
                                (let [answer (parse-answer q raw)]
                                  (if (not answer)
                                      (set failure
                                           (.. "missing or malformed answer: "
                                               name))
                                      (do
                                        (tset seen-names name true)
                                        (tset out name answer))))))))))
              (if failure
                  (values nil failure)
                  (let [missing (accumulate [m nil id _ (pairs questions)]
                                  (or m (when (not (. out id)) id)))]
                    (if missing
                        (values nil
                                (.. "missing or malformed answer: "
                                    (tostring missing)))
                        (values out decoded.usage)))))))))

M
