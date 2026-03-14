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
      (:destroy (w :obj))
      (:destroy (w :node))))
  (each s (state/wm :seats)
    (when (s :pending-destroy)
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

(defn- save-positions [config]
  (def prev @{})
  (when (config :animate)
    (each w (state/wm :windows)
      (when (and (w :x) (w :y) (not (w :new)) (not (w :closing)))
        (put prev w [(w :x) (w :y)]))))
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

(defn- dispatch-pointer-ops [render-order config]
  (each w (state/wm :windows)
    (when-let [move (w :pointer-move-requested)]
      (seat/pointer-move (move :seat) w render-order config))
    (when-let [resize (w :pointer-resize-requested)]
      (seat/pointer-resize (resize :seat) w (resize :edges) render-order config))))

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

(defn- start-animations [prev-positions now config]
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
                 (not (w :anim)) (not (w :layout-hidden))
                 (not (w :scroll-placed)))
        (when-let [prev (get prev-positions w)]
          (def [px py] prev)
          (when (or (not= px (w :x)) (not= py (w :y)))
            (animation/start w :move
              @{:from-x px :from-y py
                :to-x (w :x) :to-y (w :y)}
              now config)))))))

(defn- compute-visibility [outputs windows]
  (def all-tags @{})
  (each o outputs
    (merge-into all-tags (o :tags)))
  (each w windows
    (put w :visible
      (if (or (w :closing)
              (and (all-tags (w :tag))
                   (or (not (w :layout-hidden)) (w :anim))
                   (not (w :needs-open-anim))))
        true false))))

(defn reconcile-tags
  ``Enforce tag invariants: each tag 1-9 on at most one output (focused wins),
  tag 0 (scratchpad) exempt, every output has at least one tag,
  and primary-tag changes trigger layout save/restore.``
  [outputs focused tag-layouts]

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

  # Save/restore per-tag layouts on primary-tag change
  (each o outputs
    (def prev (o :primary-tag))
    (def curr (min-of (keys (o :tags))))
    (when (not= prev curr)
      (when prev
        (put tag-layouts prev
             @{:layout (o :layout)
               :params (table/clone (o :layout-params))}))
      (when-let [saved (get tag-layouts curr)]
        (put o :layout (saved :layout))
        (merge-into (o :layout-params) (saved :params)))
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
      (put w :vis-applied vis)
      (if vis (:show (w :obj)) (:hide (w :obj))))))

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
  (def prev-positions (save-positions config))
  (sort-outputs)
  (each o outputs (output/manage o outputs))
  (each w windows (window/manage w config seats))
  (dispatch-pointer-ops render-order config)
  (each s seats (seat/manage s outputs windows render-order config))
  (reconcile-tags outputs
                  (when-let [s (first seats)] (s :focused-output))
                  state/tag-layouts)
  (sanitize)
  (clear-layout-state)
  (def tag-map (build-tag-map outputs))
  (each o outputs (layout/apply o windows seats config now))
  (each o outputs
    (when (get-in o [:layout-params :scroll-animating])
      (put state/wm :anim-active true)))
  (compute-borders seats config tag-map)
  (start-animations prev-positions now config)
  (compute-visibility outputs windows)

  # Safety: if focused window ended up hidden, re-pick from visible
  (each s seats
    (when-let [w (s :focused)]
      (when (and (not (w :visible)) (not (w :closing)))
        (def best (last (filter |(and ($ :visible) (not ($ :closing))) render-order)))
        (seat/focus s best render-order config))))

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
