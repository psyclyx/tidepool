# All action/* functions, navigation, find-adjacent-output, tag-layout save/restore.

(import ./state)
(import ./window)
(import ./output)
(import ./seat)
(import ./indicator)
(import ./layout)
(import ./layout/scroll :as scroll)

(defn- clamp [x lo hi] (min hi (max lo x)))
(defn- wrap [x n] (% (+ (% x n) n) n))

# --- Tag-Layout Save/Restore ---

(defn- output/primary-tag [o]
  (min-of (keys (o :tags))))

(defn tag-layout/save [o]
  (when-let [tag (output/primary-tag o)]
    (put state/tag-layouts tag
         @{:layout (o :layout)
           :params (table/clone (o :layout-params))})))

(defn tag-layout/restore [o]
  (when-let [tag (output/primary-tag o)
             saved (state/tag-layouts tag)]
    (put o :layout (saved :layout))
    (merge-into (o :layout-params) (saved :params))))

(defn- fallback-tags [outputs]
  (for tag 1 10
    (unless (find |(($ :tags) tag) outputs)
      (when-let [o (find |(empty? ($ :tags)) outputs)]
        (put (o :tags) tag true)))))

# --- Adjacent Output ---

(defn- find-adjacent-output [current dir]
  (var best nil)
  (var best-dist math/inf)
  (each o (state/wm :outputs)
    (when (not= o current)
      (def dist
        (case dir
          :right (when (>= (o :x) (+ (current :x) (current :w)))
                   (- (o :x) (+ (current :x) (current :w))))
          :left (when (<= (+ (o :x) (o :w)) (current :x))
                  (- (current :x) (+ (o :x) (o :w))))
          :down (when (>= (o :y) (+ (current :y) (current :h)))
                  (- (o :y) (+ (current :y) (current :h))))
          :up (when (<= (+ (o :y) (o :h)) (current :y))
                (- (current :y) (+ (o :y) (o :h))))))
      (when (and dist (< dist best-dist))
        (set best o)
        (set best-dist dist))))
  best)

# --- Navigation Target ---

(defn target [seat dir]
  (when-let [w (seat :focused)
             o (window/tag-output w)
             visible (output/visible o (state/wm :windows))
             i (assert (index-of w visible))]
    (case dir
      :next (get visible (+ i 1) (first visible))
      :prev (get visible (- i 1) (last visible))
      # Spatial navigation uses tiled-only indices to match layout positions
      (let [tiled (filter |(not (or ($ :float) ($ :fullscreen))) visible)
            ti (index-of w tiled)]
        (when ti
          (let [n (length tiled)
                lo (o :layout)
                main-count (get-in o [:layout-params :main-count] 1)
                nav-fn (get layout/navigate-fns lo (layout/navigate-fns :master-stack))
                target-i (nav-fn n main-count ti dir
                           {:output o :windows tiled :focused w})]
            (when target-i (get tiled target-i))))))))

# --- Scroll Helpers ---

(defn- scroll/focused-column [seat]
  (when-let [o (seat :focused-output)]
    (when (= (o :layout) :scroll)
      (when-let [ctx (scroll/context o)]
        (get (ctx :cols) (ctx :focused-col))))))

# --- Actions ---

(defn spawn [command]
  (fn [seat binding]
    (ev/spawn (os/proc-wait (os/spawn command :p)))))

(defn close []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (:close (w :obj)))))

(defn zoom []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (window/tag-output focused)
               visible (output/visible o (state/wm :windows))
               t (if (= focused (first visible)) (get visible 1) focused)
               i (assert (index-of t (state/wm :windows)))]
      (array/remove (state/wm :windows) i)
      (array/insert (state/wm :windows) 0 t)
      (seat/focus seat (first (state/wm :windows))))))

(defn focus [dir]
  (fn [seat binding]
    (if-let [t (target seat dir)]
      (seat/focus seat t)
      # No target in current output — try adjacent monitor
      (when-let [current (or (when-let [w (seat :focused)] (window/tag-output w))
                             (seat :focused-output))
                 adjacent (find-adjacent-output current dir)]
        (seat/focus-output seat adjacent)
        (seat/focus seat nil)))))

(defn swap [dir]
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (if-let [t (target seat dir)
               wi (index-of w (state/wm :windows))
               ti (index-of t (state/wm :windows))]
        (do
          # Swap column/sizing assignments for scroll layout
          (def wc (w :column))
          (def tc (t :column))
          (put w :column tc)
          (put t :column wc)
          (def wcw (w :col-width))
          (def tcw (t :col-width))
          (put w :col-width tcw)
          (put t :col-width wcw)
          (def wcwt (w :col-weight))
          (def tcwt (t :col-weight))
          (put w :col-weight tcwt)
          (put t :col-weight wcwt)
          (put (state/wm :windows) wi t)
          (put (state/wm :windows) ti w))
        # No target in current output — move to adjacent monitor
        (when-let [current (window/tag-output w)
                   adjacent (find-adjacent-output current dir)]
          (put w :tag (or (min-of (keys (adjacent :tags))) 1))
          (put w :column nil)
          (put w :col-width nil)
          (put w :col-weight nil)
          (seat/focus-output seat adjacent))))))

(defn focus-output [&opt dir]
  (fn [seat binding]
    (if dir
      # Directional: focus adjacent output in given direction
      (when-let [current (or (seat :focused-output) (first (state/wm :outputs)))
                 adjacent (find-adjacent-output current dir)]
        (seat/focus-output seat adjacent)
        (seat/focus seat nil))
      # No direction: cycle to next output
      (when-let [focused (seat :focused-output)
                 i (assert (index-of focused (state/wm :outputs)))
                 t (or (get (state/wm :outputs) (+ i 1)) (first (state/wm :outputs)))]
        (seat/focus-output seat t)
        (seat/focus seat nil)))))

(defn focus-last []
  (fn [seat binding]
    (when-let [prev (seat :focus-prev)]
      (when (and (not (prev :closed))
                 (window/tag-output prev))
        (seat/focus seat prev)))))

(defn send-to-output []
  (fn [seat binding]
    (when-let [w (seat :focused)
               current (seat :focused-output)
               i (assert (index-of current (state/wm :outputs)))
               t (or (get (state/wm :outputs) (+ i 1)) (first (state/wm :outputs)))]
      (put w :tag (or (min-of (keys (t :tags))) 1)))))

(defn float []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (window/set-float w (not (w :float))))))

(defn fullscreen []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (if (w :fullscreen)
        (window/set-fullscreen w nil)
        (window/set-fullscreen w (window/tag-output w))))))

(defn set-tag [tag]
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (put w :tag tag))))

(defn focus-tag [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (tag-layout/save o)
      (each out (state/wm :outputs) (put (out :tags) tag nil))
      (put o :tags @{tag true})
      (fallback-tags (state/wm :outputs))
      (tag-layout/restore o)
      (indicator/layout-changed o))))

(defn toggle-tag [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (tag-layout/save o)
      (if ((o :tags) tag)
        (put (o :tags) tag nil)
        (do
          (each out (state/wm :outputs) (put (out :tags) tag nil))
          (put (o :tags) tag true)))
      (fallback-tags (state/wm :outputs))
      (tag-layout/restore o)
      (indicator/layout-changed o))))

(defn focus-all-tags []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (each out (state/wm :outputs) (put out :tags @{}))
      (put o :tags (table ;(mapcat |[$ true] (range 1 10)))))))

(defn adjust-ratio [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (case (o :layout)
        :scroll (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
        :dwindle (put params :dwindle-ratio (max 0.1 (min 0.9 (+ (params :dwindle-ratio) delta))))
        (put params :main-ratio (max 0.1 (min 0.9 (+ (params :main-ratio) delta)))))
      (tag-layout/save o))))

(defn adjust-main-count [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (put params :main-count (max 1 (+ (params :main-count) delta)))
      (tag-layout/save o))))

(defn cycle-layout [dir]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def layouts (state/config :layouts))
      (def current (o :layout))
      (def i (or (index-of current layouts) 0))
      (def next-i (case dir
                    :next (% (+ i 1) (length layouts))
                    :prev (% (+ (- i 1) (length layouts)) (length layouts))))
      (put o :layout (get layouts next-i))
      (tag-layout/save o)
      (indicator/layout-changed o))))

(defn set-layout [lo]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (put o :layout lo)
      (tag-layout/save o)
      (indicator/layout-changed o))))

(defn adjust-column-width [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
      (tag-layout/save o))))

(defn resize-column [delta]
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def current (or ((first col) :col-width)
                       (get-in (seat :focused-output) [:layout-params :column-width] 0.5)))
      (def new-width (max 0.1 (min 1.0 (+ current delta))))
      (each win col (put win :col-width new-width)))))

(defn resize-window [delta]
  (fn [seat binding]
    (when-let [w (seat :focused)
               col (scroll/focused-column seat)]
      (when (> (length col) 1)
        (def current (or (w :col-weight) 1.0))
        (put w :col-weight (max 0.1 (+ current delta)))))))

(defn preset-column-width []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def presets (state/config :column-presets))
      (when (and presets (> (length presets) 0))
        (def current (or ((first col) :col-width)
                         (get-in (seat :focused-output) [:layout-params :column-width] 0.5)))
        # Find next preset (first one larger than current, or wrap to first)
        (def next-width
          (or (find |(> $ (+ current 0.01)) (sorted presets))
              (first (sorted presets))))
        (each win col (put win :col-width next-width))))))

(defn equalize-column []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (each win col (put win :col-weight nil)))))

(defn consume-column [dir]
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)]
      (when (= (o :layout) :scroll)
        (when-let [ctx (scroll/context o)]
          (def {:cols cols :num-cols num-cols :focused-col my-col} ctx)
          (def target-ci (case dir :left (- my-col 1) :right (+ my-col 1)))
          (when (and (>= target-ci 0) (< target-ci num-cols) (not= target-ci my-col))
            (put w :column ((first (get cols target-ci)) :column))))))))

(defn expel-column []
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)]
      (when (= (o :layout) :scroll)
        (when-let [ctx (scroll/context o)]
          (def {:cols cols :focused-col my-col :windows tiled} ctx)
          (when (> (length (get cols my-col)) 1)
            (var max-col -1)
            (each win tiled (set max-col (max max-col (or (win :column) 0))))
            (put w :column (+ max-col 1))))))))

(defn pointer-move []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      (seat/pointer-move seat w))))

(defn pointer-resize []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      (seat/pointer-resize seat w {:bottom true :right true}))))

(defn passthrough []
  (fn [seat binding]
    (put binding :passthrough (not (binding :passthrough)))
    (def request (if (binding :passthrough) :disable :enable))
    (each other (seat :xkb-bindings)
      (unless (= other binding) (request (other :obj))))
    (each other (seat :pointer-bindings)
      (unless (= other binding) (request (other :obj))))))

(defn toggle-scratchpad []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (if ((o :tags) 0)
        (put (o :tags) 0 nil)
        (put (o :tags) 0 true)))))

(defn send-to-scratchpad []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (put w :tag 0)
      (window/set-float w true))))

(defn restart []
  (fn [seat binding]
    (os/exit 42)))

(defn exit []
  (fn [seat binding]
    (:stop (state/registry "river_window_manager_v1"))))
