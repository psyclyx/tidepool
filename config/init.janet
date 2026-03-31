(def config (ctx :config))

(def super {:mod4 true})
(def super-shift {:mod4 true :shift true})

(put config :xkb-bindings
  @[[:Return super (actions/spawn "foot")]
    [:q super-shift actions/close-focused]
    [:j super actions/focus-next]
    [:k super actions/focus-prev]
    [:j super-shift actions/swap-next]
    [:k super-shift actions/swap-prev]
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
