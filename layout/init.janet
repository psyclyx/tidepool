# Layout registry: layout-fns + navigate-fns tables, apply-geometry, apply.

(import ../state)
(import ../output)
(import ../window)
(import ./master-stack)
(import ./monocle)
(import ./grid)
(import ./centered-master)
(import ./dwindle)
(import ./columns)

(def layout-fns
  @{:master-stack master-stack/layout
    :monocle monocle/layout
    :grid grid/layout
    :centered-master centered-master/layout
    :dwindle dwindle/layout
    :columns columns/layout})

(def navigate-fns
  @{:master-stack master-stack/navigate
    :monocle monocle/navigate
    :grid grid/navigate
    :centered-master centered-master/navigate
    :dwindle dwindle/navigate
    :columns columns/navigate})

# Apply geometry specs from a layout function to actual windows
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
  # Find focused window for this output
  (def focused
    (when-let [seat (first (state/wm :seats))]
      (when-let [w (seat :focused)]
        (when (find |(= $ w) windows) w))))
  # Reset clip boxes for non-columns layouts so stale clips don't persist
  (when (not= layout-fn columns/layout)
    (each w windows (:set-clip-box (w :obj) 0 0 0 0)))
  (apply-geometry (layout-fn usable windows params cfg focused)))
