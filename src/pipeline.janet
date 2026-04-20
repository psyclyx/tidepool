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

# --- Tag → output index ---

(defn- build-tag-output-index [ctx]
  "Build a tag→output lookup table on ctx for O(1) per-window lookups."
  (def idx @{})
  (each o (ctx :outputs)
    (eachk tag (o :tags) (put idx tag o)))
  (put ctx :tag-output-index idx))

(defn tag-output
  "O(1) tag→output lookup using precomputed index."
  [ctx w]
  (get (ctx :tag-output-index) (w :tag)))

# --- Tag state persistence ---

(defn- tag-state-path []
  "Path for saving window-tag state, scoped to wayland socket, in tmpfs."
  (def runtime-dir (or (os/getenv "XDG_RUNTIME_DIR") "/tmp"))
  (def wl-display (or (os/getenv "WAYLAND_DISPLAY") "wayland-0"))
  (string runtime-dir "/tidepool-" wl-display "-tags.jdn"))

(defn- save-tag-state [ctx]
  "Save window app-id/title → tag mapping for restart recovery."
  (def entries @[])
  (each w (ctx :windows)
    (when (and (w :app-id) (w :tag) (not (w :closed)))
      (array/push entries {:app-id (w :app-id)
                           :title (or (w :title) "")
                           :tag (w :tag)
                           :float (truthy? (w :float))})))
  (try
    (spit (tag-state-path) (string/format "%j" entries))
    ([err] (log/debugf "failed to save tag state: %s" err))))

(defn- load-tag-state []
  "Load saved window-tag state. Returns array of entries or nil."
  (try
    (do (def raw (slurp (tag-state-path)))
        (parse raw))
    ([err] nil)))

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

(defn- destroy-decoration [ctx w]
  "Clean up a window's decoration surface and related objects."
  (ipc/emit-decoration-destroy ctx w)
  (when-let [buf (w :decoration-buffer)]
    (:destroy buf)
    (put w :decoration-buffer nil))
  (when-let [deco (w :decoration)]
    (:destroy deco)
    (put w :decoration nil))
  (when-let [vp (w :decoration-viewport)]
    (:destroy vp)
    (put w :decoration-viewport nil))
  (when-let [surf (w :decoration-surface)]
    (:destroy surf)
    (put w :decoration-surface nil))
  (put w :decoration-color nil))

(defn- apply-destroys [ctx]
  (each o (ctx :outputs)
    (when (o :pending-destroy)
      (when (o :layer-shell) (:destroy (o :layer-shell)))
      (:destroy (o :obj))))
  (each w (ctx :windows)
    (when (w :pending-destroy)
      (destroy-decoration ctx w)
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

(defn- output-matches-entry? [o entry]
  "Check if output matches an order entry by :name (exact) or :match (substring of name or description)."
  (cond
    (entry :match)
    (let [pat (string/ascii-lower (entry :match))]
      (or (and (o :name) (string/find pat (string/ascii-lower (o :name))))
          (and (o :description) (string/find pat (string/ascii-lower (o :description))))))
    (entry :name)
    (= (o :name) (entry :name))))

(defn- sort-outputs [ctx]
  (def order (get-in ctx [:config :output-order]))
  (defn order-index [o]
    (var idx nil)
    (each i (range (length order))
      (when (output-matches-entry? o (order i))
        (set idx i)
        (break)))
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
      (each entry order
        (when (and (output-matches-entry? o entry) (entry :tag)
                   (not (used-tags (entry :tag))))
          (put (o :tags) (entry :tag) true)
          (put used-tags (entry :tag) true)
          (set assigned true)
          (break)))
      # Fallback: assign first unused integer tag
      (when (not assigned)
        (var t 1)
        (while (used-tags t) (++ t))
        (put (o :tags) t true)
        (put used-tags t true))))
  # Re-assign tags when description first arrives and config specifies a different tag
  (each o (ctx :outputs)
    (when (and (not (o :new)) (o :description) (not (o :description-applied)))
      (put o :description-applied true)
      (each entry order
        (when (and (output-matches-entry? o entry) (entry :tag)
                   (not ((o :tags) (entry :tag))))
          # Swap tags with whoever currently holds our desired tag
          (def desired (entry :tag))
          (def current-tag (min-of (keys (o :tags))))
          (def holder (find |(and (not= $ o) (($ :tags) desired)) (ctx :outputs)))
          (when holder
            (put (holder :tags) desired nil)
            (put (holder :tags) current-tag true))
          (table/clear (o :tags))
          (put (o :tags) desired true)
          (break))))))

(defn- match-saved-tag
  "Find and consume a saved entry matching this window. Returns tag-id or nil."
  [w saved]
  (when saved
    # Prefer exact app-id + title match, then app-id only
    (var best nil)
    (for i 0 (length saved)
      (def entry (saved i))
      (when (and entry (= (entry :app-id) (w :app-id)))
        (if (= (entry :title) (or (w :title) ""))
          (do (set best i) (break))
          (when (nil? best) (set best i)))))
    (when best
      (def entry (saved best))
      (put saved best nil)
      (entry :tag))))

(defn- assign-tag-for-new-window
  "Pick a tag for a new window: saved state > focused output > round-robin."
  [ctx w saved rr-counter]
  (def outputs (ctx :outputs))
  # Try saved state first
  (def saved-tag (match-saved-tag w saved))
  (if saved-tag
    saved-tag
    # Round-robin across outputs when bulk-adopting (multiple new windows)
    (if (and (> rr-counter 0) (> (length outputs) 1))
      (let [idx (% rr-counter (length outputs))
            o (outputs idx)]
        (or (min-of (keys (o :tags))) 1))
      # Single new window: use focused output
      (when-let [s (first (ctx :seats))
                 o (s :focused-output)]
        (or (min-of (keys (o :tags))) 1)))))

(defn- init-new-windows [ctx]
  (def config (ctx :config))
  (def new-windows (filter |($ :new) (ctx :windows)))
  # Load saved state only when bulk-adopting (restart scenario)
  (def saved (when (> (length new-windows) 1) (load-tag-state)))
  (var rr-counter 0)
  (each w new-windows
    (put w :needs-ssd (and (not (nil? (w :decoration-hint)))
                           (not= (w :decoration-hint) :only-supports-csd)))
    (if (and (w :wl-parent) (not ((w :wl-parent) :closed)))
      (do
        (window/set-float w true)
        (put w :tag ((w :wl-parent) :tag)))
      (do
        (window/set-float w (window/should-float? w (config :rules)))
        (put w :tag (assign-tag-for-new-window ctx w saved rr-counter))
        (++ rr-counter)
        # Insert tiled windows into the tag's node tree as new columns
        (when (not (w :float))
          (def tag-id (w :tag))
          (def tag (state/ensure-tag ctx tag-id))
          (def leaf (tree/leaf w (config :default-column-width)))
          (put w :tree-leaf leaf)
          (let [insert-idx
                (if-let [fid (tag :focused-id)
                         focused-leaf (fid :tree-leaf)]
                  (inc (or (tree/find-column-index (tag :columns) focused-leaf) -1))
                  (length (tag :columns)))]
            (tree/insert-column (tag :columns) insert-idx leaf))
          # Set focus to new window
          (put tag :focused-id w)
          (tree/update-active-path leaf))))
    # Propose 0x0 for float windows so compositor configures the client
    (when (and (w :float) (not (w :w)))
      (put w :proposed-w 0)
      (put w :proposed-h 0))))

(defn- init-new-seats [ctx]
  (each s (ctx :seats)
    (when (s :new)
      (each [keysym mods action-fn] ((ctx :config) :xkb-bindings)
        (seat/bind-key ctx s keysym mods action-fn)))))

(defn- process-focus [ctx]
  (each s (ctx :seats)
    # Re-assert focus after layer shell releases exclusive focus
    (when (and (= (s :layer-focus-prev) :exclusive)
               (not= (s :layer-focus) :exclusive))
      (put s :focus-changed true))
    (put s :layer-focus-prev (s :layer-focus))
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
    # Clicked window gets focus + output follows + update tag tree
    (when-let [w (s :window-interaction)]
      (when-let [tag-id (w :tag)
                 o (find |(($ :tags) tag-id) (ctx :outputs))]
        (seat/focus-output s o))
      (seat/focus s w)
      # Update tag tree so sync-tree-focus doesn't override
      (when-let [leaf (w :tree-leaf)]
        (when-let [tag-id (w :tag)
                   tag (get-in ctx [:tags tag-id])]
          (put tag :focused-id w)
          (tree/update-active-path leaf))))
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

(defn- promote-late-floats [ctx]
  "Convert tiled windows to float when size hints arrive after manage."
  (def config (ctx :config))
  (each w (ctx :windows)
    (when (and (w :hints-changed)
               (w :tree-leaf)
               (not (w :float))
               (not (w :closed))
               (not (w :new)))
      (put w :hints-changed nil)
      (when (window/should-float? w (get config :rules []))
        (def leaf (w :tree-leaf))
        (when-let [tag-id (w :tag)
                   tag (get-in ctx [:tags tag-id])]
          (def columns (tag :columns))
          (def col-idx (tree/find-column-index columns leaf))
          (def child-idx (or (tree/child-index leaf) 0))
          (def [col-removed result] (tree/remove-leaf columns leaf))
          (when (= (tag :focused-id) w)
            (def successor (tree/focus-successor columns
                             (or col-idx 0) child-idx
                             (if col-removed nil result)))
            (if successor
              (do (put tag :focused-id (successor :window))
                  (tree/update-active-path successor))
              (put tag :focused-id nil))))
        (put w :tree-leaf nil)
        (window/set-float w true)))))

(defn- adopt-orphan-windows [ctx]
  "Ensure all non-closed windows have a tree-leaf (tiled) or are floated."
  (def config (ctx :config))
  (each w (ctx :windows)
    (when (and (not (w :tree-leaf))
               (not (w :float))
               (not (w :closed))
               (not (w :pending-destroy))
               (w :tag))
      # Apply float logic — same rules as init-new-windows
      (when (window/should-float? w (config :rules))
        (window/set-float w true)
        (when (not (w :w))
          (put w :proposed-w 0)
          (put w :proposed-h 0)))
      (when (not (w :float))
        (def tag-id (w :tag))
        (def tag (state/ensure-tag ctx tag-id))
        (def leaf (tree/leaf w (config :default-column-width)))
        (put w :tree-leaf leaf)
        (tree/insert-column (tag :columns) (length (tag :columns)) leaf)
        (when (nil? (tag :focused-id))
          (put tag :focused-id w)
          (tree/update-active-path leaf))))))

(defn- sync-tree-focus [ctx]
  "Sync seat focus from the tag tree's focused-id."
  (each s (ctx :seats)
    (when-let [o (s :focused-output)
               tag-id (o :primary-tag)
               tag (get-in ctx [:tags tag-id])
               fwin (tag :focused-id)]
      # Don't override if seat is focused on a visible float on the active tag
      (def current (s :focused))
      (def on-float (and current (current :float) (not (current :closed))
                         (= (current :tag) tag-id)))
      (when (and (not on-float) fwin (not (fwin :closed)) (not (fwin :pending-destroy)))
        (seat/focus s fwin)))))

(defn- process-pointer-ops [ctx]
  "Start and apply pointer move/resize operations on floating windows."
  (each w (ctx :windows)
    (when-let [seat (w :pointer-move-requested)]
      (when (w :float)
        (put seat :op @{:type :move :window w
                        :origin-vx (or (w :float-vx) 0)
                        :origin-vy (or (w :float-vy) 0)})
        (:op-start-pointer (seat :obj)))
      (put w :pointer-move-requested nil)))
  (each s (ctx :seats)
    (when-let [op (s :op)]
      (when-let [dx (op :dx)
                 dy (op :dy)]
        (def w (op :window))
        (case (op :type)
          :move
          (do
            (put w :float-vx (+ (op :origin-vx) dx))
            (put w :float-vy (+ (op :origin-vy) dy))))))
    (when (s :op-release)
      (put s :op nil)
      (put s :op-release nil))))

(defn- run-scroll-layout [ctx]
  (def config (ctx :config))
  (def scroll-config @{:peek-width (config :peek-width)
                        :border-width (config :border-width)
                        :inner-gap (config :inner-gap)
                        :outer-gap (config :outer-gap)
                        :decoration-height (or (config :decoration-height) 0)})
  # Save previous positions for animation (y, w, h only — x is camera-driven)
  (each w (ctx :windows)
    (put w :prev-y (w :y))
    (put w :prev-w (if (not (nil? (w :proposed-w))) (w :proposed-w) (w :w)))
    (put w :prev-h (if (not (nil? (w :proposed-h))) (w :proposed-h) (w :h))))
  # Clear placement state so every window gets fresh data from scroll-layout
  (each w (ctx :windows)
    (put w :layout-hidden nil)
    (when (and (not (w :float)) (not (w :closed)))
      (put w :x nil)
      (put w :vx nil)))
  # Save previous camera before layout overwrites it
  (eachp [_ tag] (ctx :tags)
    (put tag :prev-camera (tag :camera)))
  (each o (ctx :outputs)
    (when-let [tag-id (o :primary-tag)
               tag (get-in ctx [:tags tag-id])]
      (def columns (tag :columns))
      (when (not (empty? columns))
        (def usable (output/usable-area o))
        (def output-rect {:x (or (o :x) 0) :y (or (o :y) 0)
                          :w (or (o :w) 1920) :h (or (o :h) 1080)})
        # Find focused leaf via cached tree-leaf on the window
        (def focus-leaf
          (when-let [fid (tag :focused-id)] (fid :tree-leaf)))
        (def result (scroll/scroll-layout columns focus-leaf
                                           (tag :camera) output-rect usable
                                           scroll-config))
        # Update camera
        (put tag :camera (result :camera))
        # Apply placements — store virtual x and screen y
        (each p (result :placements)
          (def w (p :window))
          (put w :vx (p :vx))
          (put w :y (p :y))
          (put w :x true) # mark as placed (for layout-hidden check)
          (window/propose-dimensions w (p :w) (p :h) config)))))
  # Mark windows not placed by scroll layout as hidden
  (each w (ctx :windows)
    (when (and (not (w :float)) (not (w :fullscreen)) (not (w :closed)) (not (w :x)))
      (put w :layout-hidden true))))

(defn- start-animations [ctx]
  (def config (ctx :config))
  (when (not (config :anim-enabled)) (break))
  (def duration (config :anim-duration))
  (def open-dur (config :anim-open-duration))
  (def close-dur (config :anim-close-duration))
  (each w (ctx :windows)
    (when (and (w :vx) (w :y) (not (w :closed)) (not (w :float)))
      # Animate y/w/h if window had a previous position (not new)
      (when (and (w :prev-y) (not (w :new)))
        (anim/set-targets w (w :y) (w :proposed-w) (w :proposed-h)
                          duration
                          (w :prev-y) (w :prev-w) (w :prev-h))))
    # Open animation for new windows
    (when (and (w :new) (not (w :float)))
      (anim/start-open w open-dur))
    # Close animation
    (when (and (w :closed) (not (w :closing)) (w :tree-leaf))
      (anim/start-close w close-dur)))
  # Camera animation — the primary driver for horizontal scrolling
  (eachp [_ tag] (ctx :tags)
    (anim/set-camera-target tag (tag :camera) duration (tag :prev-camera)))
  # Reset animation clock so the render chain measures dt from now,
  # not from the last idle render (which may be ~960ms ago).
  (when (anim/any-animating? ctx)
    (put ctx :anim-last-time (os/clock :monotonic))))

(defn- process-fullscreen [ctx]
  "Handle fullscreen requests from clients and toggle-fullscreen action.
   Also exits fullscreen when the fullscreen output is removed."
  (each w (ctx :windows)
    # Exit fullscreen if the output was removed
    (when (and (w :fullscreen) (w :fullscreen-output)
               ((w :fullscreen-output) :removed))
      (put w :fullscreen nil)
      (put w :fullscreen-output nil))
    (when-let [req (w :fullscreen-requested)]
      (put w :fullscreen-requested nil)
      (match req
        [:enter output]
        (let [o (or output (tag-output ctx w))]
          (when (and o (not (w :fullscreen)))
            (put w :fullscreen true)
            (put w :fullscreen-output o)))
        [:exit]
        (when (w :fullscreen)
          (put w :fullscreen nil)
          (put w :fullscreen-output nil))))))

(defn- apply-fullscreen [ctx]
  "Send fullscreen/exit-fullscreen protocol requests."
  (each w (ctx :windows)
    (when (not= (w :fullscreen) (w :fullscreen-applied))
      (if (w :fullscreen)
        (when-let [o (w :fullscreen-output)]
          (:fullscreen (w :obj) (o :obj))
          (:inform-fullscreen (w :obj))
          (put w :fullscreen-applied true))
        (do
          (:exit-fullscreen (w :obj))
          (:inform-not-fullscreen (w :obj))
          (put w :fullscreen-applied nil)
          # Force re-proposal of dimensions on the next cycle
          (put w :last-proposed-w nil)
          (put w :last-proposed-h nil))))))

# ============================================================
# Decoration surfaces (river_decoration_v1)
# ============================================================

(defn- create-decorations [ctx]
  "Create decoration surfaces for tiled windows that don't have one yet.
   Uses single-pixel-buffer as placeholder content. Also destroys decorations
   when decoration-height drops to 0 (decorator disconnected)."
  (def config (ctx :config))
  (def dh (config :decoration-height))
  # Destroy all decorations if height is 0
  (when (<= dh 0)
    (each w (ctx :windows)
      (when (w :decoration) (destroy-decoration ctx w)))
    (break))
  (def compositor (get-in ctx [:registry :proxies "wl_compositor"]))
  (def spb (get-in ctx [:registry :proxies "wp_single_pixel_buffer_manager_v1"]))
  (def vp (get-in ctx [:registry :proxies "wp_viewporter"]))
  (when (not (and compositor spb vp)) (break))
  (each w (ctx :windows)
    (when (and (not (w :float)) (not (w :fullscreen))
               (not (w :closed)) (not (w :pending-destroy))
               (not (w :decoration)))
      (def wl-surface (:create-surface compositor))
      (def deco (:get-decoration-above (w :obj) wl-surface))
      (def viewport (:get-viewport vp wl-surface))
      (put w :decoration deco)
      (put w :decoration-surface wl-surface)
      (put w :decoration-viewport viewport)
      (put w :decoration-color nil)
      (ipc/emit-decoration-create ctx w))))

(defn- update-decoration-colors [ctx]
  "Set decoration color based on focus state. Creates single-pixel-buffer
   and attaches when color changes. Destroys decorations on floated windows."
  (def config (ctx :config))
  (def dh (config :decoration-height))
  (def spb (get-in ctx [:registry :proxies "wp_single_pixel_buffer_manager_v1"]))
  (each w (ctx :windows)
    # Remove decorations from floated or fullscreen windows
    (when (and (w :decoration) (or (w :float) (w :fullscreen)))
      (destroy-decoration ctx w))
    # Update colors on existing decorations
    (when (and (w :decoration) spb (> dh 0))
      (def focused (when-let [s (first (ctx :seats))] (s :focused)))
      (def color (if (= w focused)
                   (config :border-focused)
                   (config :border-normal)))
      (when (not= color (w :decoration-color))
        (put w :decoration-color color)
        (def [r g b a] (output/rgb-to-u32-rgba color))
        (def buffer (:create-u32-rgba-buffer spb r g b a))
        (:attach (w :decoration-surface) buffer 0 0)
        (put w :decoration-dirty true)))))

(defn- apply-decorations [ctx]
  "Render-chain step: position decoration surfaces and commit.
   Only commits when decoration state has changed (size or buffer)
   to avoid per-frame protocol overhead."
  (def config (ctx :config))
  (def dh (config :decoration-height))
  (when (<= dh 0) (break))
  (def bw (config :border-width))
  (each w (ctx :windows)
    (when (and (w :decoration) (w :visible) (not (w :render-hidden)))
      (def [rw _] (anim/resolve-dimensions w))
      (def win-w (or rw (w :proposed-w) (w :w) 0))
      (def deco-w (max 1 (+ win-w (* 2 bw))))
      # Only update if dimensions changed or buffer was attached
      (when (or (w :decoration-dirty)
                (not= deco-w (w :decoration-applied-w)))
        (put w :decoration-applied-w deco-w)
        (put w :decoration-dirty nil)
        (:set-destination (w :decoration-viewport) deco-w dh)
        (:set-offset (w :decoration) (- bw) (- 0 dh bw))
        (:sync-next-commit (w :decoration))
        (:commit (w :decoration-surface))))))

(defn- compute-borders [ctx]
  (def config (ctx :config))
  (def focused (when-let [s (first (ctx :seats))] (s :focused)))
  (each w (ctx :windows)
    (when (not (or (w :closed) (w :pending-destroy)))
      (window/set-borders w
        (if (= w focused) :focused :normal)
        config))))

(defn- sync-child-tags [ctx]
  (each w (ctx :windows)
    (when-let [p (w :wl-parent)]
      (when (and (w :float) (not (w :closed)) (not (p :closed))
                 (not= (w :tag) (p :tag)))
        (put w :tag (p :tag))))))

(defn- anchor-floats
  "Assign virtual positions to floating windows so they scroll with content.
   Also rescues floats that have drifted too far from the viewport."
  [ctx]
  (each w (ctx :windows)
    (when (and (w :float) (not (w :closed)) (not (w :pending-destroy)))
      (when-let [o (tag-output ctx w)
                 tag-id (o :primary-tag)
                 tag (get-in ctx [:tags tag-id])]
        (def cam (or (tag :camera) 0))
        (def ow (or (o :w) 1920))
        (def oh (or (o :h) 1080))
        (def oy (or (o :y) 0))
        # Assign initial anchor for new floats
        (when (nil? (w :float-vx))
          (def ww (or (w :w) 0))
          (def wh (or (w :h) 0))
          (put w :float-vx (+ cam (div (- ow ww) 2)))
          (put w :float-vy (+ oy (div (- oh wh) 2))))
        # Rescue: if float is more than 2 viewports away, pull it back
        (def screen-vx (- (w :float-vx) cam))
        (when (or (< screen-vx (- 0 (* 2 ow)))
                  (> screen-vx (* 3 ow)))
          (put w :float-vx (+ cam (div ow 2))))))))

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
    # Compositor ignores propose-dimensions while fullscreen — skip to avoid
    # polluting last-proposed-w/h (which would cause the skip check to suppress
    # the re-proposal needed when exiting fullscreen).
    (when (and (not (w :fullscreen))
               (not (nil? (w :proposed-w))) (not (nil? (w :proposed-h))))
      # Skip re-proposing identical dimensions — unless the window never
      # confirmed any dimensions (w/h nil), in which case keep trying so
      # the client eventually commits and the compositor sends :dimensions.
      (unless (and (= (w :proposed-w) (w :last-proposed-w))
                   (= (w :proposed-h) (w :last-proposed-h))
                   (not (w :new))
                   (w :w))
        (put w :last-proposed-w (w :proposed-w))
        (put w :last-proposed-h (w :proposed-h))
        (:propose-dimensions (w :obj) (w :proposed-w) (w :proposed-h))))))

(defn- apply-focus [ctx]
  (def config (ctx :config))
  (each s (ctx :seats)
    (when (s :focus-changed)
      (if-let [w (s :focused)]
        (do (:focus-window (s :obj) (w :obj))
            (:place-top (w :node))
            # Warp cursor to center of focused window
            (when (and (config :warp-cursor) (not (s :window-interaction)))
              (when-let [ww (w :w) wh (w :h)
                         vx (or (w :float-vx) (w :vx))
                         tag (get-in ctx [:tags (w :tag)])
                         o (tag-output ctx w)]
                (def usable (output/usable-area o))
                (def cam (or (tag :camera) 0))
                (def sx (+ (usable :x) (- vx cam)))
                (def sy (or (w :float-vy) (w :y) 0))
                (:pointer-warp (s :obj)
                               (math/round (+ sx (/ ww 2)))
                               (math/round (+ sy (/ wh 2)))))))
        (:clear-focus (s :obj))))
    (when (s :focus-output-changed)
      (when-let [o (s :focused-output)]
        (when (o :layer-shell)
          (:set-default (o :layer-shell))))))
  # Ensure floating windows stay above tiled windows
  (each w (ctx :windows)
    (when (and (w :float) (w :visible) (w :node))
      (:place-top (w :node)))))

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
    (put w :hints-changed nil)
    (put w :proposed-w nil)
    (put w :proposed-h nil)
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
    (when (and (w :w) (w :h) (not (w :float)) (not (w :x)))
      (if-let [o (tag-output ctx w)]
        (window/set-position w
          (+ (o :x) (div (- (o :w) (w :w)) 2))
          (+ (o :y) (div (- (o :h) (w :h)) 2)))
        (window/set-position w 0 0)))))

(defn- tick-animations [ctx]
  (def config (ctx :config))
  (when (not (config :anim-enabled)) (break))
  (def now (os/clock :monotonic))
  (def last-time (or (ctx :anim-last-time) now))
  (def raw-dt (* (- now last-time) 1000)) # convert to ms
  (put ctx :anim-last-time now)
  (when (< raw-dt 0.1) (break)) # skip if dt is negligible (first frame)
  # Cap dt to prevent instant completion after long idle gaps (e.g. ~960ms
  # background cycles), but allow real frame intervals through (~100ms at
  # the compositor's manage-dirty rate).
  (def dt (min raw-dt 200))
  (def ease-fn (or (anim/easing-fns (config :anim-ease)) anim/ease-out-cubic))
  (each w (ctx :windows)
    (anim/tick-window w dt ease-fn))
  (eachp [_ tag] (ctx :tags)
    (anim/tick-camera tag dt ease-fn)))

(defn- window-screen-x
  "Compute screen x from virtual x, animated camera, and output."
  [w ctx]
  (when-let [vx (w :vx)
             tag (get-in ctx [:tags (w :tag)])
             o (tag-output ctx w)]
    (def usable (output/usable-area o))
    (def cam (or (tag :camera-visual) (tag :camera)))
    (+ (usable :x) (- vx cam))))

(defn- float-screen-pos
  "Compute screen position for a floating window from its virtual anchor."
  [w ctx]
  (when-let [vx (w :float-vx)
             vy (w :float-vy)
             tag (get-in ctx [:tags (w :tag)])
             o (tag-output ctx w)]
    (def usable (output/usable-area o))
    (def cam (or (tag :camera-visual) (tag :camera) 0))
    [(+ (usable :x) (- vx cam)) vy]))

(defn- apply-positions [ctx]
  (each w (ctx :windows)
    (when (and (w :visible) (w :node))
      (if (w :float)
        (when-let [[sx sy] (float-screen-pos w ctx)]
          (:set-position (w :node) (math/round sx) (math/round sy)))
        (do
          (def screen-x (window-screen-x w ctx))
          (def screen-y (anim/resolve-y w))
          (when (and screen-x screen-y)
            (:set-position (w :node)
                           (math/round screen-x) (math/round screen-y))))))))

(defn- apply-float-clips [ctx]
  "Clip floating windows at output boundaries, hide if fully off-screen."
  (each w (ctx :windows)
    (when (and (w :visible) (w :obj) (w :float))
      (when-let [[sx sy] (float-screen-pos w ctx)
                 o (tag-output ctx w)]
        (def ox (or (o :x) 0))
        (def oy (or (o :y) 0))
        (def ow (or (o :w) 1920))
        (def oh (or (o :h) 1080))
        (def ww (or (w :w) 0))
        (def wh (or (w :h) 0))
        (def on-screen (and (< sx (+ ox ow)) (> (+ sx ww) ox)
                            (< sy (+ oy oh)) (> (+ sy wh) oy)))
        (if on-screen
          (do
            (when (w :render-hidden)
              (put w :render-hidden nil)
              (:show (w :obj)))
            (def clip (scroll/clip-rect sx ww sy wh ox oy ow oh))
            (if clip
              (:set-clip-box (w :obj)
                             (math/round (clip :clip-x)) (math/round (clip :clip-y))
                             (math/round (clip :clip-w)) (math/round (clip :clip-h)))
              (when (w :clip-applied)
                (:set-clip-box (w :obj) 0 0 0 0)))
            (put w :clip-applied clip))
          (when (not (w :render-hidden))
            (put w :render-hidden true)
            (:hide (w :obj))))))))

(defn- apply-clips [ctx]
  (each w (ctx :windows)
    (when (and (w :visible) (w :obj) (not (w :float)))
      (def screen-x (window-screen-x w ctx))
      (def o (tag-output ctx w))
      (def [rw rh] (anim/resolve-dimensions w))
      (def win-w (or rw 0))
      (def win-h (or rh 0))
      (if (or (<= win-w 0) (<= win-h 0))
        # Dimensions not yet known — clear any stale clip, don't hide
        (when (w :clip-applied)
          (:set-clip-box (w :obj) 0 0 0 0)
          (put w :clip-applied nil))
        # Normal clipping logic
        (do
          (def on-screen
            (and screen-x o
                 (scroll/visible? screen-x win-w
                                  (or (o :x) 0) (or (o :w) 1920))))
          (if on-screen
            (do
              # Re-show if previously hidden by render clipping
              (when (w :render-hidden)
                (put w :render-hidden nil)
                (:show (w :obj)))
              (def screen-y (anim/resolve-y w))
              (def ox (or (o :x) 0))
              (def oy (or (o :y) 0))
              (def ow (or (o :w) 1920))
              (def oh (or (o :h) 1080))
              # Compute clip, expanding to include decoration area if present
              (def cfg (ctx :config))
              (def dh (if (w :decoration) (+ (cfg :decoration-height) (cfg :border-width)) 0))
              (def dbw (if (w :decoration) (cfg :border-width) 0))
              (def clip
                (scroll/clip-rect (- screen-x dbw) (+ win-w (* 2 dbw))
                                  (- screen-y dh) (+ win-h dh)
                                  ox oy ow oh))
              # Convert clip back to window-local coords (offset by decoration expansion)
              (if clip
                (:set-clip-box (w :obj)
                               (math/round (- (clip :clip-x) dbw))
                               (math/round (- (clip :clip-y) dh))
                               (math/round (clip :clip-w))
                               (math/round (clip :clip-h)))
                (when (w :clip-applied)
                  (:set-clip-box (w :obj) 0 0 0 0)))
              (put w :clip-applied clip))
            # Fully off-screen — hide instead of zero-size clip
            (when (not (w :render-hidden))
              (put w :render-hidden true)
              (:hide (w :obj)))))))))


(defn- request-rerender [ctx]
  (when (anim/any-animating? ctx)
    (:manage-dirty
      (get-in ctx [:registry :proxies "river_window_manager_v1"]))))

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
    create-decorations
    init-new-seats
    process-focus
    process-pointer-ops
    state/reconcile-tags
    build-tag-output-index
    promote-late-floats
    adopt-orphan-windows
    sync-tree-focus
    process-fullscreen
    run-scroll-layout
    start-animations
    compute-borders
    update-decoration-colors
    sync-child-tags
    anchor-floats
    compute-visibility
    # --- effects ---
    apply-fullscreen
    apply-window-config
    apply-focus
    apply-borders
    apply-visibility
    ipc/emit-decoration-updates
    ipc/emit-state-events
    clear-transient
    save-tag-state
    signal-manage-done])

(def render-chain
  @[build-tag-output-index
    tick-animations
    center-unplaced
    apply-positions
    apply-float-clips
    apply-clips
    apply-decorations
    signal-render-done
    request-rerender])

# ============================================================
# Event registration
# ============================================================

(dispatch/reg-event :manage
  (fn [ctx] (run-chain ctx manage-chain) nil))

(dispatch/reg-event :render
  (fn [ctx] (run-chain ctx render-chain) nil))
