# Actions for floating windows.
# Each action is (fn [ctx s] ...) where s is a seat.

(import ./tree)
(import ./window)
(import ./state)
(import ./seat)

# --- Toggle ---

(defn toggle-float [ctx s]
  (when-let [w (s :focused)]
    (if (w :float)
      # Unfloat: insert into tree as new column
      (do
        (window/set-float w false)
        (put w :float-vx nil)
        (put w :float-vy nil)
        (def tag-id (w :tag))
        (def tag (state/ensure-tag ctx tag-id))
        (def config (ctx :config))
        (def leaf (tree/leaf w (config :default-column-width)))
        (put w :tree-leaf leaf)
        (tree/insert-column (tag :columns) (length (tag :columns)) leaf)
        (put tag :focused-id w)
        (tree/update-active-path leaf))
      # Float: remove from tree, anchor at current position
      (do
        (when-let [leaf (w :tree-leaf)]
          (when-let [tag-id (w :tag)
                     tag (get-in ctx [:tags tag-id])]
            (def columns (tag :columns))
            (def col-idx (tree/find-column-index columns leaf))
            (def child-idx (or (tree/child-index leaf) 0))
            (def [col-removed result] (tree/remove-leaf columns leaf))
            (when (= (tag :focused-id) w)
              (def successor (tree/focus-successor columns
                               (or col-idx 0) child-idx
                               (if col-removed nil result)))
              (if successor
                (do (put tag :focused-id (successor :window))
                    (tree/update-active-path successor))
                (put tag :focused-id nil))))
          (put w :tree-leaf nil))
        (window/set-float w true)
        # Anchor at current position — vx is virtual x from scroll layout
        (when (w :vx)
          (put w :float-vx (w :vx))
          (put w :float-vy (or (w :y) 0)))))))

# --- Helpers ---

(defn tag-floats
  "Get visible floating windows on the seat's focused tag."
  [ctx s]
  (when-let [o (s :focused-output)
             tag-id (o :primary-tag)]
    (filter |(and ($ :float) (not ($ :closed)) (= ($ :tag) tag-id))
            (ctx :windows))))

(defn- win-center [w]
  [(+ (or (w :float-vx) 0) (/ (or (w :w) 0) 2))
   (+ (or (w :float-vy) 0) (/ (or (w :h) 0) 2))])

(defn focus-directional
  "Focus the nearest float in a direction from the current window."
  [ctx s direction]
  (def floats (tag-floats ctx s))
  (when (and floats (not (empty? floats)))
    (def current (s :focused))
    (def [cx cy] (if (and current (current :float))
                   (win-center current)
                   # Focused tiled window — use screen position
                   (let [w current
                         ww (or (w :w) 0) wh (or (w :h) 0)
                         vx (or (w :vx) 0) wy (or (w :y) 0)]
                     [vx wy])))
    (var best nil)
    (var best-dist math/inf)
    (each f floats
      (when (not= f current)
        (def [fx fy] (win-center f))
        (def valid
          (case direction
            :left (< fx cx)
            :right (> fx cx)
            :up (< fy cy)
            :down (> fy cy)))
        (when valid
          (def dist (+ (math/abs (- fx cx)) (math/abs (- fy cy))))
          (when (< dist best-dist)
            (set best-dist dist)
            (set best f)))))
    (when best
      (seat/focus s best)
      true)))

(defn move-directional
  "Move a floating window in a direction by a step."
  [ctx s direction]
  (when-let [w (s :focused)]
    (when (w :float)
      (def step-x (div (or (w :w) 100) 2))
      (def step-y (div (or (w :h) 100) 2))
      (case direction
        :left (put w :float-vx (- (or (w :float-vx) 0) step-x))
        :right (put w :float-vx (+ (or (w :float-vx) 0) step-x))
        :up (put w :float-vy (- (or (w :float-vy) 0) step-y))
        :down (put w :float-vy (+ (or (w :float-vy) 0) step-y)))
      true)))

(defn focus-tiled
  "Jump from a float back to the tiled tree's focused window."
  [ctx s]
  (when (and (s :focused) ((s :focused) :float))
    (when-let [o (s :focused-output)
               tag-id (o :primary-tag)
               tag (get-in ctx [:tags tag-id])
               fwin (tag :focused-id)]
      (when (and fwin (not (fwin :closed)))
        (seat/focus s fwin)
        true))))

(defn toggle-focus-float
  "Toggle focus between float layer and tiled layer."
  [ctx s]
  (if (and (s :focused) ((s :focused) :float))
    (focus-tiled ctx s)
    # Focus the most recent float, or first available
    (let [floats (tag-floats ctx s)]
      (when (and floats (not (empty? floats)))
        (seat/focus s (first floats))
        true))))

# --- Focus cycling ---

(defn focus-float-next [ctx s]
  (def floats (tag-floats ctx s))
  (when (and floats (not (empty? floats)))
    (def current (s :focused))
    (def idx (or (find-index |(= $ current) floats) -1))
    (def next-idx (% (+ idx 1) (length floats)))
    (seat/focus s (floats next-idx))))

(defn focus-float-prev [ctx s]
  (def floats (tag-floats ctx s))
  (when (and floats (not (empty? floats)))
    (def current (s :focused))
    (def idx (or (find-index |(= $ current) floats) -1))
    (def next-idx (% (+ idx (- (length floats) 1)) (length floats)))
    (seat/focus s (floats next-idx))))

# --- Gather ---

(defn gather-floats [ctx s]
  (when-let [o (s :focused-output)
             tag-id (o :primary-tag)
             tag (get-in ctx [:tags tag-id])]
    (def cam (or (tag :camera) 0))
    (def ow (or (o :w) 1920))
    (def oh (or (o :h) 1080))
    (def oy (or (o :y) 0))
    (def floats (filter |(and ($ :float) (not ($ :closed)) (= ($ :tag) tag-id))
                        (ctx :windows)))
    # Arrange floats in a grid centered on viewport
    (def n (length floats))
    (when (> n 0)
      (def cols-n (math/ceil (math/sqrt n)))
      (def rows-n (math/ceil (/ n cols-n)))
      (def cell-w (div ow (+ cols-n 1)))
      (def cell-h (div oh (+ rows-n 1)))
      (for i 0 n
        (def w (floats i))
        (def col (% i cols-n))
        (def row (div i cols-n))
        (def cx (+ cam (* (+ col 1) cell-w) (- (div (or (w :w) 0) 2))))
        (def cy (+ oy (* (+ row 1) cell-h) (- (div (or (w :h) 0) 2))))
        (put w :float-vx cx)
        (put w :float-vy cy)))))
