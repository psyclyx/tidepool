(def defaults
  "Default configuration."
  @{:border-width 4
    :outer-padding 4
    :inner-padding 8
    :outer-gap 4
    :inner-gap 8
    :peek-width 8
    :default-column-width 0.5
    :width-presets @[0.5 0.66 0.8 1.0]
    :main-ratio 0.55
    :main-count 1
    :default-layout :master-stack
    :column-width 0.5
    :dwindle-ratio 0.5
    :border-focused 0xffffff
    :border-normal 0x646464
    :border-urgent 0xff0000
    :border-insert 0x00ff88
    :anim-enabled true
    :anim-duration 200
    :anim-open-duration 150
    :anim-close-duration 120
    :anim-ease :ease-out-cubic
    :xcursor-theme "Adwaita"
    :xcursor-size 24
    :xkb-bindings @[]
    :pointer-bindings @[]
    :warp-cursor false
    :rules @[]
    :output-order @[]})

(defn init
  "Initialize the WM context with default state."
  [ctx]
  (put ctx :config (table/clone defaults))
  (put ctx :outputs @[])
  (put ctx :windows @[])
  (put ctx :seats @[])
  (put ctx :render-order @[])
  (put ctx :tag-layouts @{})
  (put ctx :tag-focus @{})
  (put ctx :tags @{})
  ctx)

(defn ensure-tag
  "Get or create tag state for a given tag id."
  [ctx tag-id]
  (or (get-in ctx [:tags tag-id])
      (let [tag @{:columns @[]
                  :camera 0
                  :focused-id nil
                  :insert-mode :sibling}]
        (put-in ctx [:tags tag-id] tag)
        tag)))

(defn remove-destroyed
  "Remove entries with :pending-destroy from array in-place."
  [arr]
  (var i 0)
  (while (< i (length arr))
    (if ((arr i) :pending-destroy)
      (array/remove arr i)
      (++ i))))

(defn reconcile-tags
  "Enforce tag invariants: no conflicts, every output has a tag."
  [ctx]
  (def outputs (ctx :outputs))
  (def focused
    (when-let [s (first (ctx :seats))]
      (s :focused-output)))
  # Collect all tags in use
  (def all-tags @{})
  (each o outputs (eachk tag (o :tags) (put all-tags tag true)))
  (each w (ctx :windows) (when (w :tag) (put all-tags (w :tag) true)))
  (def tags (sorted (keys all-tags)))
  # Focused output wins tag conflicts
  (when focused
    (each tag tags
      (when ((focused :tags) tag)
        (each o outputs
          (when (not= o focused)
            (put (o :tags) tag nil))))))
  # Assign orphaned tags to empty outputs
  (each tag tags
    (unless (find |(($ :tags) tag) outputs)
      (when-let [o (find |(empty? ($ :tags)) outputs)]
        (put (o :tags) tag true))))
  # Ensure every output has a tag — assign lowest unused integer if needed
  (each o outputs
    (when (empty? (o :tags))
      (def used @{})
      (each o2 outputs (eachk tag (o2 :tags) (put used tag true)))
      (var t 1)
      (while (used t) (++ t))
      (put (o :tags) t true)))
  # Track primary tag
  (each o outputs
    (put o :primary-tag (min-of (keys (o :tags))))))
