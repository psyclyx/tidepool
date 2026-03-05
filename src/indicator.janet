(import ./state)

(defn tags-changed []
  (when (state/config :indicator-file)
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (def focused-output (when-let [seat (first (state/wm :seats))]
                            (seat :focused-output)))
      (def occupied @{})
      (each window (state/wm :windows)
        (unless (window :closed)
          (put occupied (window :tag) true)))
      (def occupied-tags (sorted (keys occupied)))
      (def occupied-str (string/join (map string occupied-tags) ","))

      (def focused-tags
        (if focused-output
          (sorted (keys (focused-output :tags)))
          @[]))
      (def focused-str (string/join (map string focused-tags) ","))
      (spit (string rd "/tidepool-tags")
            (string "focused:" focused-str " occupied:" occupied-str))

      (each o (state/wm :outputs)
        (def output-tags (sorted (keys (o :tags))))
        (def output-str (string/join (map string output-tags) ","))
        (def active (= o focused-output))
        (spit (string rd "/tidepool-tags-" (o :x) "," (o :y))
              (string "focused:" output-str
                      " occupied:" occupied-str
                      " active:" (if active "true" "false")))
        (spit (string rd "/tidepool-layout-" (o :x) "," (o :y))
              (string (o :layout) "\n")))

      (when focused-output
        (spit (string rd "/tidepool-layout")
              (string (focused-output :layout) "\n"))))))

(defn layout-changed [o]
  (def name (string (o :layout)))
  (when (state/config :indicator-file)
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (spit (string rd "/tidepool-layout") (string name "\n"))
      (spit (string rd "/tidepool-layout-" (o :x) "," (o :y)) (string name "\n"))))
  (when (state/config :indicator-notify)
    (ev/spawn (os/proc-wait
      (os/spawn ["notify-send" "-t" "1000"
                 "-h" "string:x-canonical-private-synchronous:tidepool-layout"
                 "Layout" name] :p)))))
