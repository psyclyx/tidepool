(import ./state)
(import ./output)
(import ./window)
(import ./seat)
(import ./animation)
(import ./ipc)
(import ./layout)

(var profile-last-manage 0)
(var profile-count 0)
(var profile-manage-total 0)
(var profile-render-total 0)
(var profile-cycle-total 0)

# --- Lifecycle helpers ---

(defn- prune-closed []
  (def arr (state/wm :render-order))
  (var i 0)
  (while (< i (length arr))
    (if (let [w (arr i)] (and (w :closed) (not (w :closing))))
      (array/remove arr i)
      (++ i))))

(defn- lifecycle-start [now config]
  (each o (state/wm :outputs) (output/manage-start o))
  (each w (state/wm :windows) (window/manage-start w now config))
  (each s (state/wm :seats) (seat/manage-start s)))

(defn- remove-destroyed
  "Remove elements with :pending-destroy from an array in place."
  [arr]
  (var i 0)
  (while (< i (length arr))
    (if ((arr i) :pending-destroy)
      (array/remove arr i)
      (++ i))))

(defn- apply-destroys []
  (each o (state/wm :outputs)
    (when (o :pending-destroy)
      (:destroy (o :obj))
      (output/bg/destroy (o :bg))))
  (each w (state/wm :windows)
    (when (w :pending-destroy)
      # Clean up marks referencing this window
      (when (w :mark)
        (put state/marks (w :mark) nil))
      # Prune from nav trail
      (def trail-entries (state/nav-trail :entries))
      (var ti 0)
      (while (< ti (length trail-entries))
        (if (= ((trail-entries ti) :window) w)
          (do
            (when-let [cursor (state/nav-trail :cursor)]
              (when (>= cursor ti)
                (put state/nav-trail :cursor (max 0 (- cursor 1)))))
            (array/remove trail-entries ti))
          (++ ti)))
      (:destroy (w :obj))
      (:destroy (w :node))))
  (each s (state/wm :seats)
    (when (s :pending-destroy)
      (:destroy (s :layer-shell))
      (:destroy (s :obj))))
  (remove-destroyed (state/wm :outputs))
  (remove-destroyed (state/wm :windows))
  (remove-destroyed (state/wm :seats))
  (remove-destroyed (state/wm :render-order)))

(defn- lifecycle-finish []
  (each o (state/wm :outputs) (output/manage-finish o))
  (each w (state/wm :windows) (window/manage-finish w))
  (each s (state/wm :seats) (seat/manage-finish s)))

# --- Pure data computation helpers ---

(defn- save-geometry [config]
  (def prev @{})
  (when (config :animate)
    (each w (state/wm :windows)
      (when (and (w :x) (w :y) (not (w :new)) (not (w :closing)))
        (put prev w [(w :x) (w :y) (w :w) (w :h)]))))
  prev)

(defn- sort-outputs []
  (sort (state/wm :outputs)
    (fn [a b] (let [ax (or (a :x) 0) ay (or (a :y) 0)
                    bx (or (b :x) 0) by (or (b :y) 0)]
                (if (= ax bx) (< ay by) (< ax bx))))))

(defn- clear-layout-state []
  (each w (state/wm :windows)
    (put w :layout-hidden nil)
    (put w :scroll-placed nil)
    (put w :layout-meta nil))
  (put state/wm :anim-active false))

(defn- sanitize []
  (each w (state/wm :windows)
    (when (and (not (w :closing)) (not (w :closed)))
      (when-let [cw (w :col-width)]
        (when (or (< cw 0.1) (> cw 1.0))
          (put w :col-width nil)))
      (when-let [cw (w :col-weight)]
        (when (<= cw 0)
          (put w :col-weight nil))))))

(defn- dispatch-pointer-ops [outputs render-order config]
  (each w (state/wm :windows)
    (when-let [move (w :pointer-move-requested)]
      (seat/pointer-move (move :seat) w outputs render-order config))
    (when-let [resize (w :pointer-resize-requested)]
      (seat/pointer-resize (resize :seat) w (resize :edges) outputs render-order config))))

(defn- build-tag-map
  "Build tag→output lookup table."
  [outputs]
  (def m @{})
  (each o outputs (eachk tag (o :tags) (put m tag o)))
  m)

(defn- compute-borders [seats config tag-map]
  (def focused (when-let [s (first seats)] (s :focused)))
  (each w (state/wm :windows)
    (when (not (w :closing))
      (if (= w focused)
        (window/set-borders w :focused config)
        (if (and focused (w :tag) (= (w :tag) (focused :tag))
                 (not (w :float)) (not (focused :float)))
          # Tabbed layout: non-focused windows in same tag are "tabbed"
          (if-let [o (get tag-map (w :tag))]
            (if (= (o :layout) :tabbed)
              (window/set-borders w :tabbed config)
              (window/set-borders w :normal config))
            (window/set-borders w :normal config))
          (window/set-borders w :normal config))))))

(defn- start-animations [prev-geometry now config]
  (when (config :animate)
    (each w (state/wm :windows)
      (when (and (w :new) (not (w :float)) (not (w :closing)))
        (put w :needs-open-anim true))
      (when (and (w :needs-open-anim) (w :x) (w :y)
                 (w :w) (> (w :w) 0) (w :h) (> (w :h) 0)
                 (not (w :closing)))
        (put w :needs-open-anim nil)
        (def cw (w :w))
        (def ch (w :h))
        (def cx (math/round (/ cw 2)))
        (def cy (math/round (/ ch 2)))
        (animation/start w :open
          @{:clip-from @[cx cy 0 0]
            :clip-to @[0 0 cw ch]}
          now config))
      (when (and (not (w :new)) (not (w :closing))
                 (not (w :layout-hidden))
                 (not (w :scroll-placed)))
        (when-let [prev (get prev-geometry w)]
          (def [px py pw ph] prev)
          (def tx (w :x))
          (def ty (w :y))
          (def moved (or (not= px tx) (not= py ty)))
          (def nw (w :proposed-w))
          (def nh (w :proposed-h))
          (def resized (and pw ph nw nh
                            (or (not= pw nw) (not= ph nh))))
          (when (or moved resized)
            (def props @{})
            (when moved
              (put props :from-x px) (put props :from-y py)
              (put props :to-x tx) (put props :to-y ty))
            (when resized
              (put props :clip-from @[0 0 pw ph])
              (put props :clip-to @[0 0 nw nh]))
            (if-let [existing (w :anim)]
              (when (= (existing :type) :move)
                (def retarget (or (not= (existing :to-x) (props :to-x))
                                  (not= (existing :to-y) (props :to-y))))
                (when retarget
                  (animation/start w :move props now config)))
              (animation/start w :move props now config))))))))

(defn- compute-visibility [outputs windows]
  (def all-tags @{})
  (each o outputs
    (merge-into all-tags (o :tags)))
  (each w windows
    (put w :visible
      (if (or (w :closing)
              (and (all-tags (w :tag))
                   (or (not (w :layout-hidden)) (w :anim))))
        true false))))

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
               :params (state/clone-layout-params (o :layout-params))})
        (when focused-window
          (put tag-focus prev focused-window)))
      # Reset params to defaults before restoring saved state.
      # Without this, stale keys (active-row, scroll-offset, animation
      # keys) from the previous tag leak into the new one.
      (def params (o :layout-params))
      (table/clear params)
      (merge-into params (state/default-layout-params))
      (when-let [saved (get tag-layouts curr)]
        (put o :layout (saved :layout))
        (merge-into params (saved :params)))
      (put o :tag-focus-hint (get tag-focus curr))
      (put o :primary-tag curr))))

# --- Effect application passes ---

(defn- apply-lifecycle-effects [windows]
  (each w windows
    (when (w :needs-ssd)
      (:use-ssd (w :obj)))
    (when (w :float-changed)
      (if (w :float)
        (:set-tiled (w :obj) {})
        (:set-tiled (w :obj) {:left true :bottom true :top true :right true})))
    (when (and (w :proposed-w) (w :proposed-h))
      (:propose-dimensions (w :obj) (w :proposed-w) (w :proposed-h)))))

(defn- apply-focus-effects [seats]
  (each s seats
    (when (s :focus-changed)
      (if-let [w (s :focused)]
        (do (:focus-window (s :obj) (w :obj))
            (:place-top (w :node))
            (when-let [wt (s :warp-target)]
              (:pointer-warp (s :obj)
                             (+ (wt :x) (div (wt :w) 2))
                             (+ (wt :y) (div (wt :h) 2)))))
        (:clear-focus (s :obj))))
    (when (s :focus-output-changed)
      (when-let [o (s :focused-output)]
        (:set-default (o :layer-shell))))
    (when (s :op-started)
      (:op-start-pointer (s :obj)))
    (when (s :op-ended)
      (:op-end (s :obj)))))

(def- all-edges {:left true :bottom true :top true :right true})

(defn- apply-borders-effects [windows]
  (each w windows
    (when (and (w :border-rgb)
               (or (not= (w :border-rgb) (w :border-applied-rgb))
                   (not= (w :border-width) (w :border-applied-width))))
      (put w :border-applied-rgb (w :border-rgb))
      (put w :border-applied-width (w :border-width))
      (:set-borders (w :obj) all-edges (w :border-width)
                    ;(output/rgb-to-u32-rgba (w :border-rgb))))))

(defn- apply-fullscreen-effects [windows outputs]
  (each w windows
    (when (w :fullscreen-changed)
      (if (w :fullscreen)
        (:inform-fullscreen (w :obj))
        (do (:inform-not-fullscreen (w :obj))
            (:exit-fullscreen (w :obj))))))
  (each o outputs
    (each w windows
      (when (and (w :fullscreen) ((o :tags) (w :tag)))
        (:fullscreen (w :obj) (o :obj))))))

(defn- apply-visibility [windows]
  (each w windows
    (def vis (w :visible))
    (unless (= vis (w :vis-applied))
      (if vis
        (do (put w :vis-applied vis) (:show (w :obj)))
        # Don't hide windows before their initial configure — the
        # compositor won't send dimensions to a hidden surface.
        (when (w :w)
          (put w :vis-applied vis)
          (:hide (w :obj)))))))

# --- Main cycles ---

(defn manage
  "Run the management cycle: layout, borders, animations, persistence."
  []
  (def t0 (when (state/config :debug) (os/clock)))
  (def cycle-dt (when t0 (if (> profile-last-manage 0) (- t0 profile-last-manage) 0)))
  (when t0 (set profile-last-manage t0))

  (def now (os/clock))
  (def config state/config)
  (def outputs (state/wm :outputs))
  (def windows (state/wm :windows))
  (def seats (state/wm :seats))
  (def render-order (state/wm :render-order))

  # --- Lifecycle (flag and destroy dead objects) ---
  (prune-closed)
  (lifecycle-start now config)
  (apply-destroys)

  # --- Pure data computation ---
  (def prev-geometry (save-geometry config))
  (sort-outputs)
  (each o outputs (output/manage o outputs))
  (each w windows (window/manage w config seats))
  (dispatch-pointer-ops outputs render-order config)
  (each s seats (seat/manage s outputs windows render-order config))
  (reconcile-tags outputs
                  (when-let [s (first seats)] (s :focused-output))
                  state/tag-layouts state/tag-focus
                  (when-let [s (first seats)] (s :focused)))
  (each o outputs
    (when-let [hint (o :tag-focus-hint)]
      (put o :tag-focus-hint nil)
      (when (and (not (hint :closed)) (not (hint :closing)))
        (each s seats
          (when (= (s :focused-output) o)
            (seat/focus s hint outputs render-order config))))))
  (sanitize)
  (clear-layout-state)
  (def tag-map (build-tag-map outputs))
  (each o outputs (layout/apply o windows seats config now))
  (each o outputs
    (when (get-in o [:layout-params :scroll-animating])
      (put state/wm :anim-active true)))
  (compute-borders seats config tag-map)
  (start-animations prev-geometry now config)
  (compute-visibility outputs windows)

  # Safety: if focused window ended up hidden, re-pick from visible.
  # Prefer a window on the focused output to avoid unexpected output jumps.
  (each s seats
    (when-let [w (s :focused)]
      (when (and (not (w :visible)) (not (w :closing)) (not (w :new)))
        (def best
          (or (when-let [o (s :focused-output)]
                (last (filter |(and ($ :visible) (not ($ :closing))
                                   ((o :tags) ($ :tag)))
                              render-order)))
              (last (filter |(and ($ :visible) (not ($ :closing))) render-order))))
        (seat/focus s best outputs render-order config))))

  # --- Effect application ---
  (apply-lifecycle-effects windows)
  (apply-focus-effects seats)
  (apply-borders-effects windows)
  (apply-fullscreen-effects windows outputs)
  (apply-visibility windows)
  (each o outputs (output/bg/manage (o :bg) o config state/registry))

  (ipc/emit-events outputs windows seats)

  (lifecycle-finish)
  (:manage-finish (state/registry "river_window_manager_v1"))

  (when (state/config :debug)
    (def manage-dt (- (os/clock) t0))
    (+= profile-manage-total manage-dt)
    (when (> cycle-dt 0) (+= profile-cycle-total cycle-dt))
    (++ profile-count)
    (when (= (% profile-count 10) 0)
      (def avg-manage (/ profile-manage-total profile-count))
      (def avg-render (/ profile-render-total profile-count))
      (def avg-cycle (if (> profile-count 1) (/ profile-cycle-total (- profile-count 1)) 0))
      (eprintf "PROFILE [%d frames] manage=%.1fms render=%.1fms cycle=%.1fms (%.0ffps) anim=%s\n"
        profile-count
        (* avg-manage 1000) (* avg-render 1000) (* avg-cycle 1000)
        (if (> avg-cycle 0) (/ 1 avg-cycle) 0)
        (string (state/wm :anim-active)))
      (set profile-count 0)
      (set profile-manage-total 0)
      (set profile-render-total 0)
      (set profile-cycle-total 0))))

(defn render
  "Run the render cycle: position windows, tick animations, clip."
  []
  (def t0 (when (state/config :debug) (os/clock)))
  (def now (os/clock))
  (def windows (state/wm :windows))
  (def outputs (state/wm :outputs))
  (def config state/config)

  # --- Pure data computation ---
  (each w windows (window/render w outputs))
  (each w windows
    (when (animation/tick w now)
      (put state/wm :anim-active true)))
  (def tag-map (build-tag-map outputs))
  (each w windows (window/clip-to-output w tag-map config))
  (each s (state/wm :seats) (seat/render s))

  # --- Effect application ---
  (each w windows
    (when (and (w :x) (w :y))
      (:set-position (w :node) (w :x) (w :y))))
  (each w windows
    (cond
      (w :anim-clip)
      (if (= (w :anim-clip) :clear)
        (:set-clip-box (w :obj) 0 0 0 0)
        (let [[cx cy cw ch] (w :anim-clip)]
          (:set-clip-box (w :obj) cx cy cw ch)))

      (w :clip-rect)
      (if (= (w :clip-rect) :clear)
        (:set-clip-box (w :obj) 0 0 0 0)
        (let [[cx cy cw ch] (w :clip-rect)]
          (:set-clip-box (w :obj) cx cy cw ch)))))

  (:render-finish (state/registry "river_window_manager_v1"))
  (when t0 (+= profile-render-total (- (os/clock) t0)))
  (when (state/wm :anim-active)
    (:manage-dirty (state/registry "river_window_manager_v1"))))
