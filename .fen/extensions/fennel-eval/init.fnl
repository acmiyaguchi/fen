;; Repository-local development escape hatch.
;;
;; Keep the registration gate here instead of relying only on the manifest:
;; project-local extensions normally load by default, while this tool must
;; remain inert unless an operator opts in for the current process.

(fn enabled? []
  (= (os.getenv :FEN_FENNEL_EVAL) "1"))

(fn [api]
  (when (enabled?)
    (let [tool (api.load :tool)]
      (tool.register api)))
  true)
