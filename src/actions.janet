(import ./state)
(import ./window)
(import ./output)
(import ./seat)
(import ./indicator)
(import ./layout)
(import ./layout/scroll :as scroll)

(defn- clamp [x lo hi] (min hi (max lo x)))
(defn- wrap [x n] (% (+ (% x n) n) n))

(defn- output/primary-tag [o]
  (min-of (keys (o :tags))))

(defn tag-layout/save
  "Persist the current layout for the output's primary tag."
  [o tag-layouts]
  (when-let [tag (output/primary-tag o)]
    (put tag-layouts tag
         @{:layout (o :layout)
           :params (table/clone (o :layout-params))})))

(defn- find-adjacent-output [current outputs dir]
  (var best nil)
  (var best-dist math/inf)
  (each o outputs
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

(defn target
  "Find the navigation target window for a seat in the given direction."
  [seat dir]
  (def outputs (state/wm :outputs))
  (def windows (state/wm :windows))
  (when-let [w (seat :focused)
             o (window/tag-output w outputs)
             visible (output/visible o windows)
             i (assert (index-of w visible))]
    (case dir
      :next (get visible (+ i 1) (first visible))
      :prev (get visible (- i 1) (last visible))
      (let [tiled (filter |(not (or ($ :float) ($ :fullscreen))) visible)
            ti (index-of w tiled)]
        (when ti
          (let [n (length tiled)
                lo (o :layout)
                main-count (get-in o [:layout-params :main-count] 1)
                nav-fn (get layout/navigate-fns lo (layout/navigate-fns :master-stack))
                nav-ctx (when (= lo :scroll)
                          (scroll/context o windows w (seat :focus-prev)))
                target-i (nav-fn n main-count ti dir
                           (or nav-ctx {:output o :windows tiled :focused w}))]
            (when target-i (get tiled target-i))))))))

(defn- scroll/focused-column [seat]
  (when-let [o (seat :focused-output)]
    (when (= (o :layout) :scroll)
      (when-let [ctx (scroll/context o (state/wm :windows) (seat :focused) (seat :focus-prev))]
        (get (ctx :cols) (ctx :focused-col))))))

(defn spawn
  "Action: spawn a command."
  [command]
  (fn [seat binding]
    (ev/spawn (os/proc-wait (os/spawn command :p)))))

(defn close
  "Action: close the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (:close (w :obj)))))

(defn zoom
  "Action: swap the focused window to master position."
  []
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (def windows (state/wm :windows))
    (when-let [focused (seat :focused)
               o (window/tag-output focused outputs)
               visible (output/visible o windows)
               t (if (= focused (first visible)) (get visible 1) focused)
               i (assert (index-of t windows))]
      (array/remove windows i)
      (array/insert windows 0 t)
      (seat/focus seat (first windows) (state/wm :render-order) state/config))))

(defn focus
  "Action: focus in a direction, crossing outputs if needed."
  [dir]
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (if-let [t (target seat dir)]
      (seat/focus seat t (state/wm :render-order) state/config)
      (when-let [current (or (when-let [w (seat :focused)] (window/tag-output w outputs))
                             (seat :focused-output))
                 adjacent (find-adjacent-output current outputs dir)]
        (seat/focus-output seat adjacent)
        (seat/focus seat nil (state/wm :render-order) state/config)))))

(defn swap
  "Action: swap the focused window in a direction."
  [dir]
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (def windows (state/wm :windows))
    (when-let [w (seat :focused)]
      (if-let [t (target seat dir)
               wi (index-of w windows)
               ti (index-of t windows)]
        (do
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
          (put windows wi t)
          (put windows ti w))
        (when-let [current (window/tag-output w outputs)
                   adjacent (find-adjacent-output current outputs dir)]
          (put w :tag (or (min-of (keys (adjacent :tags))) 1))
          (put w :column nil)
          (put w :col-width nil)
          (put w :col-weight nil)
          (seat/focus-output seat adjacent))))))

(defn focus-output
  "Action: focus the next or adjacent output."
  [&opt dir]
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (if dir
      (when-let [current (or (seat :focused-output) (first outputs))
                 adjacent (find-adjacent-output current outputs dir)]
        (seat/focus-output seat adjacent)
        (seat/focus seat nil (state/wm :render-order) state/config))
      (when-let [focused (seat :focused-output)
                 i (assert (index-of focused outputs))
                 t (or (get outputs (+ i 1)) (first outputs))]
        (seat/focus-output seat t)
        (seat/focus seat nil (state/wm :render-order) state/config)))))

(defn focus-last
  "Action: focus the previously focused window."
  []
  (fn [seat binding]
    (when-let [prev (seat :focus-prev)]
      (when (and (not (prev :closed))
                 (window/tag-output prev (state/wm :outputs)))
        (seat/focus seat prev (state/wm :render-order) state/config)))))

(defn send-to-output
  "Action: send the focused window to the next output."
  []
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (when-let [w (seat :focused)
               current (seat :focused-output)
               i (assert (index-of current outputs))
               t (or (get outputs (+ i 1)) (first outputs))]
      (put w :tag (or (min-of (keys (t :tags))) 1)))))

(defn float
  "Action: toggle floating on the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (window/set-float w (not (w :float))))))

(defn fullscreen
  "Action: toggle fullscreen on the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (if (w :fullscreen)
        (window/set-fullscreen w nil)
        (window/set-fullscreen w (window/tag-output w (state/wm :outputs)))))))

(defn set-tag
  "Action: move the focused window to a tag."
  [tag]
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (put w :tag tag))))

(defn focus-tag
  "Action: show only the given tag on the focused output."
  [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (put o :tags @{tag true}))))

(defn toggle-tag
  "Action: toggle a tag's visibility on the focused output."
  [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (if ((o :tags) tag)
        (put (o :tags) tag nil)
        (put (o :tags) tag true)))))

(defn focus-all-tags
  "Action: show all tags on the focused output."
  []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (put o :tags (table ;(mapcat |[$ true] (range 1 10)))))))

(defn adjust-ratio
  "Action: adjust the layout split ratio by delta."
  [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (case (o :layout)
        :scroll (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
        :dwindle (put params :dwindle-ratio (max 0.1 (min 0.9 (+ (params :dwindle-ratio) delta))))
        (put params :main-ratio (max 0.1 (min 0.9 (+ (params :main-ratio) delta)))))
      (tag-layout/save o state/tag-layouts))))

(defn adjust-main-count
  "Action: adjust the main window count by delta."
  [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (put params :main-count (max 1 (+ (params :main-count) delta)))
      (tag-layout/save o state/tag-layouts))))

(defn cycle-layout
  "Action: cycle to the next/prev layout."
  [dir]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def layouts (state/config :layouts))
      (def current (o :layout))
      (def i (or (index-of current layouts) 0))
      (def next-i (case dir
                    :next (% (+ i 1) (length layouts))
                    :prev (% (+ (- i 1) (length layouts)) (length layouts))))
      (put o :layout (get layouts next-i))
      (tag-layout/save o state/tag-layouts)
      (indicator/layout-changed o state/config))))

(defn set-layout
  "Action: set the layout on the focused output."
  [lo]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (put o :layout lo)
      (tag-layout/save o state/tag-layouts)
      (indicator/layout-changed o state/config))))

(defn adjust-column-width
  "Action: adjust the default column width by delta."
  [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def params (o :layout-params))
      (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
      (tag-layout/save o state/tag-layouts))))

(defn resize-column
  "Action: resize the focused scroll column by delta."
  [delta]
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def current (or ((first col) :col-width)
                       (get-in (seat :focused-output) [:layout-params :column-width] 0.5)))
      (def new-width (max 0.1 (min 1.0 (+ current delta))))
      (each win col (put win :col-width new-width)))))

(defn resize-window
  "Action: resize the focused window's weight by delta."
  [delta]
  (fn [seat binding]
    (when-let [w (seat :focused)
               col (scroll/focused-column seat)]
      (when (> (length col) 1)
        (def current (or (w :col-weight) 1.0))
        (put w :col-weight (max 0.1 (+ current delta)))))))

(defn preset-column-width
  "Action: cycle the focused column through width presets."
  []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def presets (state/config :column-presets))
      (when (and presets (> (length presets) 0))
        (def current (or ((first col) :col-width)
                         (get-in (seat :focused-output) [:layout-params :column-width] 0.5)))
        (def next-width
          (or (find |(> $ (+ current 0.01)) (sorted presets))
              (first (sorted presets))))
        (each win col (put win :col-width next-width))))))

(defn equalize-column
  "Action: reset all row weights in the focused column."
  []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (each win col (put win :col-weight nil)))))

(defn consume-column
  "Action: merge the focused window into an adjacent column."
  [dir]
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)]
      (when (= (o :layout) :scroll)
        (when-let [ctx (scroll/context o (state/wm :windows) w (seat :focus-prev))]
          (def {:cols cols :num-cols num-cols :focused-col my-col} ctx)
          (def target-ci (case dir :left (- my-col 1) :right (+ my-col 1)))
          (when (and (>= target-ci 0) (< target-ci num-cols) (not= target-ci my-col))
            (put w :column ((first (get cols target-ci)) :column))))))))

(defn expel-column
  "Action: expel the focused window into a new column."
  []
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)]
      (when (= (o :layout) :scroll)
        (when-let [ctx (scroll/context o (state/wm :windows) w (seat :focus-prev))]
          (def {:cols cols :focused-col my-col :windows tiled} ctx)
          (when (> (length (get cols my-col)) 1)
            (var max-col -1)
            (each win tiled (set max-col (max max-col (or (win :column) 0))))
            (put w :column (+ max-col 1))))))))

(defn pointer-move
  "Action: start a pointer move operation."
  []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      (seat/pointer-move seat w (state/wm :render-order) state/config))))

(defn pointer-resize
  "Action: start a pointer resize operation."
  []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      (seat/pointer-resize seat w {:bottom true :right true} (state/wm :render-order) state/config))))

(defn passthrough
  "Action: toggle keybinding passthrough."
  []
  (fn [seat binding]
    (put binding :passthrough (not (binding :passthrough)))
    (def request (if (binding :passthrough) :disable :enable))
    (each other (seat :xkb-bindings)
      (unless (= other binding) (request (other :obj))))
    (each other (seat :pointer-bindings)
      (unless (= other binding) (request (other :obj))))))

(defn toggle-scratchpad
  "Action: toggle scratchpad (tag 0) visibility."
  []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (if ((o :tags) 0)
        (put (o :tags) 0 nil)
        (put (o :tags) 0 true)))))

(defn send-to-scratchpad
  "Action: send the focused window to the scratchpad."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (put w :tag 0)
      (window/set-float w true))))

(defn restart
  "Action: restart tidepool (exit code 42)."
  []
  (fn [seat binding]
    (os/exit 42)))

(defn exit
  "Action: exit tidepool."
  []
  (fn [seat binding]
    (:stop (state/registry "river_window_manager_v1"))))
