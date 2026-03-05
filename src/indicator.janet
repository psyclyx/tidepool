(defn compute "Compute tag/layout status strings (pure)." [windows outputs focused-output config]
  (unless (config :indicator-file) (break nil))
  (def occupied @{})
  (each window windows
    (unless (window :closed)
      (put occupied (window :tag) true)))
  (def occupied-tags (sorted (keys occupied)))
  (def occupied-str (string/join (map string occupied-tags) ","))

  (def focused-tags
    (if focused-output
      (sorted (keys (focused-output :tags)))
      @[]))
  (def focused-str (string/join (map string focused-tags) ","))

  (def global-tags (string "focused:" focused-str " occupied:" occupied-str))
  (def global-layout
    (when focused-output (string (focused-output :layout) "\n")))

  (def per-output @[])
  (each o outputs
    (def output-tags (sorted (keys (o :tags))))
    (def output-str (string/join (map string output-tags) ","))
    (def active (= o focused-output))
    (array/push per-output
      @{:x (o :x) :y (o :y)
        :tags-str (string "focused:" output-str
                          " occupied:" occupied-str
                          " active:" (if active "true" "false"))
        :layout-str (string (o :layout) "\n")}))

  @{:global-tags global-tags
    :global-layout global-layout
    :per-output per-output})

(defn write "Write computed tag/layout status to runtime files (effectful)." [status]
  (when status
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (spit (string rd "/tidepool-tags") (status :global-tags))

      (each o (status :per-output)
        (spit (string rd "/tidepool-tags-" (o :x) "," (o :y)) (o :tags-str))
        (spit (string rd "/tidepool-layout-" (o :x) "," (o :y)) (o :layout-str)))

      (when (status :global-layout)
        (spit (string rd "/tidepool-layout") (status :global-layout))))))

(defn layout-changed "Notify layout change via files and optionally notify-send." [o config]
  (when (config :indicator-file)
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (def name (string (o :layout)))
      (spit (string rd "/tidepool-layout") (string name "\n"))
      (spit (string rd "/tidepool-layout-" (o :x) "," (o :y)) (string name "\n"))))
  (when (config :indicator-notify)
    (ev/spawn (os/proc-wait
      (os/spawn ["notify-send" "-t" "1000"
                 "-h" "string:x-canonical-private-synchronous:tidepool-layout"
                 "Layout" (string (o :layout))] :p)))))
