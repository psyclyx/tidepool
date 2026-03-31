(import ./dispatch)
(import ./state)
(import ./window)
(import ./seat)
(import ./layout)
(import ./output)
(import ./log)
(import ./ipc)

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
    (when (o :pending-destroy) (:destroy (o :obj))))
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
  (sort (ctx :outputs)
    (fn [a b]
      (let [ax (or (a :x) 0) bx (or (b :x) 0)
            ay (or (a :y) 0) by (or (b :y) 0)]
        (if (= ax bx) (< ay by) (< ax bx))))))

(defn- init-new-outputs [ctx]
  (each o (ctx :outputs)
    (when (and (o :new) (empty? (o :tags)))
      (put (o :tags) 1 true))))

(defn- init-new-windows [ctx]
  (def config (ctx :config))
  (each w (ctx :windows)
    (when (w :new)
      (put w :needs-ssd (not= (w :decoration-hint) 0))
      (if (w :wl-parent)
        (do
          (window/set-float w true)
          (put w :tag ((w :wl-parent) :tag)))
        (do
          (window/set-float w false)
          (when (window/fixed-size? w)
            (window/set-float w true))
          (when-let [s (first (ctx :seats))
                     o (s :focused-output)]
            (put w :tag (or (min-of (keys (o :tags))) 1))))))))

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
    # Pending keybinding action
    (when-let [action-fn (s :pending-action)]
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
    (put w :proposed-h nil))
  (each s (ctx :seats)
    (put s :new nil)
    (put s :pending-action nil)
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

(defn- apply-positions [ctx]
  (each w (ctx :windows)
    (when (and (w :x) (w :y) (w :visible))
      (:set-position (w :node) (w :x) (w :y)))))

(defn- signal-render-done [ctx]
  (:render-finish
    (get-in ctx [:registry :proxies "river_window_manager_v1"])))

# ============================================================
# Chains — mutable arrays, modifiable at the REPL
# ============================================================

(def manage-chain
  @[prune-closed
    flag-destroyed
    ipc/emit-close-events
    apply-destroys
    sort-outputs
    init-new-outputs
    init-new-windows
    init-new-seats
    process-focus
    state/reconcile-tags
    run-layout
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
  @[center-unplaced
    apply-positions
    signal-render-done])

# ============================================================
# Event registration
# ============================================================

(dispatch/reg-event :manage
  (fn [ctx] (run-chain ctx manage-chain) nil))

(dispatch/reg-event :render
  (fn [ctx] (run-chain ctx render-chain) nil))
