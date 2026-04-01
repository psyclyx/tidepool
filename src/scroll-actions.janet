# Actions for the scrolling tiled layout.
# Each action is (fn [ctx s] ...) where s is a seat.

(import ./tree)

# --- Helpers ---

(defn- active-tag
  "Get the tag state for the seat's focused output."
  [ctx s]
  (when-let [o (s :focused-output)
             tag-id (o :primary-tag)]
    (get-in ctx [:tags tag-id])))

(defn- focused-leaf
  "Get the currently focused leaf node from tag state."
  [ctx s]
  (when-let [tag (active-tag ctx s)
             fid (tag :focused-id)]
    (var found nil)
    (each col (tag :columns)
      (when (not found)
        (set found (tree/find-leaf col fid))))
    found))

(defn- set-focus
  "Set focus to a leaf node, updating tag and active path."
  [ctx s tag leaf-node]
  (when leaf-node
    (put tag :focused-id (leaf-node :window))
    (tree/update-active-path leaf-node)))

# --- Directional neighbor finding ---

(defn find-directional-neighbor
  "Find the neighbor in a given direction from the focused leaf.
   Returns the neighbor leaf or nil (no-op)."
  [columns leaf-node direction]
  (var node leaf-node)
  (var result nil)

  (case direction
    :left
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (if (= (p :orientation) :horizontal)
          (let [idx (tree/child-index node)]
            (if (> idx 0)
              (set result (tree/last-leaf ((p :children) (dec idx))))
              (set node p)))
          (set node p))
        # At column level
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (> col-idx 0))
            (set result (tree/last-leaf (columns (dec col-idx)))))
          (set node nil))))

    :right
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (if (= (p :orientation) :horizontal)
          (let [idx (tree/child-index node)]
            (if (< idx (dec (length (p :children))))
              (set result (tree/first-leaf ((p :children) (inc idx))))
              (set node p)))
          (set node p))
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (< col-idx (dec (length columns))))
            (set result (tree/first-leaf (columns (inc col-idx)))))
          (set node nil))))

    :up
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (if (= (p :orientation) :vertical)
          (let [idx (tree/child-index node)]
            (if (> idx 0)
              (set result (tree/last-leaf ((p :children) (dec idx))))
              (set node nil)))
          (set node p))
        (set node nil)))

    :down
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (if (= (p :orientation) :vertical)
          (let [idx (tree/child-index node)]
            (if (< idx (dec (length (p :children))))
              (set result (tree/first-leaf ((p :children) (inc idx))))
              (set node nil)))
          (set node p))
        (set node nil))))

  result)

# --- Focus ---

(defn focus-left [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :left)]
      (set-focus ctx s tag target))))

(defn focus-right [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :right)]
      (set-focus ctx s tag target))))

(defn focus-up [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :up)]
      (set-focus ctx s tag target))))

(defn focus-down [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :down)]
      (set-focus ctx s tag target))))

# --- Tab cycling ---

(defn focus-tab-next [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (var node leaf)
    (while (node :parent)
      (def p (node :parent))
      (when (tree/tabbed? p)
        (def idx (p :active))
        (when (< idx (dec (length (p :children))))
          (put p :active (inc idx))
          (set-focus ctx s tag (tree/first-leaf ((p :children) (inc idx)))))
        (break))
      (set node p))))

(defn focus-tab-prev [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (var node leaf)
    (while (node :parent)
      (def p (node :parent))
      (when (tree/tabbed? p)
        (def idx (p :active))
        (when (> idx 0)
          (put p :active (dec idx))
          (set-focus ctx s tag (tree/first-leaf ((p :children) (dec idx)))))
        (break))
      (set node p))))

# --- Swap ---

(defn- swap-windows [a b]
  (def wa (a :window))
  (def wb (b :window))
  (put a :window wb)
  (put b :window wa))

(defn swap-left [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :left)]
      (swap-windows leaf target)
      (set-focus ctx s tag target))))

(defn swap-right [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :right)]
      (swap-windows leaf target)
      (set-focus ctx s tag target))))

(defn swap-up [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :up)]
      (swap-windows leaf target)
      (set-focus ctx s tag target))))

(defn swap-down [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (when-let [target (find-directional-neighbor (tag :columns) leaf :down)]
      (swap-windows leaf target)
      (set-focus ctx s tag target))))

# --- Join ---

(defn- detach-leaf
  "Remove a leaf from the tree, collapsing empty parents.
   Returns true if the column was removed."
  [columns leaf-node]
  (def [col-removed _] (tree/remove-leaf columns leaf-node))
  col-removed)

(defn- join-into
  "Join leaf into the container that holds neighbor, or wrap neighbor."
  [columns leaf-node neighbor direction]
  (def orient (if (or (= direction :left) (= direction :right))
                :vertical :horizontal))
  (def pos (if (or (= direction :left) (= direction :up))
             :before :after))
  (def np (neighbor :parent))
  (if (and np (> (length (np :children)) 1))
    # Multi-child parent — insert alongside
    (let [ni (tree/child-index neighbor)
          insert-idx (if (or (= direction :right) (= direction :down))
                       (inc ni) ni)]
      (tree/insert-child np insert-idx leaf-node))
    # Single-child wrapper or no parent — wrap with correct orientation
    (tree/wrap-in-container columns neighbor :split orient leaf-node pos)))

(defn- do-join [ctx s direction]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (def columns (tag :columns))
    (def neighbor (find-directional-neighbor columns leaf direction))
    (unless neighbor (break))
    (detach-leaf columns leaf)
    (join-into columns leaf neighbor direction)
    (set-focus ctx s tag leaf)))

(defn join-left [ctx s] (do-join ctx s :left))
(defn join-right [ctx s] (do-join ctx s :right))
(defn join-up [ctx s] (do-join ctx s :up))
(defn join-down [ctx s] (do-join ctx s :down))

# --- Leave ---

(defn leave [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    # Already a top-level column (sole child of root wrapper)
    (def parent (leaf :parent))
    (when (and (tree/root? parent) (= 1 (length (parent :children))))
      (break))
    (def columns (tag :columns))
    (def col-idx (tree/find-column-index columns leaf))
    (def default-width (get-in ctx [:config :default-column-width] 1.0))
    (detach-leaf columns leaf)
    (put leaf :width default-width)
    # Insert as new column to the right of the old column
    (def insert-idx (min (inc (or col-idx 0)) (length columns)))
    (tree/insert-column columns insert-idx leaf)
    (set-focus ctx s tag leaf)))

# --- Width cycling ---

(defn cycle-width
  "Return an action that cycles column width through presets in the given direction."
  [direction]
  (fn [ctx s]
    (when-let [tag (active-tag ctx s)
               leaf (focused-leaf ctx s)]
      (def col (tree/column-of leaf))
      (def presets (get-in ctx [:config :width-presets] @[0.33 0.5 0.66 0.8 1.0]))
      (def current (col :width))
      # Find nearest preset
      (var best-idx 0)
      (var best-dist math/inf)
      (for i 0 (length presets)
        (def d (math/abs (- (presets i) current)))
        (when (< d best-dist)
          (set best-dist d)
          (set best-idx i)))
      (def new-idx
        (case direction
          :forward (min (inc best-idx) (dec (length presets)))
          :backward (max (dec best-idx) 0)))
      (put col :width (presets new-idx)))))

(def cycle-width-forward (cycle-width :forward))
(def cycle-width-backward (cycle-width :backward))

# --- Insert mode ---

(defn toggle-insert-mode [ctx s]
  (when-let [tag (active-tag ctx s)]
    (put tag :insert-mode
      (if (= (tag :insert-mode) :child) :sibling :child))))

# --- Container mode conversion ---

(defn- set-container-mode [ctx s mode]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)
             p (leaf :parent)]
    (put p :mode mode)))

(defn make-tabbed [ctx s] (set-container-mode ctx s :tabbed))
(defn make-split [ctx s] (set-container-mode ctx s :split))

(defn- set-container-orientation [ctx s orient]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)
             p (leaf :parent)]
    (put p :orientation orient)))

(defn make-horizontal [ctx s] (set-container-orientation ctx s :horizontal))
(defn make-vertical [ctx s] (set-container-orientation ctx s :vertical))

# --- Close ---

(defn close-focused [ctx s]
  (when-let [w (s :focused)]
    (:close (w :obj))))

# --- Spawn ---

(defn spawn [& cmd]
  (fn [ctx s]
    (ev/go (fn [] (os/proc-wait (os/spawn [;cmd] :p))))))
