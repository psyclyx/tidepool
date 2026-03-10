# Pool rendering: recursive layout computation.
# Pure functions — no compositor dependencies. Takes a pool tree and a rect,
# returns an array of placements [{:window :x :y :w :h} ...].

(import ../pool)

(defn- sum [xs] (reduce + 0 xs))

(defn- hide-all
  "Emit {:window w :hidden true} for every window leaf in the subtree."
  [node placements &opt scroll-placed]
  (pool/walk-windows node
    (fn [w] (array/push placements
              (merge @{:window w :hidden true}
                     (if scroll-placed @{:scroll-placed true} @{}))))))

(defn- render-leaf
  "Render a single window at the given rect."
  [window rect placements &opt scroll-placed]
  (array/push placements
    (merge @{:window window :x (rect :x) :y (rect :y)
             :w (rect :w) :h (rect :h)}
           (if scroll-placed @{:scroll-placed true} @{}))))

# Forward declaration
(varfn render-pool [node rect config focused now &opt scroll-placed]
  nil)

# --- Stack (horizontal and vertical) ---

(defn- divide-space
  "Divide a total size among n children by ratio (2 children) or weights."
  [pool total inner n]
  (when (<= n 0) (break @[]))
  (def gap (* inner (- n 1)))
  (def available (- total gap))
  (if (and (= n 2) (pool :ratio))
    (let [first-size (math/round (* available (pool :ratio)))]
      @[first-size (- available first-size)])
    (let [weights (pool :weights)
          ws (seq [i :range [0 n]]
               (or (and weights (get weights i)) 1.0))
          total-w (sum ws)]
      (def sizes @[])
      (var used 0)
      (for i 0 n
        (def size (if (= i (- n 1))
                    (- available used)
                    (math/round (* available (/ (get ws i) total-w)))))
        (array/push sizes size)
        (+= used size))
      sizes)))

(defn render-stack
  "Render a stack-h or stack-v pool."
  [node rect config focused now &opt scroll-placed]
  (def placements @[])
  (def animating false)
  (def children (node :children))
  (def n (length children))
  (when (= n 0) (break {:placements placements :animating false}))
  (def inner (config :inner-padding))
  (def horizontal (= (node :mode) :stack-h))
  (def total (if horizontal (rect :w) (rect :h)))
  (def sizes (divide-space node total inner n))
  (var offset 0)
  (var any-animating false)
  (for i 0 n
    (def child (get children i))
    (def size (get sizes i))
    (def child-rect
      (if horizontal
        @{:x (+ (rect :x) offset) :y (rect :y) :w size :h (rect :h)}
        @{:x (rect :x) :y (+ (rect :y) offset) :w (rect :w) :h size}))
    (def result (render-pool child child-rect config focused now scroll-placed))
    (array/concat placements (result :placements))
    (when (result :animating) (set any-animating true))
    (+= offset (+ size inner)))
  {:placements placements :animating any-animating})

# --- Tabbed ---

(defn render-tabbed
  "Render a tabbed pool: show active child, hide rest."
  [node rect config focused now &opt scroll-placed]
  (def placements @[])
  (def children (node :children))
  (def n (length children))
  (when (= n 0) (break {:placements placements :animating false}))
  (def active (min (max 0 (or (node :active) 0)) (- n 1)))
  # Clamp :active to valid range
  (put node :active active)
  (var any-animating false)
  (for i 0 n
    (def child (get children i))
    (if (= i active)
      (do
        (def result (render-pool child rect config focused now scroll-placed))
        (array/concat placements (result :placements))
        (when (result :animating) (set any-animating true)))
      (hide-all child placements scroll-placed)))
  {:placements placements :animating any-animating})

# --- Scroll ---

(defn- col-width-px
  "Compute a column's pixel width from its :width ratio and the viewport width."
  [child content-w default-ratio]
  (def ratio (or (child :width) default-ratio))
  (math/round (* content-w ratio)))

(defn render-scroll
  "Render a scroll pool: rows x columns, one row visible, horizontal scroll within."
  [node rect config focused now &opt scroll-placed]
  (def placements @[])
  (def children (node :children))
  (def n (length children))
  (when (= n 0) (break {:placements placements :animating false}))

  # Clamp active-row
  (def active-row (min (max 0 (or (node :active-row) 0)) (- n 1)))
  (put node :active-row active-row)

  # Hide non-active rows
  (for i 0 n
    (when (not= i active-row)
      (hide-all (get children i) placements true)))

  (def row (get children active-row))
  # Guard: row must be a pool. If it's a bare window (tree corruption),
  # render it as a single-column leaf rather than crashing.
  (unless (pool/pool? row)
    (render-leaf row rect placements true)
    (break {:placements placements :animating false}))
  (def cols (row :children))
  (def num-cols (length cols))
  (when (= num-cols 0)
    (break {:placements placements :animating false}))

  (def inner (config :inner-padding))
  (def peek (* 2 inner))
  (def default-ratio (or (config :column-width) 0.5))
  (def content-w (- (rect :w) (* 2 inner)))

  # Compute column x-positions in content space
  (def col-xs @[])
  (var x-acc 0)
  (for i 0 num-cols
    (array/push col-xs x-acc)
    (+= x-acc (col-width-px (get cols i) content-w default-ratio)))
  (def total-content-w (+ (* 2 inner) x-acc))

  # Find focused column
  (var focused-col-idx 0)
  (when focused
    (for i 0 num-cols
      (def col (get cols i))
      (when (or (= col focused)
                (and (pool/pool? col) (pool/find-window col focused)))
        (set focused-col-idx i)
        (break))))

  # Compute scroll target
  (def max-scroll (max 0 (- total-content-w (rect :w))))
  (unless (node :scroll-offset-x) (put node :scroll-offset-x @{}))
  (def scroll-offsets (node :scroll-offset-x))
  (unless (get scroll-offsets active-row) (put scroll-offsets active-row 0))

  (when focused
    (def focused-x (+ inner (get col-xs focused-col-idx)))
    (def focused-w (col-width-px (get cols focused-col-idx) content-w default-ratio))
    (def col-right (+ focused-x focused-w))
    (def peek-l (if (> focused-col-idx 0) peek 0))
    (def peek-r (if (< focused-col-idx (- num-cols 1)) peek 0))
    (def min-s (max 0 (- col-right (- (rect :w) peek-r))))
    (def max-s (min max-scroll (- focused-x peek-l)))
    (def current (get scroll-offsets active-row))
    (def target (min max-s (max min-s current)))
    (put scroll-offsets active-row target))

  (def scroll (or (get scroll-offsets active-row) 0))
  (def clip-left (rect :x))
  (def clip-right (+ (rect :x) (rect :w)))

  # Place columns
  (var any-animating false)
  (for i 0 num-cols
    (def col (get cols i))
    (def cw (col-width-px col content-w default-ratio))
    (def col-x (+ (rect :x) inner (get col-xs i) (- scroll)))
    (def col-right-edge (+ col-x cw))
    # Off-screen check
    (if (or (<= col-right-edge clip-left) (>= col-x clip-right))
      (hide-all col placements true)
      (do
        (def col-rect @{:x col-x :y (rect :y) :w cw :h (rect :h)})
        (def result (render-pool col col-rect config focused now true))
        (array/concat placements (result :placements))
        (when (result :animating) (set any-animating true)))))

  {:placements placements :animating any-animating})

# --- Dispatcher ---

(varfn render-pool [node rect config focused now &opt scroll-placed]
  (if (pool/window? node)
    (let [p @[]]
      (render-leaf node rect p scroll-placed)
      {:placements p :animating false})
    (case (node :mode)
      :stack-h (render-stack node rect config focused now scroll-placed)
      :stack-v (render-stack node rect config focused now scroll-placed)
      :tabbed (render-tabbed node rect config focused now scroll-placed)
      :scroll (render-scroll node rect config focused now scroll-placed)
      # Default: treat as stack-v
      (render-stack node rect config focused now scroll-placed))))
