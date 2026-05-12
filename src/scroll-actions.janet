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
    (fid :tree-leaf)))

(defn- set-focus
  "Set focus to a leaf node, updating tag and active path."
  [ctx s tag leaf-node]
  (when leaf-node
    (put tag :focused-id (leaf-node :window))
    (tree/update-active-path leaf-node)
    true))

# --- Directional neighbor finding ---

(defn find-directional-neighbor
  "Find the neighbor in a given direction from the focused leaf.
   Orientation is derived from depth (alternating splits)."
  [columns leaf-node direction]
  (var node leaf-node)
  (var result nil)
  (var depth (tree/node-depth leaf-node))

  (case direction
    :left
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :horizontal)
            (let [idx (tree/child-index node)]
              (if (> idx 0)
                (set result (tree/last-leaf ((p :children) (dec idx))))
                (do (set node p) (-- depth))))
            (do (set node p) (-- depth))))
        # At column level
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (> col-idx 0))
            (set result (tree/last-leaf (columns (dec col-idx)))))
          (set node nil))))

    :right
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :horizontal)
            (let [idx (tree/child-index node)]
              (if (< idx (dec (length (p :children))))
                (set result (tree/first-leaf ((p :children) (inc idx))))
                (do (set node p) (-- depth))))
            (do (set node p) (-- depth))))
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (< col-idx (dec (length columns))))
            (set result (tree/first-leaf (columns (inc col-idx)))))
          (set node nil))))

    :up
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :vertical)
            (let [idx (tree/child-index node)]
              (if (> idx 0)
                (set result (tree/last-leaf ((p :children) (dec idx))))
                (set node nil)))
            (do (set node p) (-- depth))))
        (set node nil)))

    :down
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :vertical)
            (let [idx (tree/child-index node)]
              (if (< idx (dec (length (p :children))))
                (set result (tree/first-leaf ((p :children) (inc idx))))
                (set node nil)))
            (do (set node p) (-- depth))))
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

# --- Structural neighbor finding (for swap) ---

(defn find-structural-neighbor
  "Find the structural sibling in a given direction from a leaf.
   Returns [swap-node neighbor] or nil."
  [columns leaf-node direction]
  (var node leaf-node)
  (var result nil)
  (var depth (tree/node-depth leaf-node))

  (case direction
    :left
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :horizontal)
            (let [idx (tree/child-index node)]
              (if (> idx 0)
                (set result [node ((p :children) (dec idx))])
                (do (set node p) (-- depth))))
            (do (set node p) (-- depth))))
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (> col-idx 0))
            (set result [node (columns (dec col-idx))]))
          (set node nil))))

    :right
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :horizontal)
            (let [idx (tree/child-index node)]
              (if (< idx (dec (length (p :children))))
                (set result [node ((p :children) (inc idx))])
                (do (set node p) (-- depth))))
            (do (set node p) (-- depth))))
        (let [col-idx (tree/find-column-index columns node)]
          (when (and col-idx (< col-idx (dec (length columns))))
            (set result [node (columns (inc col-idx))]))
          (set node nil))))

    :up
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :vertical)
            (let [idx (tree/child-index node)]
              (if (> idx 0)
                (set result [node ((p :children) (dec idx))])
                (set node nil)))
            (do (set node p) (-- depth))))
        (set node nil)))

    :down
    (while (and (not result) node)
      (if-let [p (node :parent)]
        (let [orient (tree/orientation-at-depth (dec depth))]
          (if (= orient :vertical)
            (let [idx (tree/child-index node)]
              (if (< idx (dec (length (p :children))))
                (set result [node ((p :children) (inc idx))])
                (set node nil)))
            (do (set node p) (-- depth))))
        (set node nil))))

  result)

# --- Detach helper ---

(defn- detach-leaf
  "Remove a leaf from the tree, collapsing empty parents.
   Returns true if the column was removed."
  [columns leaf-node]
  (def [col-removed _] (tree/remove-leaf columns leaf-node))
  col-removed)

# --- Edge detection (for extract-on-swap) ---

(defn- direction-axis [direction]
  (case direction :left :horizontal :right :horizontal
                  :up :vertical :down :vertical))

(defn- at-start? [direction]
  (case direction :left true :up true :right false :down false))

(defn- find-edge-container
  "Walk up from node to find the nearest ancestor container where the node
   is at the directional edge. Uses depth-derived orientation."
  [node direction]
  (def axis (direction-axis direction))
  (def start (at-start? direction))
  (var child node)
  (var depth (tree/node-depth node))
  (var result nil)
  (while (and (not result) (child :parent))
    (def p (child :parent))
    (-- depth)
    (when (and (= (tree/orientation-at-depth depth) axis)
               (> (length (p :children)) 1))
      (def idx (tree/child-index child))
      (if start
        (when (= idx 0) (set result [p child]))
        (when (= idx (dec (length (p :children)))) (set result [p child]))))
    (set child p))
  result)

# --- Swap ---

(defn- do-swap [ctx s direction]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (def columns (tag :columns))
    (if-let [pair (find-structural-neighbor columns leaf direction)]
      # Normal structural swap
      (let [[swap-node target] pair]
        (tree/swap-children columns swap-node target)
        (set-focus ctx s tag leaf))
      # At edge — extract from container
      (when-let [[source _] (find-edge-container leaf direction)]
        (def source-is-root (tree/root? source))
        (def sc-idx (tree/find-column-index columns source))
        (def source-parent (source :parent))
        (def source-idx (when source-parent (tree/child-index source)))
        (def default-width (get-in ctx [:config :default-column-width] 0.5))
        (detach-leaf columns leaf)
        (put leaf :width default-width)
        (if source-is-root
          (let [insert-idx (if (at-start? direction)
                             (or sc-idx 0)
                             (min (inc (or sc-idx 0)) (length columns)))]
            (tree/insert-column columns insert-idx leaf))
          (tree/insert-child source-parent
            (if (at-start? direction) source-idx (inc source-idx))
            leaf))
        (set-focus ctx s tag leaf)))))

(defn swap-left [ctx s] (do-swap ctx s :left))
(defn swap-right [ctx s] (do-swap ctx s :right))
(defn swap-up [ctx s] (do-swap ctx s :up))
(defn swap-down [ctx s] (do-swap ctx s :down))

# --- Absorb (pull neighbor into focused window's group) ---

(defn- do-absorb [ctx s direction]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (def columns (tag :columns))
    (def neighbor (find-directional-neighbor columns leaf direction))
    (unless neighbor (break))
    # Detach the neighbor from its current position
    (def neighbor-leaf neighbor)
    (detach-leaf columns neighbor-leaf)
    # Insert neighbor into focused window's parent container
    (def p (leaf :parent))
    (if (and p (> (length (p :children)) 1))
      # Already in a multi-child container: insert alongside focused leaf
      (let [idx (tree/child-index leaf)
            insert-idx (if (or (= direction :right) (= direction :down))
                         (inc idx) idx)]
        (tree/insert-child p insert-idx neighbor-leaf))
      # Leaf is alone (sole child of column wrapper): wrap into new container
      (let [pos (if (or (= direction :left) (= direction :up))
                  :before :after)]
        (tree/wrap-in-container columns leaf :split neighbor-leaf pos)))
    (set-focus ctx s tag leaf)))

(defn absorb-left [ctx s] (do-absorb ctx s :left))
(defn absorb-right [ctx s] (do-absorb ctx s :right))
(defn absorb-up [ctx s] (do-absorb ctx s :up))
(defn absorb-down [ctx s] (do-absorb ctx s :down))

# --- Eject (push focused window out of its group) ---

(defn eject [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    # Already a top-level column (sole child of root wrapper)
    (def parent (leaf :parent))
    (when (and (tree/root? parent) (= 1 (length (parent :children))))
      (break))
    (def columns (tag :columns))
    (def col-idx (tree/find-column-index columns leaf))
    (def default-width (get-in ctx [:config :default-column-width] 0.5))
    (detach-leaf columns leaf)
    (put leaf :width default-width)
    # Insert as new column to the right of the old column
    (def insert-idx (min (inc (or col-idx 0)) (length columns)))
    (tree/insert-column columns insert-idx leaf)
    (set-focus ctx s tag leaf)))

# --- Expel (push edge child out of focused window's group) ---

(defn- do-expel [ctx s direction]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (def columns (tag :columns))
    (def axis (direction-axis direction))
    (def start (at-start? direction))
    # Walk up from leaf to find a container with matching orientation
    (var node leaf)
    (var depth (tree/node-depth leaf))
    (var target-container nil)
    (while (and (not target-container) (node :parent))
      (def p (node :parent))
      (-- depth)
      (when (and (= (tree/orientation-at-depth depth) axis)
                 (> (length (p :children)) 1))
        (set target-container p))
      (set node p))
    (unless target-container (break))
    # Pick the edge child
    (def children (target-container :children))
    (def edge-idx (if start 0 (dec (length children))))
    (def edge-child (children edge-idx))
    # Get the first leaf of the edge child to use as the detach target
    (def edge-leaf (tree/first-leaf edge-child))
    # Find column position before detach
    (def col-idx (tree/find-column-index columns edge-child))
    (def default-width (get-in ctx [:config :default-column-width] 0.5))
    # If edge child is a subtree, detach the whole subtree
    (tree/remove-child edge-child)
    (tree/collapse-singles target-container)
    (put edge-child :width default-width)
    # Insert as new column adjacent to the old column
    (def insert-idx
      (if start
        (or col-idx 0)
        (min (inc (or col-idx 0)) (length columns))))
    (tree/insert-column columns insert-idx edge-child)
    (set-focus ctx s tag leaf)))

(defn expel-left [ctx s] (do-expel ctx s :left))
(defn expel-right [ctx s] (do-expel ctx s :right))
(defn expel-up [ctx s] (do-expel ctx s :up))
(defn expel-down [ctx s] (do-expel ctx s :down))

# --- Width cycling ---

(defn grow
  "Cycle column width forward through presets, wrapping around."
  [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (def col (tree/column-of leaf))
    (def presets (get-in ctx [:config :width-presets] @[0.5 0.66 0.8 1.0]))
    (def current (col :width))
    # Find nearest preset
    (var best-idx 0)
    (var best-dist math/inf)
    (for i 0 (length presets)
      (def d (math/abs (- (presets i) current)))
      (when (< d best-dist)
        (set best-dist d)
        (set best-idx i)))
    (def new-idx (% (inc best-idx) (length presets)))
    (put col :width (presets new-idx))))

(defn- clamp-ratio [ratio min-v max-v]
  (def lo (max 0.001 (or min-v 0.001)))
  (def hi (when (and max-v (> max-v 0)) max-v))
  (max lo (if hi (min hi ratio) ratio)))

(defn- nearest-split-child [leaf axis]
  (var child leaf)
  (var parent (child :parent))
  (var result nil)
  (while (and parent (not result))
    (when (and (tree/split? parent)
               (= (tree/node-orientation parent) axis)
               (> (length (parent :children)) 1))
      (set result [parent child]))
    (set child parent)
    (set parent (child :parent)))
  result)

(defn- resize-split-child [ctx leaf axis grow?]
  (when-let [[parent child] (nearest-split-child leaf axis)]
    (def children (parent :children))
    (def idx (tree/child-index child))
    (def neighbor
      (if (< idx (dec (length children)))
        (children (inc idx))
        (when (> idx 0) (children (dec idx)))))
    (unless neighbor (break nil))
    (def min-r (get-in ctx [:config :split-min-width] 0.1))
    (def step (get-in ctx [:config :split-resize-step] 0.1))
    (def donor (if grow? neighbor child))
    (def receiver (if grow? child neighbor))
    (def available (max 0 (- (donor :width) min-r)))
    (def delta (min step available))
    (when (> delta 0)
      (put donor :width (- (donor :width) delta))
      (put receiver :width (+ (receiver :width) delta))
      true)))

(defn- resize-column [ctx leaf grow?]
  (def col (tree/column-of leaf))
  (def step (get-in ctx [:config :column-resize-step] 0.05))
  (def min-r (get-in ctx [:config :column-min-width] 0.2))
  (def max-r (get-in ctx [:config :column-max-width] 2.0))
  (def delta (if grow? step (- step)))
  (put col :width (clamp-ratio (+ (col :width) delta) min-r max-r))
  true)

(defn- resize-focused [ctx s axis grow?]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (or (resize-split-child ctx leaf axis grow?)
        (when (= axis :horizontal)
          (resize-column ctx leaf grow?)))))

(defn shrink-width [ctx s] (resize-focused ctx s :horizontal false))
(defn grow-width [ctx s] (resize-focused ctx s :horizontal true))
(defn shrink-height [ctx s] (resize-focused ctx s :vertical false))
(defn grow-height [ctx s] (resize-focused ctx s :vertical true))

(defn reset-size [ctx s]
  "Reset the nearest split containing the focused window, or the column width."
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)]
    (var child leaf)
    (var parent (child :parent))
    (var split nil)
    (while (and parent (not split))
      (when (and (tree/split? parent)
                 (> (length (parent :children)) 1))
        (set split parent))
      (set child parent)
      (set parent (child :parent)))
    (if split
      (do
        (each child (split :children)
          (put child :width 1.0))
        true)
      (do
        (put (tree/column-of leaf) :width
             (get-in ctx [:config :default-column-width] 0.5))
        true))))

# --- Container mode toggle ---

(defn toggle-split-tabbed [ctx s]
  (when-let [tag (active-tag ctx s)
             leaf (focused-leaf ctx s)
             p (leaf :parent)]
    (put p :mode (if (= (p :mode) :tabbed) :split :tabbed))))

# --- Close ---

(defn close-focused [ctx s]
  (when-let [w (s :focused)]
    (:close (w :obj))))

# --- Spawn ---

(defn spawn [& cmd]
  (fn [ctx s]
    (ev/go (fn [] (os/proc-wait (os/spawn [;cmd] :p))))))
