#!/usr/bin/env fennel
;; Tiny deterministic OpenAI-compatible mock service for scripts/smoke-mock.sh.
;; Depends only on LuaSocket. It intentionally understands just the request
;; shapes Fen's smoke test sends and returns scripted tool-call -> OK turns.

(local socket (require :socket))

(local port-file (. arg 1))
(when (not port-file)
  (io.stderr:write "usage: mock-openai.fnl PORT_FILE\n")
  (os.exit 2))

(fn write-file [path text]
  (let [f (assert (io.open path :w))]
    (f:write text)
    (f:close)))

(fn json-escape [s]
  (-> (tostring s)
      (string.gsub "\\" "\\\\")
      (string.gsub "\"" "\\\"")
      (string.gsub "\n" "\\n")))

(fn write-response [client status content-type body]
  (let [reason (if (= status 200) "OK" "Not Found")]
    (client:send
      (table.concat
        [(.. "HTTP/1.1 " status " " reason)
         (.. "Content-Type: " content-type)
         (.. "Content-Length: " (length body))
         "Connection: close"
         ""
         body]
        "\r\n"))))

(fn sse [events]
  (let [out []]
    (each [_ ev (ipairs events)]
      (table.insert out (.. "data: " ev "\n\n")))
    (table.insert out "data: [DONE]\n\n")
    (table.concat out)))

(fn has-chat-tool-result? [body]
  (not= nil (string.find body "\"role\"%s*:%s*\"tool\"")))

(fn has-responses-tool-result? [body]
  (not= nil (string.find body "\"type\"%s*:%s*\"function_call_output\"")))

(fn chat-response [body]
  (let [model (or (string.match body "\"model\"%s*:%s*\"([^\"]+)\"") "mock-chat")]
    (if (has-chat-tool-result? body)
        (string.format
          "{\"id\":\"chatcmpl_mock_final\",\"object\":\"chat.completion\",\"created\":%d,\"model\":\"%s\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"OK\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
          (os.time) (json-escape model))
        (let [args (json-escape "{\"path\":\"README.md\",\"limit\":1}")]
          (string.format
            "{\"id\":\"chatcmpl_mock_tool\",\"object\":\"chat.completion\",\"created\":%d,\"model\":\"%s\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_read_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"%s\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
            (os.time) (json-escape model) args)))))

(fn responses-stream [body]
  (if (has-responses-tool-result? body)
      (sse
        ["{\"type\":\"response.created\",\"response\":{\"id\":\"resp_mock_final\"}}"
         "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"msg_mock_final\",\"type\":\"message\",\"status\":\"in_progress\"}}"
         "{\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}"
         "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"msg_mock_final\",\"type\":\"message\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\",\"annotations\":[]}]}}"
         "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_mock_final\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}"])
      (let [args (json-escape "{\"path\":\"README.md\",\"limit\":1}")]
        (sse
          ["{\"type\":\"response.created\",\"response\":{\"id\":\"resp_mock_tool\"}}"
           "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_mock_1\",\"type\":\"function_call\",\"call_id\":\"call_read_1\",\"name\":\"read\",\"arguments\":\"\"}}"
           (string.format "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"%s\"}" args)
           (string.format "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"%s\"}" args)
           (string.format "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_mock_1\",\"type\":\"function_call\",\"call_id\":\"call_read_1\",\"name\":\"read\",\"arguments\":\"%s\",\"status\":\"completed\"}}" args)
           "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_mock_tool\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}"]))))

(fn read-request [client]
  (let [request-line (client:receive :*l)]
    (when request-line
      (let [(method path) (string.match request-line "^(%S+)%s+(%S+)")
            headers {}]
        (var done? false)
        (while (not done?)
          (let [line (client:receive :*l)]
            (if (or (not line) (= line ""))
                (set done? true)
                (let [(k v) (string.match line "^([^:]+):%s*(.*)$")]
                  (when k
                    (tset headers (string.lower k) v))))))
        (let [n (or (tonumber (or (. headers :content-length) "0")) 0)
              body (if (> n 0) (or (client:receive n) "") "")]
          (values method path body))))))

(local server (assert (socket.bind "127.0.0.1" 0)))
(server:settimeout 1)
(let [(_host port) (server:getsockname)]
  (write-file port-file (tostring port)))

(while true
  (let [client (server:accept)]
    (when client
      (client:settimeout 5)
      (let [(_method path body) (read-request client)]
        (if (= path "/v1/chat/completions")
            (write-response client 200 "application/json" (chat-response (or body "")))
            (= path "/v1/responses")
            (write-response client 200 "text/event-stream" (responses-stream (or body "")))
            path
            (write-response client 404 "application/json" "{\"error\":{\"message\":\"unknown path\"}}")))
      (client:close))))
