(local json (require :util.json))
(local log (require :util.log))

(local API-URL "https://api.openai.com/v1/chat/completions")

(fn build-request [{: model : messages : tools : max-tokens}]
  (let [req {:model model
             :messages messages
             :max_tokens (or max-tokens 1024)}]
    (when (and tools (> (length tools) 0))
      (set req.tools tools)
      (set req.tool_choice :auto))
    req))

(fn call-openai [api-key request]
  (let [curl (require :cURL)
        body (json.encode request)
        chunks []
        easy (curl.easy)]
    (easy:setopt_url API-URL)
    (easy:setopt_post 1)
    (easy:setopt_postfields body)
    (easy:setopt_httpheader [(.. "Authorization: Bearer " api-key)
                             "Content-Type: application/json"])
    (easy:setopt_writefunction
      (fn [chunk] (table.insert chunks chunk) (length chunk)))
    (let [(ok err) (pcall #(easy:perform))
          status (easy:getinfo_response_code)]
      (easy:close)
      (if (not ok)
          (do (log.error (.. "curl perform failed: " (tostring err)))
              {:ok? false :error (tostring err)})
          (let [raw (table.concat chunks)
                (decoded decode-err) (pcall json.decode raw)]
            (if (not decoded)
                (do (log.error (.. "json decode failed: " (tostring decode-err)
                                   " body=" raw))
                    {:ok? false :error (tostring decode-err) :raw raw})
                (let [resp decode-err]
                  (if (or (< status 200) (>= status 300))
                      (do (log.error (.. "http " status ": " raw))
                          {:ok? false :status status :error raw})
                      (let [choice (. resp.choices 1)]
                        {:ok? true
                         :finish-reason choice.finish_reason
                         :message choice.message
                         :usage resp.usage}))))))) ))

{: build-request : call-openai}
