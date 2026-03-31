(var- level :info)

(def- levels
  {:trace 0 :debug 1 :info 2 :warn 3 :error 4 :silent 5})

(defn set-level [l]
  (assert (levels l) (string "unknown log level: " l))
  (set level l))

(defn active? [lvl]
  (>= (levels lvl) (levels level)))

(defn- timestamp []
  (let [d (os/date nil :local)]
    (string/format "%02d:%02d:%02d"
                   (d :hours) (d :minutes) (d :seconds))))

(defn emit [lvl msg]
  (when (active? lvl)
    (printf "%s [%s] %s" (timestamp) lvl msg)))

(defn trace [msg] (emit :trace msg))
(defn debug [msg] (emit :debug msg))
(defn info [msg] (emit :info msg))
(defn warn [msg] (emit :warn msg))
(defn error [msg] (emit :error msg))

(defn tracef [fmt & args] (emit :trace (string/format fmt ;args)))
(defn debugf [fmt & args] (emit :debug (string/format fmt ;args)))
(defn infof [fmt & args] (emit :info (string/format fmt ;args)))
(defn warnf [fmt & args] (emit :warn (string/format fmt ;args)))
(defn errorf [fmt & args] (emit :error (string/format fmt ;args)))
