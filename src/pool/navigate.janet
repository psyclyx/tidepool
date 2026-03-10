# Pool navigation: structural directional navigation through the pool tree.
# Uses :parent back-pointers to bubble up at boundaries and descend into neighbors.

(import ../pool)

(defn- first-leaf
  "Find the first (topmost/leftmost) window leaf in a subtree."
  [node]
  (if (pool/window? node)
    node
    (when (and (node :children) (> (length (node :children)) 0))
      (case (node :mode)
        :tabbed (let [active (or (node :active) 0)]
                  (first-leaf (get (node :children) active)))
        (first-leaf (get (node :children) 0))))))

(defn- enter-pool
  "Enter a pool from outside, picking the appropriate child.
  For tabbed: pick active. For others: pick first child."
  [node]
  (if (pool/window? node)
    node
    (first-leaf node)))

(defn- find-child-containing
  "Find the index of the child that is or contains the focused window."
  [pool focused]
  (def children (pool :children))
  (var result nil)
  (for i 0 (length children)
    (def child (get children i))
    (when (or (= child focused)
              (and (pool/pool? child) (pool/find-window child focused)))
      (set result i)
      (break)))
  result)

(defn- navigate-within
  "Try to navigate within a pool given the original focused window.
  Returns target window, :bubble (try parent), or nil."
  [pool focused dir]
  (def children (pool :children))
  (def n (length children))

  (case (pool :mode)
    :tabbed
    (if (or (= dir :left) (= dir :right))
      :bubble
      (if (<= n 1)
        nil
        (let [active (or (pool :active) 0)
              next-idx (cond
                         (= dir :down) (% (+ active 1) n)
                         (= dir :up) (% (+ active (- n 1)) n)
                         nil)]
          (when next-idx
            (put pool :active next-idx)
            (enter-pool (get children next-idx))))))

    :scroll
    (do
      (def active-row (or (pool :active-row) 0))
      (def row (get children active-row))
      (if (or (= dir :left) (= dir :right))
        # Find the focused window's column in the active row
        (let [col-idx (find-child-containing row focused)]
          (if (nil? col-idx)
            :bubble
            (let [next-idx (if (= dir :right) (+ col-idx 1) (- col-idx 1))
                  row-n (length (row :children))]
              (if (or (< next-idx 0) (>= next-idx row-n))
                nil
                (enter-pool (get (row :children) next-idx))))))
        # up/down: cross rows
        (let [next-row (if (= dir :down) (+ active-row 1) (- active-row 1))]
          (if (or (< next-row 0) (>= next-row n))
            nil
            (do
              (put pool :active-row next-row)
              (enter-pool (get children next-row)))))))

    # stack-h / stack-v
    (do
      (def [neg pos] (case (pool :mode)
                       :stack-h [:left :right]
                       :stack-v [:up :down]
                       [:left :right]))
      (if (and (not= dir neg) (not= dir pos))
        :bubble
        (let [child-idx (find-child-containing pool focused)]
          (if (nil? child-idx)
            :bubble
            (let [next-idx (if (= dir pos) (+ child-idx 1) (- child-idx 1))]
              (if (or (< next-idx 0) (>= next-idx n))
                :bubble
                (enter-pool (get children next-idx))))))))))

(defn navigate
  "Navigate from focused window in direction. Returns target window or nil."
  [root focused dir]
  # Walk up from focused, trying each ancestor pool
  (var current focused)
  (var result nil)
  (while true
    (def parent (current :parent))
    (when (nil? parent) (break))
    (def nav-result (navigate-within parent focused dir))
    (cond
      (= nav-result :bubble)
      (set current parent)

      (nil? nav-result)
      # nil means the pool handled it but there's no target (edge).
      # Keep bubbling — a higher pool might handle it.
      (set current parent)

      # Got a window result
      (do (set result nav-result) (break))))
  result)
