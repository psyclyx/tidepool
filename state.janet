# Shared mutable state for tidepool.
# Entry point populates these tables; other modules import them.

(def config
  @{:border-width 4
    :outer-padding 4
    :inner-padding 8
    :main-ratio 0.55
    :default-layout :master-stack
    :layouts [:master-stack :monocle :grid :centered-master :dwindle :columns]
    :dwindle-ratio 0.5
    :column-width 0.5
    :column-presets [0.333 0.5 0.667 1.0]
    :column-row-height 0
    :struts {:left 0 :right 0 :top 0 :bottom 0}
    :animate true
    :animation-duration 0.2
    :main-count 1
    :indicator-notify true
    :indicator-file true
    :background 0x000000
    :border-focused 0xffffff
    :border-normal 0x646464
    :border-urgent 0xff0000
    :xkb-bindings @[]
    :pointer-bindings @[]
    :rules @[]
    :warp-pointer false
    :xcursor-theme "Adwaita"
    :xcursor-size 24})

(def wm
  @{:config config
    :outputs @[]
    :seats @[]
    :windows @[]
    :render-order @[]
    :anim-active false})

# Per-tag layout storage: tag -> {:layout :kw :params @{...}}
(def tag-layouts @{})

(def output-state-cache @{})
(def registry @{})
