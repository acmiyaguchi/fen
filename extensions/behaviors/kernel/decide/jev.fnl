;; OpenRouter Decisions API client for TypeSafe's Jev.
;;
;; The only module that knows the endpoint URL and the wire shapes. The API
;; lives under `/api/alpha/`, so a breaking change there stays in this file.

(local http (require :fen.util.http))
(local json (require :fen.util.json))

(local M {})

(local URL "https://openrouter.ai/api/alpha/decisions")
(local MAX-CONNECT-TIMEOUT-MS 2000)
(local MAX-ERROR-CHARS 200)

;; @doc fen.extensions.decide.jev.encode-request
;; kind: function
;; signature: (encode-request model state questions) -> string
;; summary: Encode a Decisions API request body for one state and a map of validated noul/choice questions; raises when state is not JSON-encodable.
;; tags: decide jev openrouter
(fn M.encode-request [model state questions]
  (let [qs {}]
    (each [id q (pairs questions)]
      (tset qs id {:type q.type :instructions q.instructions :criteria q.criteria}))
    (json.encode {: model : state :questions qs})))

;; @doc fen.extensions.decide.jev.post
;; kind: function
;; signature: (post body api-key timeout-ms ?yield) -> {:status :body :headers}|{:error}
;; summary: POST an encoded request to the Decisions API through fen.util.http with an overall timeout and a connect timeout capped at 2s; errors raised by ?yield propagate.
;; tags: decide jev openrouter http
(fn M.post [body api-key timeout-ms ?yield]
  (http.request {:method :POST
                 :url URL
                 :headers {:authorization (.. "Bearer " api-key)
                           :content-type "application/json"
                           :accept "application/json"}
                 :body body
                 :timeout-ms timeout-ms
                 :connect-timeout-ms (math.min timeout-ms MAX-CONNECT-TIMEOUT-MS)
                 :yield ?yield}))

(fn error-message [body]
  (let [(ok? decoded) (pcall json.decode (or body ""))
        msg (and ok? (= (type decoded) :table)
                 (= (type decoded.error) :table)
                 decoded.error.message)]
    (string.sub (if (= (type msg) :string) msg (tostring (or body "")))
                1 MAX-ERROR-CHARS)))

(fn unit? [v]
  (and (= (type v) :number) (>= v 0) (<= v 1)))

(fn probabilities [raw]
  "Copy of a non-empty {option p} table with every p in [0,1], else nil."
  (when (and (= (type raw) :table) (not= (next raw) nil))
    (let [out {}]
      (var ok? true)
      (each [k v (pairs raw)]
        (if (and (= (type k) :string) (unit? v))
            (tset out k v)
            (set ok? false)))
      (when ok? out))))

(fn parse-answer [q raw]
  "Strict: the answer's type must match the question's, and every field the
   answer shape promises must be present and in range; otherwise nil."
  (when (and (= (type raw) :table) (= raw.type q.type))
    (if (= q.type :noul)
        (when (unit? raw.noul)
          {:type :noul :noul raw.noul})
        (= q.type :choice)
        (let [probs (probabilities raw.probabilities)]
          (when (and (= (type raw.choice) :string)
                     (. q.criteria raw.choice)
                     probs
                     (unit? raw.confidence))
            {:type :choice
             :choice raw.choice
             :probabilities probs
             :confidence raw.confidence})))))

;; @doc fen.extensions.decide.jev.parse-response
;; kind: function
;; signature: (parse-response resp questions) -> (answers usage)|(nil reason)
;; summary: Map an HTTP response to answers keyed by question id ({:type :noul :noul p} or {:type :choice :choice opt :probabilities tbl :confidence c}) plus the raw usage; any transport error, non-200, malformed body, or missing/mistyped answer returns nil and a reason.
;; tags: decide jev openrouter
(fn M.parse-response [resp questions]
  (if (= resp nil)
      (values nil "no response")
      resp.error
      (values nil (.. "transport: " (tostring resp.error)))
      (not= resp.status 200)
      (values nil (.. "HTTP " (tostring resp.status) ": " (error-message resp.body)))
      (let [(ok? decoded) (pcall json.decode (or resp.body ""))]
        (if (not (and ok? (= (type decoded) :table) (= (type decoded.answers) :table)))
            (values nil "malformed response")
            (let [out {}]
              (var missing nil)
              (each [id q (pairs questions)]
                (let [answer (parse-answer q (. decoded.answers id))]
                  (if answer
                      (tset out id answer)
                      (set missing id))))
              (if missing
                  (values nil (.. "missing or malformed answer: " (tostring missing)))
                  (values out decoded.usage)))))))

M
