(def config
  "Default configuration values."
  @{:border-width 4
    :outer-padding 4
    :inner-padding 8
    :main-ratio 0.55
    :default-layout :master-stack
    :layouts [:master-stack :grid :dwindle :scroll :tabbed]
    :dwindle-ratio 0.5
    :column-width 0.5
    :column-presets [0.333 0.5 0.667 1.0]
    :column-row-height 0
    :animate true
    :animation-duration 0.2
    :main-count 1
    :indicator-notify true
    :indicator-file true
    :background 0x000000
    :border-focused 0xffffff
    :border-normal 0x646464
    :border-urgent 0xff0000
    :border-tabbed 0x88aaff
    :border-sibling 0x888888
    :xkb-bindings @[]
    :pointer-bindings @[]
    :rules @[]
    :debug false
    :warp-pointer false
    :xcursor-theme "Adwaita"
    :xcursor-size 24})

(def wm
  "Global window manager state."
  @{:config config
    :outputs @[]
    :seats @[]
    :windows @[]
    :render-order @[]
    :anim-active false})

(def tag-layouts "Per-tag layout persistence cache." @{})

(def output-state-cache "Cached output state for reconnecting monitors." @{})
(def registry "Wayland protocol object registry." @{})
