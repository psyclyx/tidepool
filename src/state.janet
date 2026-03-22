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
    :float-step 20
    :focus-follows-mouse false
    :warp-pointer false
    :xcursor-theme "Adwaita"
    :xcursor-size 24})

# Window key ownership:
#   window.janet:  :obj :node :tag :float :fullscreen :fullscreen-output
#                  :pre-fullscreen-pos
#                  :x :y :w :h :proposed-w :proposed-h :min-w :min-h :max-w :max-h
#                  :app-id :title :wl-parent :decoration-hint
#                  :new :closed :closing :visible :needs-ssd :float-changed
#                  :fullscreen-changed :fullscreen-requested
#                  :pointer-move-requested :pointer-resize-requested
#                  :border-status :border-rgb :border-width :border-applied-rgb
#                  :border-applied-width :vis-applied :clip-rect
#   scroll.janet:  :column :col-width :col-weight :row :scroll-placed
#   actions.janet:   :mark
#   animation.janet: :anim :anim-clip :anim-destroy :needs-open-anim
#   layout (all):  :layout-hidden :layout-meta

(def wm
  "Global window manager state."
  @{:config config
    :outputs @[]
    :seats @[]
    :windows @[]
    :render-order @[]
    :anim-active false})

(def tag-layouts "Per-tag layout persistence cache." @{})
(def tag-focus "Per-tag focused window memory." @{})
(def marks "User-assigned window marks (name -> window)." @{})

# Navigation trail: bounded deque with browser-style back/forward.
# Entries are {:window w :tag t}. Auto-pushed on cross-tag/output navigation.
(def nav-trail "Navigation history trail." @{:entries @[] :cursor nil :capacity 20})

(def output-state-cache "Cached output state for reconnecting monitors." @{})
(def registry "Wayland protocol object registry." @{})

(def- persistent-layout-keys
  "Layout param keys that survive cloning (config + scroll state).
  Everything else (animation targets, derived data, transient refs) is excluded."
  @{:main-ratio true :main-count true
    :column-width true :scroll-offset true :active-row true :row-states true
    :dwindle-ratio true :dwindle-ratios true})

(defn default-layout-params
  "Return a fresh table of default layout params."
  []
  @{:main-ratio (config :main-ratio)
    :main-count (config :main-count)
    :scroll-offset 0
    :column-width (config :column-width)
    :dwindle-ratio (config :dwindle-ratio)})

(defn clone-layout-params
  "Clone layout params, keeping only persistent keys."
  [params]
  (def out @{})
  (eachp [k v] params
    (when (persistent-layout-keys k)
      (put out k v)))
  out)

(defn action-context
  "Build the standard action dispatch context for a seat."
  [seat &opt binding]
  @{:seat seat :binding binding
    :outputs (wm :outputs) :windows (wm :windows)
    :render-order (wm :render-order) :config config
    :tag-layouts tag-layouts :registry registry})

# --- Pure operations on WM state ---

(defn remove-destroyed
  "Remove elements with :pending-destroy from an array in place."
  [arr]
  (var i 0)
  (while (< i (length arr))
    (if ((arr i) :pending-destroy)
      (array/remove arr i)
      (++ i))))

(defn reconcile-tags
  ``Enforce tag invariants: each tag 1-9 on at most one output (focused wins),
  tag 0 (scratchpad) exempt, every output has at least one tag,
  primary-tag changes trigger layout save/restore and focus memory.``
  [outputs focused tag-layouts tag-focus focused-window]

  # Tags 1-9: focused output wins conflicts
  (when focused
    (for tag 1 10
      (when ((focused :tags) tag)
        (each o outputs
          (when (not= o focused)
            (put (o :tags) tag nil))))))

  # Assign orphaned tags to empty outputs
  (for tag 1 10
    (unless (find |(($ :tags) tag) outputs)
      (when-let [o (find |(empty? ($ :tags)) outputs)]
        (put (o :tags) tag true))))

  # Save/restore per-tag layouts and focus on primary-tag change
  (each o outputs
    (def prev (o :primary-tag))
    (def curr (min-of (keys (o :tags))))
    (when (not= prev curr)
      (when prev
        (put tag-layouts prev
             @{:layout (o :layout)
               :params (clone-layout-params (o :layout-params))})
        (when focused-window
          (put tag-focus prev focused-window)))
      # Reset params to defaults before restoring saved state.
      # Without this, stale keys (active-row, scroll-offset, animation
      # keys) from the previous tag leak into the new one.
      (def params (o :layout-params))
      (table/clear params)
      (merge-into params (default-layout-params))
      (when-let [saved (get tag-layouts curr)]
        (put o :layout (saved :layout))
        (merge-into params (saved :params)))
      (put o :tag-focus-hint (get tag-focus curr))
      (put o :primary-tag curr))))
