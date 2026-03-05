(import ./state)
(import ./output)
(import ./window)
(import ./seat)
(import ./animation)
(import ./indicator)
(import ./layout)
(import ./persist)

(var profile-last-manage 0)
(var profile-count 0)
(var profile-manage-total 0)
(var profile-render-total 0)
(var profile-cycle-total 0)

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

(defn- restore-windows []
  (each w (state/wm :windows)
    (persist/restore-window w)))

(defn- sanitize []
  (each w (state/wm :windows)
    (when (and (not (w :closing)) (not (w :closed)))
      (when-let [cw (w :col-width)]
        (when (or (< cw 0.1) (> cw 1.0))
          (put w :col-width nil)))
      (when-let [cw (w :col-weight)]
        (when (<= cw 0)
          (put w :col-weight nil))))))

(defn- dispatch-pointer-ops []
  (each w (state/wm :windows)
    (when-let [move (w :pointer-move-requested)]
      (seat/pointer-move (move :seat) w))
    (when-let [resize (w :pointer-resize-requested)]
      (seat/pointer-resize (resize :seat) w (resize :edges)))))

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

(defn manage []
  (def t0 (when (state/config :debug) (os/clock)))
  (def cycle-dt (when t0 (if (> profile-last-manage 0) (- t0 profile-last-manage) 0)))
  (when t0 (set profile-last-manage t0))

  (prune-closed)
  (lifecycle-start)
  (def prev-positions (save-positions))
  (sort-outputs)
  (each o (state/wm :outputs) (output/manage o))
  (each w (state/wm :windows) (window/manage w))
  (restore-windows)
  (dispatch-pointer-ops)
  (each s (state/wm :seats) (seat/manage s))
  (reconcile-tags (state/wm :outputs)
                  (when-let [s (first (state/wm :seats))] (s :focused-output))
                  state/tag-layouts)
  (sanitize)
  (clear-layout-state)
  (each o (state/wm :outputs) (layout/apply o))
  (apply-borders)
  (start-animations prev-positions)
  (show-hide)
  (lifecycle-finish)
  (persist/save)
  (indicator/tags-changed)
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

(defn render []
  (def t0 (when (state/config :debug) (os/clock)))
  (each w (state/wm :windows) (window/render w))
  (each w (state/wm :windows) (animation/tick w))
  (each w (state/wm :windows) (window/clip-to-output w))
  (each s (state/wm :seats) (seat/render s))
  (:render-finish (state/registry "river_window_manager_v1"))
  (when t0 (+= profile-render-total (- (os/clock) t0)))
  (when (state/wm :anim-active)
    (:manage-dirty (state/registry "river_window_manager_v1"))))
