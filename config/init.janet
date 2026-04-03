(def config (ctx :config))

(put config :output-order
  @[{:match "GF005" :tag 1}
    {:match "BenQ" :tag 2}
    {:match "DELL" :tag 3}])

(def super {:mod4 true})
(def super-shift {:mod4 true :shift true})
(def super-ctrl {:mod4 true :ctrl true})

(put config :outer-padding 12)
(put config :peek-width 16)

(put config :xkb-bindings
  @[[:Return super (actions/spawn "foot")]
    [:q super-shift actions/close-focused]
    # Directional focus
    [:h super actions/focus-left]
    [:l super actions/focus-right]
    [:k super actions/focus-up]
    [:j super actions/focus-down]
    # Directional swap
    [:h super-shift actions/swap-left]
    [:l super-shift actions/swap-right]
    [:k super-shift actions/swap-up]
    [:j super-shift actions/swap-down]
    # Join / Leave
    [:h super-ctrl actions/join-left]
    [:l super-ctrl actions/join-right]
    [:k super-ctrl actions/join-up]
    [:j super-ctrl actions/join-down]
    [:space super-ctrl actions/leave]
    # Width
    [:r super actions/grow]
    # Insert mode
    [:i super actions/toggle-insert-mode]
    # Container mode
    [:t super actions/make-tabbed]
    [:s super actions/make-split]
    # Tab cycling
    [:Tab super actions/focus-tab-next]
    [:Tab super-shift actions/focus-tab-prev]
    # Output focus
    [:comma super actions/focus-output-prev]
    [:period super actions/focus-output-next]
    # Tags
    [:1 super (actions/focus-tag 1)]
    [:2 super (actions/focus-tag 2)]
    [:3 super (actions/focus-tag 3)]
    [:4 super (actions/focus-tag 4)]
    [:5 super (actions/focus-tag 5)]
    [:1 super-shift (actions/send-to-tag 1)]
    [:2 super-shift (actions/send-to-tag 2)]
    [:3 super-shift (actions/send-to-tag 3)]
    [:4 super-shift (actions/send-to-tag 4)]
    [:5 super-shift (actions/send-to-tag 5)]])
