;; Small JSON Schema validator for tool-call arguments.
;;
;; This deliberately implements only the vocabulary used by Fen tool schemas:
;; type, properties, required, items, anyOf, enum, minimum, and maximum.
;; Descriptive annotations and other unknown keywords are ignored. Validation is
;; therefore best-effort: constraints outside this subset, such as
;; additionalProperties, are not enforced.

(local schema-keys
  {:type true :properties true :required true :items true :anyOf true
   :enum true :minimum true :maximum true :description true})

(fn key-name [key] (tostring key))

(fn path-field [path key]
  (if (= path "") (key-name key) (.. path "." (key-name key))))

(fn array-table? [value]
  ;; Empty Lua tables have no shape, so they must be accepted as arrays too.
  (and (= (type value) :table)
       (or (= (?. (getmetatable value) :__jsontype) "array")
           (= (length value) 0)
           (not= (rawget value 1) nil))))

(fn object-table? [value]
  ;; Empty Lua tables have no shape. Accept them as either JSON container so
  ;; literal [] tool arguments remain valid even without cjson's array metatable.
  (and (= (type value) :table)
       (or (= (length value) 0) (not (array-table? value)))))

(fn type-matches? [expected value]
  (case expected
    :string (= (type value) :string)
    :number (= (type value) :number)
    :integer (and (= (type value) :number) (= value (math.floor value)))
    :boolean (= (type value) :boolean)
    :object (object-table? value)
    :array (array-table? value)
    :null (= value nil)
    _ false))

(fn value-in? [choices value]
  (var found false)
  (each [_ candidate (ipairs (or choices []))]
    (when (= candidate value) (set found true)))
  found)

(fn schema-path [path segment]
  (if (= path "") segment (.. path "." segment)))

;; Return unknown keywords with their schema locations so registration can
;; report them once without making every later tool call fail.
(fn unsupported-keywords [schema]
  (let [found []]
    (fn visit [node path]
      (when (= (type node) :table)
        (each [key _ (pairs node)]
          (when (not (. schema-keys key))
            (table.insert found {:keyword (key-name key)
                                 :path (if (= path "") "arguments" path)})))
        (when (= (type node.properties) :table)
          (each [key child (pairs node.properties)]
            (visit child (schema-path (schema-path path "properties")
                                      (key-name key)))))
        (when (= (type node.items) :table)
          (visit node.items (schema-path path "items")))
        (when (= (type node.anyOf) :table)
          (each [index child (ipairs node.anyOf)]
            (visit child (schema-path path
                                      (.. "anyOf[" (tostring index) "]")))))))
    (visit schema "")
    (table.sort found
                (fn [left right]
                  (if (= left.path right.path)
                      (< left.keyword right.keyword)
                      (< left.path right.path))))
    found))

(fn add-error! [errors path message]
  (table.insert errors {:field (if (= path "") "arguments" path)
                        :message message}))

(fn validate-node [schema value path errors]
  (when (not= (type schema) :table)
    (error "schema node must be a table"))
  (when schema.type
    (when (not (type-matches? schema.type value))
      (add-error! errors path (.. "must be a " (key-name schema.type)))))
  (when (and schema.enum (not (value-in? schema.enum value)))
    (add-error! errors path "must be one of the declared values"))
  (when (and schema.minimum (= (type value) :number) (< value schema.minimum))
    (add-error! errors path (.. "must be at least " (tostring schema.minimum))))
  (when (and schema.maximum (= (type value) :number) (> value schema.maximum))
    (add-error! errors path (.. "must be at most " (tostring schema.maximum))))
  ;; cjson.empty_array is a userdata sentinel, not an iterable table.
  ;; Treat it and any other non-table required value as no required fields.
  (when (and (= (type schema.required) :table) (object-table? value))
    (each [_ key (ipairs schema.required)]
      (when (= (rawget value key) nil)
        (add-error! errors (path-field path key) "is required"))))
  (when (and schema.properties (object-table? value))
    (each [key child-schema (pairs schema.properties)]
      (let [child (rawget value key)]
        (when (not= child nil)
          (validate-node child-schema child (path-field path key) errors)))))
  (when (and schema.items (array-table? value))
    (each [index child (ipairs value)]
      (validate-node schema.items child (.. path "[" (tostring index) "]") errors)))
  (when schema.anyOf
    (var matched false)
    (each [_ option (ipairs schema.anyOf)]
      (let [option-errors []]
        (validate-node option value path option-errors)
        (when (= (length option-errors) 0) (set matched true))))
    (when (not matched)
      (add-error! errors path "must match one of the declared schemas"))))

;; @doc fen.util.json_schema.validate
;; kind: function
;; signature: (validate schema value) -> true|nil, [SchemaError]
;; summary: Validate a JSON value against Fen's lightweight tool-schema subset.
;; tags: json schema tools
(fn validate [schema value]
  (let [errors []]
    (validate-node (or schema {}) value "" errors)
    (if (= (length errors) 0)
        (values true nil)
        (values nil errors))))

{:validate validate
 :unsupported-keywords unsupported-keywords}
