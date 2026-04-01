# Node tree operations for the scrolling layout.
# Pure functions — no side effects, no ctx dependency.

(var- next-nid 0)

(defn reset-ids []
  (set next-nid 0))

# --- Node constructors ---

(defn leaf
  "Create a leaf node wrapping a window."
  [window &opt width]
  @{:type :leaf
    :id (++ next-nid)
    :window window
    :width (or width 1.0)
    :parent nil})

(defn container
  "Create a container node. Mode is :split or :tabbed.
   Orientation is :horizontal or :vertical."
  [mode orientation children &opt width]
  (def node @{:type :container
              :id (++ next-nid)
              :mode mode
              :orientation orientation
              :active 0
              :children @[]
              :width (or width 1.0)
              :parent nil})
  (each c children
    (put c :parent node)
    (array/push (node :children) c))
  node)

# --- Predicates ---

(defn leaf? [node] (= (node :type) :leaf))
(defn container? [node] (= (node :type) :container))
(defn tabbed? [node] (and (container? node) (= (node :mode) :tabbed)))
(defn split? [node] (and (container? node) (= (node :mode) :split)))
(defn root? [node] (nil? (node :parent)))

# --- Traversal ---

(defn first-leaf
  "Find the first (leftmost/topmost) leaf in a subtree."
  [node]
  (if (leaf? node)
    node
    (if (tabbed? node)
      (first-leaf ((node :children) (node :active)))
      (first-leaf (first (node :children))))))

(defn last-leaf
  "Find the last (rightmost/bottommost) leaf in a subtree."
  [node]
  (if (leaf? node)
    node
    (if (tabbed? node)
      (last-leaf ((node :children) (node :active)))
      (last-leaf (last (node :children))))))

(defn leaves
  "Collect all leaf nodes in depth-first order."
  [node]
  (if (leaf? node)
    @[node]
    (if (tabbed? node)
      (leaves ((node :children) (node :active)))
      (do
        (def result @[])
        (each c (node :children)
          (array/concat result (leaves c)))
        result))))

(defn all-leaves
  "Collect ALL leaf nodes, including inactive tabs."
  [node]
  (if (leaf? node)
    @[node]
    (do
      (def result @[])
      (each c (node :children)
        (array/concat result (all-leaves c)))
      result)))

(defn find-leaf
  "Find the leaf node containing a window, searching all children including inactive tabs."
  [node window]
  (if (leaf? node)
    (if (= (node :window) window) node nil)
    (do
      (var found nil)
      (each c (node :children)
        (when (not found)
          (set found (find-leaf c window))))
      found)))

(defn column-of
  "Walk up from a node to find its top-level column (root ancestor)."
  [node]
  (if (root? node) node
    (column-of (node :parent))))

(defn child-index
  "Get the index of a node within its parent's children. nil if root."
  [node]
  (when-let [p (node :parent)]
    (find-index |(= $ node) (p :children))))

# --- Mutation helpers ---

(defn- clamp-active [node]
  (when (container? node)
    (put node :active
      (min (node :active)
           (max 0 (dec (length (node :children))))))))

(defn remove-child
  "Remove a child from its parent. Returns the parent (or nil if root).
   Does NOT collapse — call collapse-singles after."
  [node]
  (when-let [p (node :parent)]
    (def idx (child-index node))
    (array/remove (p :children) idx)
    (put node :parent nil)
    (clamp-active p)
    p))

(defn collapse-singles
  "Walk up from node, collapsing any single-child containers.
   Returns the node that ended up in the collapsed position."
  [node]
  (if (and (container? node) (= 1 (length (node :children))))
    (let [child (first (node :children))
          p (node :parent)]
      (put child :width (node :width))
      (put child :parent p)
      (if p
        (do
          (def idx (find-index |(= $ node) (p :children)))
          (put (p :children) idx child)
          (collapse-singles p)
          child)
        child))
    node))

(defn insert-child
  "Insert a child into a container at index."
  [parent idx child]
  (put child :parent parent)
  (array/insert (parent :children) idx child))

(defn append-child
  "Append a child to a container."
  [parent child]
  (put child :parent parent)
  (array/push (parent :children) child))

# --- Column operations (top-level scroll sequence) ---

(defn insert-column
  "Insert a node into the columns array at index."
  [columns idx node]
  (put node :parent nil)
  (array/insert columns idx node))

(defn remove-column
  "Remove a column by index. Returns the removed node."
  [columns idx]
  (def node (columns idx))
  (array/remove columns idx)
  node)

(defn find-column-index
  "Find which column index contains a given node (walks up to root)."
  [columns node]
  (def col (column-of node))
  (find-index |(= $ col) columns))

# --- Structural operations ---

(defn remove-leaf
  "Remove a leaf from the tree. Collapses single-child parents.
   Returns [columns-changed? collapsed-node-or-nil]."
  [columns leaf-node]
  (def col-idx (find-column-index columns leaf-node))
  (if (root? leaf-node)
    # Leaf is a top-level column — just remove it
    (do (remove-column columns col-idx)
        [true nil])
    # Leaf is inside a container
    (let [parent (remove-child leaf-node)
          result (collapse-singles parent)]
      # If the collapse replaced a top-level node, update columns
      (when (and result (root? result) col-idx)
        (put columns col-idx result))
      [false result])))

(defn wrap-in-container
  "Replace a node with a new container holding it and a new sibling.
   sibling-pos is :before or :after."
  [columns node mode orientation sibling sibling-pos]
  (def old-width (node :width))
  (def old-parent (node :parent))
  (def old-idx (when old-parent
                 (find-index |(= $ node) (old-parent :children))))
  (def children (if (= sibling-pos :before)
                  @[sibling node]
                  @[node sibling]))
  (def c (container mode orientation children old-width))
  (if old-parent
    (do
      (put c :parent old-parent)
      (put (old-parent :children) old-idx c))
    # node was a top-level column
    (let [idx (find-index |(= $ node) columns)]
      (put columns idx c)))
  c)

# --- Focus helpers ---

(defn update-active-path
  "Walk from a leaf up to root, updating :active indices on each container."
  [leaf-node]
  (var node leaf-node)
  (while (node :parent)
    (let [p (node :parent)
          idx (find-index |(= $ node) (p :children))]
      (put p :active idx)
      (set node p))))

(defn next-leaf-in-columns
  "Find the next leaf after the given one in column order.
   Returns nil if at the end."
  [columns leaf-node]
  (def all @[])
  (each col columns (array/concat all (leaves col)))
  (when-let [idx (find-index |(= $ leaf-node) all)]
    (when (< idx (dec (length all)))
      (all (inc idx)))))

(defn prev-leaf-in-columns
  "Find the previous leaf before the given one in column order.
   Returns nil if at the start."
  [columns leaf-node]
  (def all @[])
  (each col columns (array/concat all (leaves col)))
  (when-let [idx (find-index |(= $ leaf-node) all)]
    (when (> idx 0)
      (all (dec idx)))))

(defn focus-successor
  "After removing a leaf, find the best node to focus next.
   Takes the columns and the parent that was affected (or nil)."
  [columns old-col-idx old-child-idx parent]
  (cond
    # Parent still has children — focus the nearest one
    (and parent (container? parent) (> (length (parent :children)) 0))
    (let [idx (min old-child-idx (dec (length (parent :children))))]
      (first-leaf ((parent :children) idx)))

    # Parent collapsed to a single leaf
    (and parent (leaf? parent))
    parent

    # Column was removed — try adjacent columns
    (> (length columns) 0)
    (let [idx (min old-col-idx (dec (length columns)))]
      (first-leaf (columns idx)))

    # Nothing left
    nil))
