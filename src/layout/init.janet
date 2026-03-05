(import ../state)
(import ../output)
(import ../window)
(import ./master-stack)
(import ./monocle)
(import ./grid)
(import ./centered-master)
(import ./dwindle)
(import ./scroll)

(def layout-fns
  @{:master-stack master-stack/layout
    :monocle monocle/layout
    :grid grid/layout
    :centered-master centered-master/layout
    :dwindle dwindle/layout
    :scroll scroll/layout})

(def navigate-fns
  @{:master-stack master-stack/navigate
    :monocle monocle/navigate
    :grid grid/navigate
    :centered-master centered-master/navigate
    :dwindle dwindle/navigate
    :scroll scroll/navigate})

(defn apply-geometry [results]
  (each r results
    (when (r :scroll-placed) (put (r :window) :scroll-placed true))
    (if (r :hidden)
      (put (r :window) :layout-hidden true)
      (do
        (window/set-position (r :window) (r :x) (r :y))
        (window/propose-dimensions (r :window) (r :w) (r :h))))))

(defn apply [o]
  (def windows (filter |(not (or ($ :float) ($ :fullscreen)))
                       (output/visible o (state/wm :windows))))
  (when (empty? windows) (break))
  (def layout-fn (get layout-fns (o :layout) master-stack/layout))
  (def usable (output/usable-area o))
  (def params (o :layout-params))
  (def cfg state/config)
  (def focused
    (when-let [seat (first (state/wm :seats))]
      (when-let [w (seat :focused)]
        (when (find |(= $ w) windows) w))))
  (when (not= layout-fn scroll/layout)
    (each w windows (:set-clip-box (w :obj) 0 0 0 0)))
  (apply-geometry (layout-fn usable windows params cfg focused)))
