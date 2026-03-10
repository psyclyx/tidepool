# Pool actions: tree-manipulation operations.

(import ../pool)

# --- Helpers ---

(defn- dir-delta [dir]
  (case dir :right 1 :down 1 :left -1 :up -1 0))

(defn- neighbor-in [parent idx dir]
  "Get the neighbor index in the given direction, or nil if out of bounds."
  (def next-idx (+ idx (dir-delta dir)))
  (when (and (>= next-idx 0) (< next-idx (length (parent :children))))
    next-idx))

(defn- find-scroll-ancestor [node]
  (pool/find-ancestor node |(= ($ :mode) :scroll)))

(def- mode-cycle [:stack-v :stack-h :tabbed :scroll])

# --- consume ---

(defn consume
  "Pull adjacent sibling into focused window's group."
  [root focused dir]
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def grandparent (parent :parent))

  # Case 1: focused is inside a sub-pool (group/tabbed). Look for neighbor
  # of that sub-pool in the grandparent.
  (when (and grandparent (pool/pool? parent))
    (def parent-idx (pool/child-index grandparent parent))
    (when parent-idx
      (def nb-idx (neighbor-in grandparent parent-idx dir))
      (when nb-idx
        (def neighbor (get (grandparent :children) nb-idx))
        (pool/remove-child grandparent nb-idx)
        (if (> (dir-delta dir) 0)
          (pool/append-child parent neighbor)
          (pool/insert-child parent neighbor 0))
        (break))))

  # Case 2: focused is a bare child. Wrap focused + neighbor in a new stack-v.
  (def idx (pool/child-index parent focused))
  (when (nil? idx) (break))
  (def nb-idx (neighbor-in parent idx dir))
  (when (nil? nb-idx) (break))
  (def lo (min idx nb-idx))
  (def hi (+ (max idx nb-idx) 1))
  (pool/wrap-children parent lo hi :stack-v))

# --- expel ---

(defn expel
  "Move focused window out of its current pool into the grandparent."
  [root focused]
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def grandparent (parent :parent))
  (when (nil? grandparent) (break))
  # Don't expel if grandparent has no parent (it's the root),
  # or if grandparent is a scroll pool (preserves row structure)
  (when (nil? (grandparent :parent)) (break))
  (when (= (grandparent :mode) :scroll) (break))
  # Remove focused from parent
  (def idx (pool/child-index parent focused))
  (when (nil? idx) (break))
  (pool/remove-child parent idx)
  # Insert after parent in grandparent
  (def parent-idx (pool/child-index grandparent parent))
  (pool/insert-child grandparent focused (+ parent-idx 1))
  # Auto-unwrap/prune parent if needed
  (if (= (length (parent :children)) 0)
    (pool/maybe-prune parent)
    (pool/maybe-unwrap parent)))

# --- swap ---

(defn swap
  "Move focused window in direction. Exchange with sibling or cross pool boundary."
  [root focused dir]
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def idx (pool/child-index parent focused))
  (when (nil? idx) (break))
  (def n (length (parent :children)))

  (def mode (parent :mode))
  # Determine if this direction is valid for this mode
  (def valid-dir
    (case mode
      :stack-h (or (= dir :left) (= dir :right))
      :stack-v (or (= dir :up) (= dir :down))
      :tabbed (or (= dir :up) (= dir :down))
      :scroll false  # scroll children are rows, not directly swappable
      false))

  (if valid-dir
    (do
      (def next-idx (+ idx (dir-delta dir)))
      (if (and (>= next-idx 0) (< next-idx n))
        (do
          # Simple sibling swap — exchange positions, weights stay
          (def other (get (parent :children) next-idx))
          (put (parent :children) idx other)
          (put (parent :children) next-idx focused)
          # Update :active in tabbed to follow focused
          (when (= mode :tabbed)
            (when (= (parent :active) idx)
              (put parent :active next-idx))))
        # At boundary — try cross-pool swap
        (do
          (def grandparent (parent :parent))
          (when grandparent
            (when (= (grandparent :mode) :scroll)
              # Cross scroll rows
              (def active-row (or (grandparent :active-row) 0))
              (def next-row (+ active-row (dir-delta dir)))
              (when (and (>= next-row 0) (< next-row (length (grandparent :children))))
                (pool/remove-child parent idx)
                (def target-row (get (grandparent :children) next-row))
                (pool/append-child target-row focused)
                (put grandparent :active-row next-row)))))))
    # Direction doesn't match mode — no-op at this level
    nil))

# --- zoom ---

(defn zoom
  "Move focused window to first position in its parent."
  [root focused]
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def idx (pool/child-index parent focused))
  (when (or (nil? idx) (= idx 0)) (break))
  (pool/remove-child parent idx)
  (pool/insert-child parent focused 0))

# --- set-mode ---

(defn set-mode
  "Set pool mode. target is :parent (default) or :tag."
  [root focused mode &opt target]
  (default target :parent)
  (def target-pool
    (if (= target :tag)
      (pool/tag-pool focused)
      (focused :parent)))
  (when (nil? target-pool) (break))

  (if (or (= mode :next) (= mode :prev))
    (do
      (def modes [:stack-v :stack-h :tabbed :scroll])
      (def has-scroll-ancestor (find-scroll-ancestor target-pool))
      (def current (target-pool :mode))
      (var cur-idx nil)
      (for i 0 (length modes)
        (when (= (get modes i) current)
          (set cur-idx i)
          (break)))
      (when (nil? cur-idx) (set cur-idx 0))
      (def step (if (= mode :prev) -1 1))
      (var next-mode nil)
      (var attempts 0)
      (while (< attempts (length modes))
        (set cur-idx (% (+ cur-idx step (length modes)) (length modes)))
        (def candidate (get modes cur-idx))
        (if (and (= candidate :scroll) has-scroll-ancestor)
          (++ attempts)
          (do (set next-mode candidate) (break)))
        (++ attempts))
      (when next-mode
        (put target-pool :mode next-mode)))
    (put target-pool :mode mode)))

# --- resize ---

(defn resize
  "Context-sensitive resize."
  [root focused delta]
  (def parent (focused :parent))
  (when (nil? parent) (break))

  (if (= delta :reset)
    (do
      (when (parent :ratio) (put parent :ratio 0.5))
      (when (parent :weights) (put parent :weights @{})))
    (if (= delta :cycle)
      (do
        # Cycle width presets on scroll column
        (def presets (focused :presets))
        (def width (or (focused :width) 0.5))
        (when (and presets (> (length presets) 0))
          (var next-w (get presets 0))
          (for i 0 (length presets)
            (when (and (< (math/abs (- (get presets i) width)) 0.001)
                       (< (+ i 1) (length presets)))
              (set next-w (get presets (+ i 1)))
              (break)))
          (put focused :width next-w)))
      # Numeric delta
      (do
        # Check if we're in a scroll column (adjust :width)
        (def scroll-anc (find-scroll-ancestor focused))
        (when scroll-anc
          (def width (or (focused :width) 0.5))
          (put focused :width (+ width delta))
          (break))
        # 2-child stack with ratio
        (when (and (parent :ratio) (= (length (parent :children)) 2))
          (put parent :ratio (+ (parent :ratio) delta))
          (break))
        # N-child stack with weights
        (when (and (or (= (parent :mode) :stack-h) (= (parent :mode) :stack-v))
                   (>= (length (parent :children)) 3))
          (def idx (pool/child-index parent focused))
          (unless (parent :weights) (put parent :weights @{}))
          (def cur (or (get (parent :weights) idx) 1.0))
          (put (parent :weights) idx (+ cur delta)))))))

# --- focus-pool ---

(defn focus-pool
  "Activate the child pool with :id on the output (root tabbed)."
  [root id]
  (def children (root :children))
  (for i 0 (length children)
    (when (= (get (get children i) :id) id)
      (put root :active i)
      (break))))

# --- send-to-pool ---

(defn send-to-pool
  "Move focused window to the pool with :id."
  [root focused id]
  (def target (pool/find-pool-by-id root id))
  (when (nil? target) (break))
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def idx (pool/child-index parent focused))
  (when (nil? idx) (break))
  (pool/remove-child parent idx)
  # Clean up source
  (if (= (length (parent :children)) 0)
    (pool/maybe-prune parent)
    (pool/maybe-unwrap parent))
  # Insert into target: if scroll, append to active row; otherwise append to children
  (if (= (target :mode) :scroll)
    (do
      (def active-row (or (target :active-row) 0))
      (def row (get (target :children) active-row))
      (when row (pool/append-child row focused)))
    (pool/append-child target focused)))

# --- toggle-pool ---

(defn toggle-pool
  "Toggle visibility of pool with :id. Sets :multi-active for multi-tag view."
  [root id]
  (def children (root :children))
  (var target-idx nil)
  (for i 0 (length children)
    (when (= (get (get children i) :id) id)
      (set target-idx i)
      (break)))
  (when (nil? target-idx) (break))
  (def current-active (or (root :active) 0))
  (if (= current-active target-idx)
    nil  # can't toggle off the only active
    (do
      # Set multi-active
      (def ma (or (root :multi-active) @{}))
      (if (get ma target-idx)
        (put ma target-idx nil)
        (put ma target-idx true))
      (put root :multi-active ma))))

# --- insert-window ---

(defn insert-window
  "Insert new window after the focused window in the tree."
  [root focused new-win]
  (def parent (focused :parent))
  (when (nil? parent) (break))
  (def idx (pool/child-index parent focused))
  (when (nil? idx) (break))
  (pool/insert-child parent new-win (+ idx 1)))

# --- remove-window ---

(defn remove-window
  "Remove a window from the tree. Auto-unwrap/prune as needed."
  [root window]
  (def parent (window :parent))
  (when (nil? parent) (break))
  (def idx (pool/child-index parent window))
  (when (nil? idx) (break))
  (pool/remove-child parent idx)
  # Clamp :active for tabbed pools
  (when (and (= (parent :mode) :tabbed) (parent :active))
    (def n (length (parent :children)))
    (when (and (> n 0) (>= (parent :active) n))
      (put parent :active (- n 1))))
  # Auto-unwrap or prune
  (if (= (length (parent :children)) 0)
    (pool/maybe-prune parent)
    (pool/maybe-unwrap parent)))

# --- cycle-preset ---

(defn cycle-preset
  "Apply the next layout preset to the focused tag's windows."
  [root focused &opt dir]
  (default dir :next)
  (def tag (pool/tag-pool focused))
  (when (nil? tag) (break))
  (def windows (pool/collect-windows tag))
  (when (= (length windows) 0) (break))
  (def current-mode (tag :mode))

  # Determine next preset: scroll -> master-stack -> monocle -> grid -> scroll
  (def next-mode
    (case current-mode
      :scroll :stack-h      # -> master-stack
      :stack-h :tabbed      # -> monocle
      :tabbed :stack-v      # -> grid (stack-v of stack-h rows)
      :stack-v :scroll      # -> scroll
      :scroll))

  # Rebuild tag children from windows
  # Clear parent pointers from all windows first
  (each w windows (put w :parent nil))

  (case next-mode
    :stack-h
    (do
      # Master-stack: first window is master, rest stacked
      (put tag :mode :stack-h)
      (put tag :ratio 0.55)
      (put tag :children @[])
      (put tag :weights nil)
      (put tag :active nil)
      (put tag :active-row nil)
      (if (<= (length windows) 1)
        (each w windows (pool/append-child tag w))
        (do
          (pool/append-child tag (get windows 0))
          (def stack (pool/make-pool :stack-v (array/slice windows 1)))
          (pool/append-child tag stack))))
    :tabbed
    (do
      # Monocle
      (put tag :mode :tabbed)
      (put tag :ratio nil)
      (put tag :weights nil)
      (put tag :active 0)
      (put tag :active-row nil)
      (put tag :children @[])
      (each w windows (pool/append-child tag w)))
    :stack-v
    (do
      # Grid: stack-v of stack-h rows
      (put tag :mode :stack-v)
      (put tag :ratio nil)
      (put tag :weights nil)
      (put tag :active nil)
      (put tag :active-row nil)
      (put tag :children @[])
      (def n (length windows))
      (def cols (math/ceil (math/sqrt n)))
      (var i 0)
      (while (< i n)
        (def row-end (min n (+ i cols)))
        (def row-wins (array/slice windows i row-end))
        (if (= (length row-wins) 1)
          (pool/append-child tag (get row-wins 0))
          (let [row (pool/make-pool :stack-h row-wins)]
            (pool/append-child tag row)))
        (set i row-end)))
    :scroll
    (do
      # Scroll: each window is a column in a single row
      (put tag :mode :scroll)
      (put tag :ratio nil)
      (put tag :weights nil)
      (put tag :active nil)
      (put tag :active-row 0)
      (put tag :children @[])
      (def row (pool/make-pool :stack-v (array ;windows)))
      (pool/append-child tag row))))

# --- float-toggle ---

(defn float-toggle
  "Toggle floating. Float removes from tree, unfloat inserts back."
  [root focused]
  (if (focused :floating)
    (do
      # Unfloat: insert into the first available pool
      (put focused :floating nil)
      # Find a pool to insert into — use root's active tag
      (def active (or (root :active) 0))
      (def tag (get (root :children) active))
      (when tag
        (if (= (tag :mode) :scroll)
          (let [row (get (tag :children) (or (tag :active-row) 0))]
            (when row (pool/append-child row focused)))
          (pool/append-child tag focused))))
    (do
      # Float: remove from tree
      (def parent (focused :parent))
      (when parent
        (def idx (pool/child-index parent focused))
        (when idx
          (pool/remove-child parent idx)
          (put focused :floating true)
          (if (= (length (parent :children)) 0)
            (pool/maybe-prune parent)
            (pool/maybe-unwrap parent)))))))
