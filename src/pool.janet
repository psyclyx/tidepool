# Pool: recursive group containers for tidepool layout.
# A pool has a :mode, :children (windows or pools), and :parent back-pointer.
# Windows are leaf nodes — any table without :children is treated as a window.

(defn pool? [node]
  "True if node is a pool (has :children)."
  (and (dictionary? node) (node :children)))

(defn window? [node]
  "True if node is a window (dictionary without :children)."
  (and (dictionary? node) (not (node :children))))

(defn make-pool
  "Create a pool with the given mode and children. Sets :parent on all children."
  [mode children &opt props]
  (def pool @{:mode mode :children (array ;children)})
  (when props (merge-into pool props))
  (each child (pool :children)
    (put child :parent pool))
  pool)

(defn insert-child
  "Insert child into pool at index. Sets :parent."
  [pool child index]
  (array/insert (pool :children) index child)
  (put child :parent pool))

(defn append-child
  "Append child to end of pool's children. Sets :parent."
  [pool child]
  (array/push (pool :children) child)
  (put child :parent pool))

(defn remove-child
  "Remove and return the child at index. Clears :parent."
  [pool index]
  (def child (get (pool :children) index))
  (array/remove (pool :children) index)
  (put child :parent nil)
  child)

(defn child-index
  "Return the index of child in pool's children, or nil."
  [pool child]
  (find-index |(= $ child) (pool :children)))

(defn wrap-children
  "Wrap children [start, end) in a new sub-pool with the given mode.
  Returns the new wrapper pool."
  [pool start end mode]
  (def wrapped @[])
  (for i start end
    (array/push wrapped (get (pool :children) i)))
  (def wrapper (make-pool mode wrapped))
  # Remove originals and insert wrapper
  (for _ start end
    (array/remove (pool :children) start))
  (array/insert (pool :children) start wrapper)
  (put wrapper :parent pool)
  wrapper)

(defn unwrap-pool
  "Replace the child pool at index with its children. Fix :parent pointers."
  [pool index]
  (def child (get (pool :children) index))
  (def grandchildren (child :children))
  (array/remove (pool :children) index)
  (var i index)
  (each gc grandchildren
    (array/insert (pool :children) i gc)
    (put gc :parent pool)
    (++ i)))

(defn move-child
  "Remove child at from-idx in from-pool, insert at to-idx in to-pool."
  [from-pool from-idx to-pool to-idx]
  (def child (remove-child from-pool from-idx))
  (insert-child to-pool child to-idx))

(defn walk-windows
  "Call f on every window leaf in the tree (depth-first)."
  [node f]
  (if (pool? node)
    (each child (node :children)
      (walk-windows child f))
    (f node)))

(defn collect-windows
  "Return a flat array of all window leaves in the tree."
  [node]
  (def result @[])
  (walk-windows node |(array/push result $))
  result)

(defn find-window
  "Find the path (array of indices) from pool to window, or nil."
  [pool window]
  (var result nil)
  (for i 0 (length (pool :children))
    (def child (get (pool :children) i))
    (if (= child window)
      (do (set result @[i]) (break))
      (when (pool? child)
        (when-let [sub-path (find-window child window)]
          (set result (array/concat @[i] sub-path))
          (break)))))
  result)

(defn find-ancestor
  "Walk up :parent pointers from node until pred returns true. Returns the matching ancestor or nil."
  [node pred]
  (var current (node :parent))
  (var result nil)
  (while current
    (when (pred current)
      (set result current)
      (break))
    (set current (current :parent)))
  result)

(defn tag-pool
  "Walk up from node to find the tag-level pool (direct child of the root/output pool).
  The root pool has no :parent. Its direct children are tag pools."
  [node]
  (var prev node)
  (var current (node :parent))
  (while current
    (when (nil? (current :parent))
      # current is root, prev is tag pool
      (break))
    (set prev current)
    (set current (current :parent)))
  (if (and current (nil? (current :parent)) (not= prev node))
    prev
    nil))

(defn find-pool-by-id
  "Find a pool with the given :id in the tree."
  [root id]
  (if (= (root :id) id)
    root
    (when (pool? root)
      (var found nil)
      (each child (root :children)
        (when (pool? child)
          (set found (find-pool-by-id child id))
          (when found (break))))
      found)))

(defn sync-tags
  "Walk the output pool tree, stamp :tag on each window based on tag pool id."
  [output-pool]
  (each child (output-pool :children)
    (def tag-id (child :id))
    (walk-windows child (fn [w] (put w :tag tag-id)))))

(defn auto-unwrap?
  "True if this pool should auto-unwrap when it has one child.
  Only unwrap stack-v with default weights (the implicit wrapper from consume).
  Never unwrap direct children of scroll pools (rows must stay as pools)."
  [pool]
  (and (= (pool :mode) :stack-v)
       (or (nil? (pool :weights)) (empty? (pool :weights)))
       (nil? (pool :ratio))
       (not (and (pool :parent) (= ((pool :parent) :mode) :scroll)))))

(defn maybe-unwrap
  "If pool has one child and passes auto-unwrap?, replace it with the child in the parent."
  [pool]
  (when (and (pool :parent)
             (= (length (pool :children)) 1)
             (auto-unwrap? pool))
    (def parent (pool :parent))
    (def idx (child-index parent pool))
    (unwrap-pool parent idx)))

(defn maybe-prune
  "If pool has zero children, remove it from parent. Recurse up."
  [pool]
  (when (and (pool :parent)
             (= (length (pool :children)) 0))
    (def parent (pool :parent))
    (def idx (child-index parent pool))
    (remove-child parent idx)
    (maybe-prune parent)))
