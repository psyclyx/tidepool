(import ../output)
(import ../window)
(import ./master-stack)
(import ./monocle)
(import ./grid)
(import ./centered-master)
(import ./dwindle)
(import ./scroll)

(def layout-fns
  "Layout function dispatch table."
  @{:master-stack master-stack/layout
    :monocle monocle/layout
    :grid grid/layout
    :centered-master centered-master/layout
    :dwindle dwindle/layout
    :scroll scroll/layout})

(def navigate-fns
  "Navigation function dispatch table."
  @{:master-stack master-stack/navigate
    :monocle monocle/navigate
    :grid grid/navigate
    :centered-master centered-master/navigate
    :dwindle dwindle/navigate
    :scroll scroll/navigate})

(defn apply-geometry
  "Store computed geometry on window tables."
  [results config]
  (each r results
    (when (r :scroll-placed) (put (r :window) :scroll-placed true))
    (if (r :hidden)
      (put (r :window) :layout-hidden true)
      (do
        (window/set-position (r :window) (r :x) (r :y))
        (window/propose-dimensions (r :window) (r :w) (r :h) config)))))

(defn apply
  "Apply the current layout to an output's tiled windows."
  [o windows seats config now]
  (def visible (filter |(not (or ($ :float) ($ :fullscreen)))
                       (output/visible o windows)))
  (when (empty? visible) (break))
  (def layout-fn (get layout-fns (o :layout) master-stack/layout))
  (def usable (output/usable-area o))
  (def params (o :layout-params))
  (def focused
    (when-let [seat (first seats)]
      (when-let [w (seat :focused)]
        (when (find |(= $ w) visible) w))))
  (def focus-prev
    (when-let [seat (first seats)]
      (seat :focus-prev)))
  (apply-geometry (layout-fn usable visible params config focused now focus-prev) config))
