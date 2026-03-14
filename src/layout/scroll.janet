(import ../animation)

(defn- sum [xs] (reduce + 0 xs))

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
  [visible focused &opt focus-prev]
  (when (empty? visible) (break nil))
  (def cols (group visible focused focus-prev))
  (def num-cols (length cols))
  (var focused-col 0)
  (var focused-row 0)
  (for ci 0 num-cols
    (def col (get cols ci))
    (for ri 0 (length col)
      (when (= (get col ri) focused)
        (set focused-col ci)
        (set focused-row ri))))
  @{:windows visible :cols cols :num-cols num-cols
    :focused-win focused :focused-col focused-col :focused-row focused-row})

(defn layout
  "Arrange windows in horizontally scrollable columns."
  [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def peek (* 2 inner))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def default-ratio (params :column-width))
  (def row-h-ratio (or (config :column-row-height) 0))

  (when (empty? windows) (break @[]))
  (def cols (group windows focused focus-prev))
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


  (def content-w (- total-w (* 2 inner)))
  (def col-xs (x-positions cols content-w default-ratio))
  (def total-content-w
    (+ (* 2 inner) (last col-xs) (col-width (last cols) content-w default-ratio)))

  (def focused-x (+ inner (get col-xs focused-col-idx)))
  (def focused-col-w (col-width (get cols focused-col-idx) content-w default-ratio))

  (when focused-win
    (def max-scroll (max 0 (- total-content-w total-w)))
    (def col-right (+ focused-x focused-col-w))
    (def peek-l (if (> focused-col-idx 0) peek 0))
    (def peek-r (if (< focused-col-idx (- num-cols 1)) peek 0))
    (def min-s (max 0 (- col-right (- total-w peek-r))))
    (def max-s (min max-scroll (- focused-x peek-l)))
    (def target-scroll (min max-s (max min-s (params :scroll-offset))))
    (animation/scroll-toward params :scroll-offset target-scroll now config))
  (animation/scroll-update params :scroll-offset now)
  (def scroll (params :scroll-offset))

  (def clip-left (usable :x))
  (def clip-right (+ (usable :x) (usable :w)))
  (def clip-top (usable :y))
  (def clip-bottom (+ (usable :y) (usable :h)))

  (def results @[])
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
          (def can-v-peek (>= max-v-scroll (* 2 peek)))
          (def min-v-scroll (if can-v-peek peek 0))
          (def max-v-scroll-adj (if can-v-peek (- max-v-scroll peek) max-v-scroll))
          (var target-v (params scroll-key))
          (when (< focused-y (+ target-v peek))
            (set target-v (- focused-y peek)))
          (when (> (+ focused-y focused-h) (- (+ target-v total-h) peek))
            (set target-v (+ (- (+ focused-y focused-h) total-h) peek)))
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
      (put win :layout-meta @{:column ci :column-total num-cols :row ri :row-total num-rows})
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
