(import ./dispatch)
(import ./state)
(import ./window)
(import ./seat)
(import ./layout)
(import ./output)
(import ./log)
(import ./ipc)
(import ./tree)
(import ./scroll)
(import ./anim)

# --- Chain runner ---

(defn run-chain [ctx chain]
  (each step chain (step ctx)))

# ============================================================
# Manage steps — data computation
# ============================================================

(defn- prune-closed [ctx]
  (def arr (ctx :render-order))
  (var i 0)
  (while (< i (length arr))
    (if (let [w (arr i)] (and (w :closed) (not (w :closing))))
      (array/remove arr i)
      (++ i))))

(defn- flag-destroyed [ctx]
  (each o (ctx :outputs)
    (when (o :removed) (put o :pending-destroy true)))
  (each w (ctx :windows)
    (when (w :closed) (put w :pending-destroy true)))
  (each s (ctx :seats)
    (when (s :removed) (put s :pending-destroy true))))

(defn- apply-destroys [ctx]
  (each o (ctx :outputs)
    (when (o :pending-destroy)
      (when (o :layer-shell) (:destroy (o :layer-shell)))
      (:destroy (o :obj))))
  (each w (ctx :windows)
    (when (w :pending-destroy)
      (:destroy (w :obj))
      (:destroy (w :node))))
  (each s (ctx :seats)
    (when (s :pending-destroy)
      (when (s :layer-shell) (:destroy (s :layer-shell)))
      (:destroy (s :obj))))
  (state/remove-destroyed (ctx :outputs))
  (state/remove-destroyed (ctx :windows))
  (state/remove-destroyed (ctx :seats))
  (state/remove-destroyed (ctx :render-order)))

(defn- sort-outputs [ctx]
  (def order (get-in ctx [:config :output-order]))
  (defn order-index [o]
    (var idx nil)
    (when (o :name)
      (each i (range (length order))
        (when (= ((order i) :name) (o :name))
          (set idx i)
          (break))))
    idx)
  (sort (ctx :outputs)
    (fn [a b]
      (let [ai (order-index a) bi (order-index b)]
        (cond
          (and ai bi) (< ai bi)
          ai true
          bi false
          # fallback: position-based
          (let [ax (or (a :x) 0) bx (or (b :x) 0)
                ay (or (a :y) 0) by (or (b :y) 0)]
            (if (= ax bx) (< ay by) (< ax bx))))))))

(defn- init-new-outputs [ctx]
  (def order (get-in ctx [:config :output-order]))
  (def used-tags @{})
  # Collect tags already in use by non-new outputs
  (each o (ctx :outputs)
    (when (not (o :new))
      (eachk tag (o :tags) (put used-tags tag true))))
  (each o (ctx :outputs)
    (when (and (o :new) (empty? (o :tags)))
      (var assigned false)
      # Try to assign tag from output-order config
      (when (o :name)
        (each entry order
          (when (and (= (entry :name) (o :name)) (entry :tag)
                     (not (used-tags (entry :tag))))
            (put (o :tags) (entry :tag) true)
            (put used-tags (entry :tag) true)
            (set assigned true)
            (break))))
      # Fallback: assign first unused integer tag
      (when (not assigned)
        (var t 1)
        (while (used-tags t) (++ t))
        (put (o :tags) t true)
        (put used-tags t true)))))

(defn- init-new-windows [ctx]
  (def config (ctx :config))
  (each w (ctx :windows)
    (when (w :new)
      (put w :needs-ssd (and (not (nil? (w :decoration-hint)))
                             (not= (w :decoration-hint) 0)))
      (if (and (w :wl-parent) (not ((w :wl-parent) :closed)))
        (do
          (window/set-float w true)
          (put w :tag ((w :wl-parent) :tag)))
        (do
          (window/set-float w false)
          (when (window/fixed-size? w)
            (window/set-float w true))
          (when-let [s (first (ctx :seats))
                     o (s :focused-output)]
            (put w :tag (or (min-of (keys (o :tags))) 1)))
          # Insert tiled windows into the tag's node tree
          (when (not (w :float))
            (def tag-id (w :tag))
            (def tag (state/ensure-tag ctx tag-id))
            (def leaf (tree/leaf w (config :default-column-width)))
            (put w :tree-leaf leaf)
            (if (= (tag :insert-mode) :child)
              # Insert into focused node's container
              (if-let [fid (tag :focused-id)
                       focused-leaf (do (var found nil)
                                      (each col (tag :columns)
                                        (when (not found)
                                          (set found (tree/find-leaf col fid))))
                                      found)]
                (if-let [p (focused-leaf :parent)]
                  # Insert after focused in its parent
                  (let [idx (inc (tree/child-index focused-leaf))]
                    (tree/insert-child p idx leaf))
                  # Focused is a bare column — wrap into vertical split
                  (tree/wrap-in-container (tag :columns) focused-leaf
                                          :split :vertical leaf :after))
                # No focus — just append as column
                (tree/insert-column (tag :columns) (length (tag :columns)) leaf))
              # :sibling mode — insert as new column after focused
              (let [insert-idx
                    (if-let [fid (tag :focused-id)
                             focused-leaf (do (var found nil)
                                            (each col (tag :columns)
                                              (when (not found)
                                                (set found (tree/find-leaf col fid))))
                                            found)]
                      (inc (or (tree/find-column-index (tag :columns) focused-leaf) -1))
                      (length (tag :columns)))]
                (tree/insert-column (tag :columns) insert-idx leaf)))
            # Set focus to new window
            (put tag :focused-id w)
            (tree/update-active-path leaf)))))))

(defn- init-new-seats [ctx]
  (each s (ctx :seats)
    (when (s :new)
      (each [keysym mods action-fn] ((ctx :config) :xkb-bindings)
        (seat/bind-key ctx s keysym mods action-fn)))))

(defn- process-focus [ctx]
  (each s (ctx :seats)
    # Clear stale focus
    (when-let [w (s :focused)]
      (when (or (w :closed) (w :pending-destroy))
        (put s :focused nil)))
    # Ensure focused output
    (when (or (not (s :focused-output))
              (and (s :focused-output) ((s :focused-output) :removed)))
      (seat/focus-output s (first (ctx :outputs))))
    # Focus new windows on active tag
    (each w (ctx :windows)
      (when (and (w :new)
                 (when-let [o (s :focused-output)]
                   ((o :tags) (w :tag))))
        (seat/focus s w)))
    # Clicked window gets focus
    (when-let [w (s :window-interaction)]
      (seat/focus s w))
    # Pending actions (keybindings + IPC)
    (each action-fn (s :pending-actions)
      (try
        (action-fn ctx s)
        ([err fib]
          (log/errorf "action failed: %s" err)
          (debug/stacktrace fib err ""))))))

(defn- run-layout [ctx]
  (def config (ctx :config))
  (each w (ctx :windows) (put w :layout-hidden nil))
  (each o (ctx :outputs)
    (def tiled (filter |(and (not ($ :float))
                             (not ($ :fullscreen))
                             (not ($ :closed)))
                       (output/visible o (ctx :windows))))
    (when (not (empty? tiled))
      (def usable (output/usable-area o))
      (def results (layout/master-stack usable tiled
                                        (o :layout-params) config))
      (each r results
        (if (r :hidden)
          (put (r :window) :layout-hidden true)
          (do
            (window/set-position (r :window) (r :x) (r :y))
            (window/propose-dimensions (r :window)
                                       (r :w) (r :h) config)))))))

(defn- remove-closed-from-tree [ctx]
  (each w (ctx :windows)
    (when (and (w :closed) (w :tree-leaf))
      (def leaf (w :tree-leaf))
      (when-let [tag-id (w :tag)
                 tag (get-in ctx [:tags tag-id])]
        (def columns (tag :columns))
        (def col-idx (tree/find-column-index columns leaf))
        (def child-idx (or (tree/child-index leaf) 0))
        # Remove from tree
        (def [col-removed result] (tree/remove-leaf columns leaf))
        # Update focus if this was the focused window
        (when (= (tag :focused-id) w)
          (def successor (tree/focus-successor columns
                           (or col-idx 0) child-idx
                           (if col-removed nil result)))
          (if successor
            (do (put tag :focused-id (successor :window))
                (tree/update-active-path successor))
            (put tag :focused-id nil))))
      (put w :tree-leaf nil))))

(defn- adopt-orphan-windows [ctx]
  "Ensure all tiled, non-closed windows have a tree-leaf."
  (def config (ctx :config))
  (each w (ctx :windows)
    (when (and (not (w :tree-leaf))
               (not (w :float))
               (not (w :closed))
               (not (w :pending-destroy))
               (w :tag))
      (def tag-id (w :tag))
      (def tag (state/ensure-tag ctx tag-id))
      (def leaf (tree/leaf w (config :default-column-width)))
      (put w :tree-leaf leaf)
      (tree/insert-column (tag :columns) (length (tag :columns)) leaf)
      (when (nil? (tag :focused-id))
        (put tag :focused-id w)
        (tree/update-active-path leaf)))))

(defn- sync-tree-focus [ctx]
  "Sync seat focus from the tag tree's focused-id."
  (each s (ctx :seats)
    (when-let [o (s :focused-output)
               tag-id (o :primary-tag)
               tag (get-in ctx [:tags tag-id])
               fwin (tag :focused-id)]
      (when (and fwin (not (fwin :closed)) (not (fwin :pending-destroy)))
        (seat/focus s fwin)))))

(defn- run-scroll-layout [ctx]
  (def config (ctx :config))
  (def scroll-config @{:peek-width (config :peek-width)
                        :border-width (config :border-width)
                        :inner-gap (config :inner-gap)
                        :outer-gap (config :outer-gap)})
  # Save previous positions for animation
  (each w (ctx :windows)
    (put w :prev-x (w :x))
    (put w :prev-y (w :y))
    (put w :prev-w (w :proposed-w))
    (put w :prev-h (w :proposed-h)))
  (each w (ctx :windows) (put w :layout-hidden nil))
  (each o (ctx :outputs)
    (when-let [tag-id (o :primary-tag)
               tag (get-in ctx [:tags tag-id])]
      (def columns (tag :columns))
      (when (not (empty? columns))
        (def usable (output/usable-area o))
        (def output-rect {:x (or (o :x) 0) :y (or (o :y) 0)
                          :w (or (o :w) 1920) :h (or (o :h) 1080)})
        # Find focused leaf
        (var focus-leaf nil)
        (when (tag :focused-id)
          (each col columns
            (when (not focus-leaf)
              (set focus-leaf (tree/find-leaf col (tag :focused-id))))))
        (def result (scroll/scroll-layout columns focus-leaf
                                           (tag :camera) output-rect usable
                                           scroll-config))
        # Update camera
        (put tag :camera (result :camera))
        # Apply placements
        (each p (result :placements)
          (def w (p :window))
          (window/set-position w (p :x) (p :y))
          (window/propose-dimensions w (p :w) (p :h) config)
)))))
  # Mark windows not placed by scroll layout as hidden
  (each w (ctx :windows)
    (when (and (not (w :float)) (not (w :closed)) (not (w :x)))
      (put w :layout-hidden true))))

(defn- start-animations [ctx]
  (def config (ctx :config))
  (when (not (config :anim-enabled)) (break))
  (def duration (config :anim-duration))
  (def open-dur (config :anim-open-duration))
  (def close-dur (config :anim-close-duration))
  (each w (ctx :windows)
    (when (and (w :x) (w :y) (not (w :closed)) (not (w :float)))
      # Only animate if window had a previous position (not new)
      (when (and (w :prev-x) (w :prev-y) (not (w :new)))
        # Temporarily set w's position to prev so set-targets sees the delta
        (def target-x (w :x))
        (def target-y (w :y))
        (def target-w (w :proposed-w))
        (def target-h (w :proposed-h))
        (put w :x (w :prev-x))
        (put w :y (w :prev-y))
        (put w :w (or (w :prev-w) (w :w)))
        (put w :h (or (w :prev-h) (w :h)))
        (anim/set-targets w target-x target-y
                          (or target-w (w :w)) (or target-h (w :h))
                          duration)
        # Restore targets
        (put w :x target-x)
        (put w :y target-y)))
    # Open animation for new windows
    (when (and (w :new) (not (w :float)))
      (anim/start-open w open-dur))
    # Close animation
    (when (and (w :closed) (not (w :closing)) (w :tree-leaf))
      (anim/start-close w close-dur)))
  # Camera animations
  (eachp [_ tag] (ctx :tags)
    (anim/set-camera-target tag (tag :camera) duration)))

(defn- compute-borders [ctx]
  (def config (ctx :config))
  (def focused (when-let [s (first (ctx :seats))] (s :focused)))
  (each w (ctx :windows)
    (when (not (or (w :closed) (w :pending-destroy)))
      (window/set-borders w
        (if (= w focused) :focused :normal)
        config))))

(defn- compute-visibility [ctx]
  (window/compute-visibility (ctx :outputs) (ctx :windows)))

# ============================================================
# Manage steps — effect application
# ============================================================

(defn- apply-window-config [ctx]
  (each w (ctx :windows)
    (when (w :needs-ssd)
      (:use-ssd (w :obj)))
    (when (w :float-changed)
      (if (w :float)
        (:set-tiled (w :obj) {})
        (:set-tiled (w :obj) {:left true :bottom true :top true :right true})))
    (when (and (w :proposed-w) (w :proposed-h))
      (:propose-dimensions (w :obj) (w :proposed-w) (w :proposed-h)))))

(defn- apply-focus [ctx]
  (each s (ctx :seats)
    (when (s :focus-changed)
      (if-let [w (s :focused)]
        (do (:focus-window (s :obj) (w :obj))
            (:place-top (w :node)))
        (:clear-focus (s :obj))))
    (when (s :focus-output-changed)
      (when-let [o (s :focused-output)]
        (when (o :layer-shell)
          (:set-default (o :layer-shell)))))))

(def- all-edges {:left true :bottom true :top true :right true})

(defn- apply-borders [ctx]
  (each w (ctx :windows)
    (when (and (w :border-rgb)
               (or (not= (w :border-rgb) (w :border-applied-rgb))
                   (not= (w :border-width) (w :border-applied-width))))
      (put w :border-applied-rgb (w :border-rgb))
      (put w :border-applied-width (w :border-width))
      (:set-borders (w :obj) all-edges (w :border-width)
                    ;(output/rgb-to-u32-rgba (w :border-rgb))))))

(defn- apply-visibility [ctx]
  (each w (ctx :windows)
    (def vis (w :visible))
    (unless (= vis (w :vis-applied))
      (if vis
        (do (put w :vis-applied vis) (:show (w :obj)))
        (when (w :w)
          (put w :vis-applied vis)
          (:hide (w :obj)))))))

(defn- clear-transient [ctx]
  (each o (ctx :outputs) (put o :new nil))
  (each w (ctx :windows)
    (put w :new nil)
    (put w :needs-ssd nil)
    (put w :float-changed nil)
    (put w :proposed-w nil)
    (put w :proposed-h nil)
    (put w :prev-x nil)
    (put w :prev-y nil)
    (put w :prev-w nil)
    (put w :prev-h nil))
  (each s (ctx :seats)
    (put s :new nil)
    (array/clear (s :pending-actions))
    (put s :focus-changed nil)
    (put s :focus-output-changed nil)
    (put s :window-interaction nil)
    (put s :pointer-moved nil)))

(defn- signal-manage-done [ctx]
  (:manage-finish
    (get-in ctx [:registry :proxies "river_window_manager_v1"])))

# ============================================================
# Render steps
# ============================================================

(defn- center-unplaced [ctx]
  (each w (ctx :windows)
    (when (and (not (w :x)) (w :w))
      (if-let [o (window/tag-output w (ctx :outputs))]
        (window/set-position w
          (+ (o :x) (div (- (o :w) (w :w)) 2))
          (+ (o :y) (div (- (o :h) (w :h)) 2)))
        (window/set-position w 0 0)))))

(defn- tick-animations [ctx]
  (def config (ctx :config))
  (when (not (config :anim-enabled)) (break))
  (def now (os/clock :monotonic))
  (def last-time (or (ctx :anim-last-time) now))
  (def dt (* (- now last-time) 1000)) # convert to ms
  (put ctx :anim-last-time now)
  (when (< dt 0.1) (break)) # skip if dt is negligible (first frame)
  (def ease-fn (or (anim/easing-fns (config :anim-ease)) anim/ease-out-cubic))
  (each w (ctx :windows)
    (anim/tick-window w dt ease-fn))
  (eachp [_ tag] (ctx :tags)
    (anim/tick-camera tag dt ease-fn)))

(defn- apply-positions [ctx]
  (each w (ctx :windows)
    (when (and (w :visible) (w :node))
      (def [x y] (anim/resolve-position w))
      (when (and x y)
        (:set-position (w :node) (math/round x) (math/round y))))))

(defn- apply-clips [ctx]
  (each w (ctx :windows)
    (when (and (w :visible) (w :obj))
      # Compute clip from animated position and output geometry
      (def clip
        (when-let [o (window/tag-output w (ctx :outputs))]
          (let [[ax ay] (anim/resolve-position w)
                aw (or (w :w) 0)
                ah (or (w :h) 0)]
            (scroll/clip-rect ax aw ay ah
                              (or (o :x) 0) (or (o :y) 0)
                              (or (o :w) 1920) (or (o :h) 1080)))))
      (if clip
        (:set-clip-box (w :obj)
                       (math/round (clip :clip-x)) (math/round (clip :clip-y))
                       (math/round (clip :clip-w)) (math/round (clip :clip-h)))
        (when (w :clip-applied)
          (:set-clip-box (w :obj) 0 0 0 0)))
      (put w :clip-applied clip))))

(defn- signal-render-done [ctx]
  (:render-finish
    (get-in ctx [:registry :proxies "river_window_manager_v1"])))

# ============================================================
# Chains — mutable arrays, modifiable at the REPL
# ============================================================

(def manage-chain
  @[prune-closed
    flag-destroyed
    remove-closed-from-tree
    ipc/emit-close-events
    apply-destroys
    sort-outputs
    init-new-outputs
    init-new-windows
    init-new-seats
    process-focus
    state/reconcile-tags
    adopt-orphan-windows
    sync-tree-focus
    run-scroll-layout
    start-animations
    compute-borders
    compute-visibility
    # --- effects ---
    apply-window-config
    apply-focus
    apply-borders
    apply-visibility
    ipc/emit-state-events
    clear-transient
    signal-manage-done])

(def render-chain
  @[tick-animations
    center-unplaced
    apply-positions
    apply-clips
    signal-render-done])

# ============================================================
# Event registration
# ============================================================

(dispatch/reg-event :manage
  (fn [ctx] (run-chain ctx manage-chain) nil))

(dispatch/reg-event :render
  (fn [ctx] (run-chain ctx render-chain) nil))
