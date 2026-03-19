(import ../animation)

(defn- sum [xs] (reduce + 0 xs))
(defn- win-row [w] (or (w :row) 0))

(defn assign
  "Assign column indices to windows, inserting new ones after focus."
  [windows focused &opt focus-prev]
  (var max-col -1)
  (each win windows
    (when (win :column)
      (set max-col (max max-col (win :column)))))
  (def insert-after
    (if-let [col (or (and focused (focused :column))
                     (and focus-prev (focus-prev :column)))]
      col
      max-col))
  (def new-windows (filter |(not ($ :column)) windows))
  (def num-new (length new-windows))
  (when (> num-new 0)
    (each win windows
      (when (and (win :column) (> (win :column) insert-after))
        (put win :column (+ (win :column) num-new)))))
  (var next-col (+ insert-after 1))
  (each win new-windows
    (put win :column next-col)
    (++ next-col))
  (def col-set (sorted (distinct (map |($ :column) windows))))
  (def col-map @{})
  (for i 0 (length col-set)
    (put col-map (get col-set i) i))
  (each win windows
    (put win :column (get col-map (win :column)))))

(defn group
  "Group windows into ordered columns."
  [windows focused &opt focus-prev]
  (assign windows focused focus-prev)
  (def groups @{})
  (each win windows
    (def col (win :column))
    (unless (groups col) (put groups col @[]))
    (array/push (groups col) win))
  (def col-indices (sorted (keys groups)))
  (map |(get groups $) col-indices))

(defn place
  "Compute placement rect, returning :hidden if fully outside clip bounds."
  [x y w h clip-left clip-right clip-top clip-bottom inner]
  (def cell-w (+ w (* 2 inner)))
  (def cell-h (+ h (* 2 inner)))
  (if (or (<= (+ x cell-w) clip-left) (>= x clip-right)
          (<= (+ y cell-h) clip-top) (>= y clip-bottom))
    :hidden
    {:x (+ x inner) :y (+ y inner) :w w :h h}))

(defn col-width
  "Compute a column's pixel width from its ratio."
  [col total-w default-ratio]
  (math/round (* total-w (or ((first col) :col-width) default-ratio))))

(defn x-positions
  "Compute cumulative x offsets for each column."
  [cols total-w default-ratio]
  (def positions @[])
  (var x 0)
  (each col cols
    (array/push positions x)
    (set x (+ x (col-width col total-w default-ratio))))
  positions)

(defn context
  "Get the scroll layout context (columns, focus) for tiled visible windows."
  [visible focused &opt focus-prev active-row]
  (def row (or active-row 0))
  (def row-windows (filter |(= (win-row $) row) visible))
  (when (empty? row-windows) (break nil))
  (def cols (group row-windows focused focus-prev))
  (def num-cols (length cols))
  (var focused-col 0)
  (var focused-row 0)
  (for ci 0 num-cols
    (def col (get cols ci))
    (for ri 0 (length col)
      (when (= (get col ri) focused)
        (set focused-col ci)
        (set focused-row ri))))
  @{:windows row-windows :cols cols :num-cols num-cols
    :focused-win focused :focused-col focused-col :focused-row focused-row
    :active-row row})

(defn layout
  "Arrange windows in horizontally scrollable columns."
  [usable windows params config focused &opt now focus-prev]
  (def active-row (or (params :active-row) 0))
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def bw (config :border-width))
  (def peek (* 2 inner))
  (def total-w (max 1 (- (usable :w) (* 2 outer))))
  (def total-h (max 1 (- (usable :h) (* 2 outer))))
  (def default-ratio (params :column-width))
  (def row-h-ratio (or (config :column-row-height) 0))

  (when (empty? windows) (break @[]))

  # Auto-assign new windows to active row
  (each win windows
    (when (nil? (win :row))
      (put win :row active-row)))

  # Split into active row and hidden rows, auto-switching if active row is empty
  (var row-windows (filter |(= (win-row $) active-row) windows))
  (when (empty? row-windows)
    (def all-rows (sorted (distinct (map win-row windows))))
    (def nearest (reduce |(if (< (math/abs (- $1 active-row))
                                 (math/abs (- $0 active-row))) $1 $0)
                         (first all-rows) all-rows))
    (when nearest
      (put params :active-row nearest)
      (set row-windows (filter |(= (win-row $) nearest) windows))))
  (def hidden-windows (filter |(not= (win-row $) (params :active-row)) windows))

  # Build hidden results for non-active-row windows
  (def results @[])
  (each win hidden-windows
    (array/push results {:window win :hidden true :scroll-placed true}))

  (when (empty? row-windows) (break results))

  (def cols (group row-windows focused focus-prev))
  (def num-cols (length cols))
  (def focused-win focused)
  (var focused-col-idx 0)
  (var focused-row-idx 0)
  (for ci 0 num-cols
    (def col (get cols ci))
    (for ri 0 (length col)
      (when (= (get col ri) focused-win)
        (set focused-col-idx ci)
        (set focused-row-idx ri))))


  (def content-w (max 1 (- total-w (* 2 inner))))
  (def col-xs (x-positions cols content-w default-ratio))
  (def total-content-w
    (+ (* 2 inner) (last col-xs) (col-width (last cols) content-w default-ratio)))

  # Expose layout geometry to IPC via params
  (put params :total-content-w total-content-w)
  (put params :column-widths (seq [col :in cols] (col-width col content-w default-ratio)))

  (def focused-x (+ inner (get col-xs focused-col-idx)))
  (def focused-col-w (col-width (get cols focused-col-idx) content-w default-ratio))

  (if focused-win
    (do
      (def max-scroll (max 0 (- total-content-w total-w)))
      (def col-right (+ focused-x focused-col-w))
      (def peek-l (if (> focused-col-idx 0) (+ peek bw) 0))
      (def peek-r (if (< focused-col-idx (- num-cols 1)) (- peek bw) 0))
      (def min-s (max 0 (- col-right (- total-w peek-r))))
      (def max-s (min max-scroll (- focused-x peek-l)))
      (def target-scroll (min max-s (max min-s (params :scroll-offset))))
      (animation/scroll-toward params :scroll-offset target-scroll now config))
    # No focused window — clamp scroll so first column stays visible
    (let [max-scroll (max 0 (- total-content-w total-w))
          clamped (min max-scroll (max 0 (params :scroll-offset)))]
      (put params :scroll-offset clamped)))
  (animation/scroll-update params :scroll-offset now)
  (def scroll (params :scroll-offset))

  # Clip against full output bounds, not usable area — usable can be
  # transiently degenerate during layer shell reconfigures.  The real
  # visual clip to output is handled downstream by clip-to-output.
  (def [ob-x ob-y ob-w ob-h] (or (params :output-bounds)
                                   [(usable :x) (usable :y) (usable :w) (usable :h)]))
  (def clip-left ob-x)
  (def clip-right (+ ob-x ob-w))
  (def clip-top ob-y)
  (def clip-bottom (+ ob-y ob-h))

  (for ci 0 num-cols
    (def col (get cols ci))
    (def cw (col-width col content-w default-ratio))
    (def x-off (- (+ inner (get col-xs ci)) scroll))
    (def num-rows (length col))

    (def heights @[])
    (var overflows false)
    (if (> row-h-ratio 0)
      (do
        (for ri 0 num-rows
          (def weight (or ((get col ri) :col-weight) 1.0))
          (array/push heights (math/round (* total-h weight row-h-ratio))))
        (def col-content-h (sum heights))
        (set overflows (> col-content-h total-h))
        (unless overflows
          (def scale (if (> col-content-h 0) (/ total-h col-content-h) 1))
          (array/clear heights)
          (var y-sum 0)
          (for ri 0 num-rows
            (def weight (or ((get col ri) :col-weight) 1.0))
            (def h (math/round (* total-h weight row-h-ratio scale)))
            (def actual-h (if (= ri (- num-rows 1)) (- total-h y-sum) h))
            (array/push heights actual-h)
            (set y-sum (+ y-sum actual-h)))))
      (do
        (def total-weight (sum (map |(or ($ :col-weight) 1.0) col)))
        (var y-sum 0)
        (for ri 0 num-rows
          (def weight (or ((get col ri) :col-weight) 1.0))
          (def h (math/round (* total-h (/ weight total-weight))))
          (def actual-h (if (= ri (- num-rows 1)) (- total-h y-sum) h))
          (array/push heights actual-h)
          (set y-sum (+ y-sum actual-h)))))

    (def scroll-key (keyword (string "scroll-y-" ci)))
    (var v-scroll 0)
    (if overflows
      (do
        (unless (params scroll-key) (put params scroll-key 0))
        (when (= ci focused-col-idx)
          (var focused-y 0)
          (for ri 0 focused-row-idx
            (set focused-y (+ focused-y (get heights ri))))
          (def focused-h (get heights focused-row-idx))
          (def col-content-h (sum heights))
          (def max-v-scroll (max 0 (- col-content-h total-h)))
          (def v-peek-top (+ peek bw))
          (def v-peek-bottom (- peek bw))
          (def can-v-peek (>= max-v-scroll (+ v-peek-top v-peek-bottom)))
          (def min-v-scroll (if can-v-peek v-peek-top 0))
          (def max-v-scroll-adj (if can-v-peek (- max-v-scroll v-peek-bottom) max-v-scroll))
          (var target-v (params scroll-key))
          (when (< focused-y (+ target-v v-peek-top))
            (set target-v (- focused-y v-peek-top)))
          (when (> (+ focused-y focused-h) (- (+ target-v total-h) v-peek-bottom))
            (set target-v (+ (- (+ focused-y focused-h) total-h) v-peek-bottom)))
          (set target-v (min max-v-scroll-adj (max min-v-scroll target-v)))
          (animation/scroll-toward params scroll-key target-v now config))
        (animation/scroll-update params scroll-key now)
        (set v-scroll (or (params scroll-key) 0)))
      (do
        (put params scroll-key 0)
        (put params (keyword (string "scroll-y-" ci "-anim")) nil)))

    (var y-acc 0)
    (for ri 0 num-rows
      (def win (get col ri))
      (put win :layout-meta @{:column ci :column-total num-cols :row ri :row-total num-rows
                               :scroll-row active-row})
      (def h (get heights ri))
      (def y-off (if overflows (- y-acc v-scroll) y-acc))
      (def placement (place
        (+ (usable :x) outer x-off)
        (+ (usable :y) outer y-off)
        (- cw (* 2 inner))
        (- h (* 2 inner))
        clip-left clip-right clip-top clip-bottom inner))
      (array/push results
        (if (= placement :hidden)
          {:window win :hidden true :scroll-placed true}
          (merge placement {:window win :scroll-placed true})))
      (set y-acc (+ y-acc h))))

  (put params :scroll-animating
    (if (or (params :scroll-offset-anim)
            (find |(params (keyword (string "scroll-y-" $ "-anim")))
                  (range 0 num-cols)))
      true nil))
  results)

(defn save-row-state
  "Save current scroll state for a row before switching."
  [params row]
  (def row-states (or (params :row-states) @{}))
  (put row-states row @{:scroll-offset (or (params :scroll-offset) 0)})
  (put params :row-states row-states))

(defn restore-row-state
  "Restore scroll state for a row after switching to it."
  [params row]
  (def saved (when-let [row-states (params :row-states)] (get row-states row)))
  (put params :scroll-offset (or (get saved :scroll-offset) 0)))

(defn switch-to-row
  "Switch active row, saving/restoring scroll state."
  [params current-row target-row]
  (save-row-state params current-row)
  (put params :active-row target-row)
  (restore-row-state params target-row))

(defn- edge-info
  "Shared edge detection for row boundary crossing.
  Returns {:at-edge :all-rows :idx :target-idx} or nil if not at edge."
  [ctx dir]
  (def {:focused-row my-row :cols cols :focused-col my-col :active-row active-row} ctx)
  (def col (get cols my-col))
  (def at-edge
    (case dir
      :up (= my-row 0)
      :down (= my-row (- (length col) 1))
      false))
  (when at-edge
    {:active-row active-row :dir dir}))

(defn row-boundary-info
  "When at a column boundary in the given direction, return the adjacent row
  number and list of windows in that row, or nil."
  [ctx dir all-tiled]
  (when-let [edge (edge-info ctx dir)]
    (def all-rows (sorted (distinct (map |(or ($ :row) 0) all-tiled))))
    (def idx (index-of (edge :active-row) all-rows))
    (when idx
      (def target-idx (case (edge :dir) :up (- idx 1) :down (+ idx 1)))
      (when (and (>= target-idx 0) (< target-idx (length all-rows)))
        (def target-row (get all-rows target-idx))
        (def row-windows (filter |(= (or ($ :row) 0) target-row) all-tiled))
        {:target-row target-row :windows row-windows}))))

(defn swap-boundary-info
  "Like row-boundary-info, but creates a new row when at the outer edge.
  Returns {:target-row :windows :new true} for new rows."
  [ctx dir all-tiled]
  (when-let [edge (edge-info ctx dir)]
    (def all-rows (sorted (distinct (map |(or ($ :row) 0) all-tiled))))
    (def idx (index-of (edge :active-row) all-rows))
    (when idx
      (def target-idx (case (edge :dir) :up (- idx 1) :down (+ idx 1)))
      (if (and (>= target-idx 0) (< target-idx (length all-rows)))
        (let [target-row (get all-rows target-idx)
              row-windows (filter |(= (or ($ :row) 0) target-row) all-tiled)]
          {:target-row target-row :windows row-windows})
        (let [target-row (case (edge :dir)
                           :up (- (first all-rows) 1)
                           :down (+ (last all-rows) 1))]
          {:target-row target-row :windows @[] :new true})))))

(defn navigate
  "Navigate between columns and rows."
  [n main-count i dir ctx]
  (when-let [col-ctx ctx]
    (def {:cols cols :num-cols num-cols
          :focused-col my-col :focused-row my-row :windows tiled} col-ctx)
    (var target nil)
    (case dir
      :left (when (> my-col 0)
              (def target-col (get cols (- my-col 1)))
              (set target (get target-col (min my-row (- (length target-col) 1)))))
      :right (when (< (+ my-col 1) num-cols)
               (def target-col (get cols (+ my-col 1)))
               (set target (get target-col (min my-row (- (length target-col) 1)))))
      :up (when (> my-row 0)
            (set target (get (get cols my-col) (- my-row 1))))
      :down (let [col (get cols my-col)]
              (when (< (+ my-row 1) (length col))
                (set target (get col (+ my-row 1))))))
    (when target (index-of target tiled))))
