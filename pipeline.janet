# Manage/render pipeline: orchestrates per-frame lifecycle.

(import ./state)
(import ./output)
(import ./window)
(import ./seat)
(import ./animation)
(import ./indicator)
(import ./layout)
(import ./persist)

# --- Show/Hide ---

(defn show-hide []
  (def all-tags @{})
  (each o (state/wm :outputs)
    (merge-into all-tags (o :tags))
    (each w (state/wm :windows)
      (when (and (w :fullscreen) ((o :tags) (w :tag)))
        (:fullscreen (w :obj) (o :obj)))))
  (each w (state/wm :windows)
    (if (or (w :closing)
            (and (all-tags (w :tag))
                 (or (not (w :layout-hidden)) (w :anim))))
      (:show (w :obj))
      (:hide (w :obj)))))

# --- Pipeline Phases ---

(defn- prune-closed []
  (update state/wm :render-order |(filter (fn [w] (not (and (w :closed) (not (w :closing))))) $)))

(defn- lifecycle-start []
  (update state/wm :outputs |(keep output/manage-start $))
  (update state/wm :windows |(keep window/manage-start $))
  (update state/wm :seats |(keep seat/manage-start $)))

(defn- save-positions []
  (def prev @{})
  (when (state/config :animate)
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
    (put w :scroll-placed nil))
  (put state/wm :anim-active false))

(defn- apply-borders []
  (each w (state/wm :windows)
    (when (not (w :closing))
      (if (find |(= ($ :focused) w) (state/wm :seats))
        (window/set-borders w :focused)
        (window/set-borders w :normal)))))

(defn- start-animations [prev-positions]
  (when (state/config :animate)
    (each w (state/wm :windows)
      (when (and (w :new) (w :x) (w :y)
                 (not (w :float)) (not (w :closing)))
        (def cw (max 0 (or (w :w) 0)))
        (def ch (max 0 (or (w :h) 0)))
        (def cx (math/round (/ cw 2)))
        (def cy (math/round (/ ch 2)))
        (animation/start w :open
          @{:clip-from @[cx cy 0 0]
            :clip-to @[0 0 cw ch]}))
      (when (and (not (w :new)) (not (w :closing))
                 (not (w :anim)) (not (w :layout-hidden))
                 (not (w :scroll-placed)))
        (when-let [prev (get prev-positions w)]
          (def [px py] prev)
          (when (or (not= px (w :x)) (not= py (w :y)))
            (animation/start w :move
              @{:from-x px :from-y py
                :to-x (w :x) :to-y (w :y)})))))))

(defn- lifecycle-finish []
  (each o (state/wm :outputs) (output/manage-finish o))
  (each w (state/wm :windows) (window/manage-finish w))
  (each s (state/wm :seats) (seat/manage-finish s)))

# --- Restore Persisted Window State ---

(defn- restore-windows []
  (each w (state/wm :windows)
    (persist/restore-window w)))

# --- Pipeline Sanitizer ---

(defn- sanitize []
  (def all-tags @{})
  (each o (state/wm :outputs)
    (merge-into all-tags (o :tags)))
  (each w (state/wm :windows)
    (when (and (not (w :closing)) (not (w :closed)))
      # Window tag must reference an active output tag
      (unless (all-tags (w :tag))
        (when-let [fallback (min-of (keys all-tags))]
          (put w :tag fallback)))
      # Clamp col-width
      (when-let [cw (w :col-width)]
        (when (or (< cw 0.1) (> cw 1.0))
          (put w :col-width nil)))
      # col-weight must be positive
      (when-let [cw (w :col-weight)]
        (when (<= cw 0)
          (put w :col-weight nil))))))

# --- Pointer Dispatch (extracted from window/manage) ---

(defn- dispatch-pointer-ops []
  (each w (state/wm :windows)
    (when-let [move (w :pointer-move-requested)]
      (seat/pointer-move (move :seat) w))
    (when-let [resize (w :pointer-resize-requested)]
      (seat/pointer-resize (resize :seat) w (resize :edges)))))

# --- Main Pipeline ---

(defn manage []
  (prune-closed)
  (lifecycle-start)
  (def prev-positions (save-positions))
  (sort-outputs)
  (each o (state/wm :outputs) (output/manage o))
  (each w (state/wm :windows) (window/manage w))
  (restore-windows)
  (dispatch-pointer-ops)
  (each s (state/wm :seats) (seat/manage s))
  (sanitize)
  (clear-layout-state)
  (each o (state/wm :outputs) (layout/apply o))
  (apply-borders)
  (start-animations prev-positions)
  (show-hide)
  (lifecycle-finish)
  (persist/save)
  (indicator/tags-changed)
  (:manage-finish (state/registry "river_window_manager_v1")))

(defn render []
  (each w (state/wm :windows) (window/render w))
  (each w (state/wm :windows) (animation/tick w))
  (each w (state/wm :windows) (window/clip-to-output w))
  (each s (state/wm :seats) (seat/render s))
  (:render-finish (state/registry "river_window_manager_v1"))
  (when (state/wm :anim-active)
    (:manage-dirty (state/registry "river_window_manager_v1"))))
