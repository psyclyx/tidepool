# Scroll layout: scrollable columns with multi-window stacking.
# Requires state, animation, output for scroll effects and context building.

(import ../state)
(import ../animation)
(import ../output)

(defn- sum [xs] (reduce + 0 xs))

# Auto-assign column indices to windows that don't have one
(defn assign [windows]
  (var max-col -1)
  (each win windows
    (when (win :column)
      (set max-col (max max-col (win :column)))))
  # Find the focused window's column to insert new windows after it
  (def focused-win
    (find |(find (fn [s] (= (s :focused) $)) (state/wm :seats)) windows))
  (def insert-after
    (if (and focused-win (focused-win :column))
      (focused-win :column)
      max-col))
  # Shift existing columns after the insertion point to make room
  (def new-windows (filter |(not ($ :column)) windows))
  (def num-new (length new-windows))
  (when (> num-new 0)
    (each win windows
      (when (and (win :column) (> (win :column) insert-after))
        (put win :column (+ (win :column) num-new)))))
  # Assign new windows to columns right after the focused one
  (var next-col (+ insert-after 1))
  (each win new-windows
    (put win :column next-col)
    (++ next-col))
  # Re-normalize: compact column indices to remove gaps
  (def col-set (sorted (distinct (map |($ :column) windows))))
  (def col-map @{})
  (for i 0 (length col-set)
    (put col-map (get col-set i) i))
  (each win windows
    (put win :column (get col-map (win :column)))))

# Group windows by column, preserving order within each column
(defn group [windows]
  (assign windows)
  (def groups @{})
  (each win windows
    (def col (win :column))
    (unless (groups col) (put groups col @[]))
    (array/push (groups col) win))
  (def col-indices (sorted (keys groups)))
  (map |(get groups $) col-indices))

# Pure placement check: returns :hidden or {:x :y :w :h} geometry spec.
(defn place [x y w h clip-left clip-right clip-top clip-bottom inner]
  (if (or (<= (+ x w (* 2 inner)) clip-left) (>= x clip-right)
          (<= (+ y h (* 2 inner)) clip-top) (>= y clip-bottom))
    :hidden
    {:x (+ x inner) :y (+ y inner) :w w :h h}))

# Get a column's pixel width from the first window's :col-width, or global default
(defn col-width [col total-w default-ratio]
  (math/round (* total-w (or ((first col) :col-width) default-ratio))))

# Compute cumulative x positions for variable-width columns
(defn x-positions [cols total-w default-ratio]
  (def positions @[])
  (var x 0)
  (each col cols
    (array/push positions x)
    (set x (+ x (col-width col total-w default-ratio))))
  positions)

# Build shared context for columns layout (used by layout, navigation, and actions)
(defn context [o &opt windows-override]
  (def windows (or windows-override
                   (filter |(not (or ($ :float) ($ :fullscreen)))
                           (output/visible o (state/wm :windows)))))
  (when (empty? windows) (break nil))
  (def cols (group windows))
  (def num-cols (length cols))
  (def focused-win
    (find |(find (fn [s] (= (s :focused) $)) (state/wm :seats)) windows))
  (var focused-col 0)
  (var focused-row 0)
  (for ci 0 num-cols
    (def col (get cols ci))
    (for ri 0 (length col)
      (when (= (get col ri) focused-win)
        (set focused-col ci)
        (set focused-row ri))))
  @{:windows windows :cols cols :num-cols num-cols
    :focused-win focused-win :focused-col focused-col :focused-row focused-row})

(defn layout [usable windows params config focused]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def struts (or (config :struts) {:left 0 :right 0 :top 0 :bottom 0}))
  (def strut-t (or (struts :top) 0))
  (def strut-b (or (struts :bottom) 0))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def default-ratio (params :column-width))
  (def row-h-ratio (or (config :column-row-height) 0))

  # Build context from windows passed in (already filtered tiled)
  (when (empty? windows) (break @[]))
  (def cols (group windows))
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

  (def col-xs (x-positions cols total-w default-ratio))
  (def total-content-w
    (+ (last col-xs) (col-width (last cols) total-w default-ratio)))

  (def strut-l (or (struts :left) 0))
  (def strut-r (or (struts :right) 0))
  (def focused-x (get col-xs focused-col-idx))
  (def focused-col-w (col-width (get cols focused-col-idx) total-w default-ratio))

  # Compute scroll target — skip when no window is focused on this output
  # so the scroll stays where it was when focus left.
  (when focused-win
    (def max-scroll (max 0 (- total-content-w total-w)))
    (def eff-strut-l (if (> focused-col-idx 0) strut-l 0))
    (def eff-strut-r (if (< focused-col-idx (- num-cols 1)) strut-r 0))
    (var target-scroll (params :scroll-offset))
    (when (< focused-x (+ target-scroll eff-strut-l))
      (set target-scroll (- focused-x eff-strut-l)))
    (when (> (+ focused-x focused-col-w) (- (+ target-scroll total-w) eff-strut-r))
      (set target-scroll (+ (- (+ focused-x focused-col-w) total-w) eff-strut-r)))
    (set target-scroll (min max-scroll (max 0 target-scroll)))
    (animation/scroll-toward params :scroll-offset target-scroll))
  (animation/scroll-update params :scroll-offset)
  (def scroll (params :scroll-offset))

  (def clip-left (+ (usable :x) outer))
  (def clip-right (+ clip-left total-w))
  (def clip-top (+ (usable :y) outer))
  (def clip-bottom (+ clip-top total-h))

  (def results @[])
  (for ci 0 num-cols
    (def col (get cols ci))
    (def cw (col-width col total-w default-ratio))
    (def x-off (- (get col-xs ci) scroll))
    (def num-rows (length col))

    # Row heights
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

    # Per-column vertical scroll (effect)
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
          (def can-v-peek (>= max-v-scroll (+ strut-t strut-b)))
          (def min-v-scroll (if can-v-peek strut-b 0))
          (def max-v-scroll-adj (if can-v-peek (- max-v-scroll strut-t) max-v-scroll))
          (var target-v (params scroll-key))
          (when (< focused-y (+ target-v strut-t))
            (set target-v (- focused-y strut-t)))
          (when (> (+ focused-y focused-h) (- (+ target-v total-h) strut-b))
            (set target-v (+ (- (+ focused-y focused-h) total-h) strut-b)))
          (set target-v (min max-v-scroll-adj (max min-v-scroll target-v)))
          (animation/scroll-toward params scroll-key target-v))
        (animation/scroll-update params scroll-key)
        (set v-scroll (or (params scroll-key) 0)))
      (do
        (put params scroll-key 0)
        (put params (keyword (string "scroll-y-" ci "-anim")) nil)))

    # Place windows (pure geometry)
    (var y-acc 0)
    (for ri 0 num-rows
      (def win (get col ri))
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
  results)

(defn navigate [n main-count i dir ctx]
  (when-let [seat (first (state/wm :seats))
             o (when-let [w (seat :focused)] (find |(($ :tags) (w :tag)) (state/wm :outputs)))
             col-ctx (context o)]
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
