(local schema (require :fen.util.json_schema))
(local json (require :fen.util.json))

(describe "util.json-schema.validate"
  (fn []
    (it "reports missing required fields"
      (fn []
        (let [(ok errors) (schema.validate {:type :object
                                            :properties {:path {:type :string}}
                                            :required [:path]}
                                           {})]
          (assert.is_nil ok)
          (assert.are.equal "path" (. errors 1 :field))
          (assert.are.equal "is required" (. errors 1 :message)))))

    (it "treats cjson's empty-array required sentinel as no required fields"
      (fn []
        (assert.are.equal :userdata (type json.empty-array))
        (let [(ok errors) (schema.validate {:type :object
                                            :properties {:topic {:type :string}}
                                            :required json.empty-array}
                                           {})]
          (assert.is_true ok)
          (assert.is_nil errors))))

    (it "reports wrong primitive and table types"
      (fn []
        (let [(ok errors) (schema.validate {:type :object
                                            :properties {:enabled {:type :boolean}
                                                         :options {:type :object}}
                                            :required [:enabled :options]}
                                           {:enabled "true" :options "not a table"})]
          (assert.is_nil ok)
          (let [messages {}]
            (each [_ error (ipairs errors)]
              (tset messages error.field error.message))
            (assert.are.equal "must be a boolean" messages.enabled)
            (assert.are.equal "must be a object" messages.options)))))

    (it "validates enum and nested array items"
      (fn []
        (let [(ok errors) (schema.validate {:type :object
                                            :properties {:mode {:type :string :enum ["fast" "safe"]}
                                                         :items {:type :array
                                                                 :items {:type :object
                                                                         :properties {:name {:type :string}}
                                                                         :required [:name]}}}}
                                           {:mode "unsafe" :items [{}]})]
          (assert.is_nil ok)
          (let [messages {}]
            (each [_ error (ipairs errors)]
              (tset messages error.field error.message))
            (assert.are.equal "must be one of the declared values" messages.mode)
            (assert.are.equal "is required" (. messages "items[1].name"))))))

    (it "ignores undeclared argument fields for open objects"
      (fn []
        (let [(ok errors) (schema.validate {:type :object
                                            :properties {:name {:type :string}}}
                                           {:name "fen" :invented true})]
          (assert.is_true ok)
          (assert.is_nil errors))))

    (it "reports unsupported schema vocabulary clearly"
      (fn []
        (let [(ok errors) (schema.validate {:type :object :pattern "nope"} {})]
          (assert.is_nil ok)
          (assert.are.equal "arguments" (. errors 1 :field))
          (assert.is_truthy (string.find (. errors 1 :message)
                                          "unsupported schema keyword pattern" 1 true)))))))
