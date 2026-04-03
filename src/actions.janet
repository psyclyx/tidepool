# Public action API. All keybindings reference this module.
# Re-exports scroll-actions, adds cross-output navigation and tag actions.

(import ./scroll-actions)
(import ./output)
(import ./seat)
(import ./tree)
(import ./state)

# --- Cross-output helpers ---

(defn- find-adjacent-output
  "Find the output adjacent to `o` in `direction` based on physical position.
   Filters for perpendicular-axis overlap, picks closest edge."
  [ctx o direction]
  (def ox (or (o :x) 0))
  (def oy (or (o :y) 0))
  (def ow (or (o :w) 0))
  (def oh (or (o :h) 0))
  (var best nil)
  (var best-dist math/inf)
  (each c (ctx :outputs)
    (when (and (not= c o) (not (c :removed)))
      (def cx (or (c :x) 0))
      (def cy (or (c :y) 0))
      (def cw (or (c :w) 0))
      (def ch (or (c :h) 0))
      (case direction
        :left
        (when (and (<= (+ cx cw) ox)
                   (< cy (+ oy oh)) (< oy (+ cy ch)))
          (def dist (- ox (+ cx cw)))
          (when (< dist best-dist) (set best-dist dist) (set best c)))
        :right
        (when (and (>= cx (+ ox ow))
                   (< cy (+ oy oh)) (< oy (+ cy ch)))
          (def dist (- cx (+ ox ow)))
          (when (< dist best-dist) (set best-dist dist) (set best c)))
        :up
        (when (and (<= (+ cy ch) oy)
                   (< cx (+ ox ow)) (< ox (+ cx cw)))
          (def dist (- oy (+ cy ch)))
          (when (< dist best-dist) (set best-dist dist) (set best c)))
        :down
        (when (and (>= cy (+ oy oh))
                   (< cx (+ ox ow)) (< ox (+ cx cw)))
          (def dist (- cy (+ oy oh)))
          (when (< dist best-dist) (set best-dist dist) (set best c))))))
  best)

(defn- entry-leaf
  "Get the leaf to focus when entering a tag from a given direction.
   We want the leaf closest to where we came from."
  [tag direction]
  (def columns (tag :columns))
  (when (and columns (not (empty? columns)))
    (case direction
      :left (tree/last-leaf (last columns))
      :right (tree/first-leaf (first columns))
      :up (tree/last-leaf (last columns))
      :down (tree/first-leaf (first columns)))))

(defn- cross-output-focus
  "Focus a window on an adjacent output, or just focus an empty output."
  [ctx s direction]
  (when-let [current (s :focused-output)
             adj (find-adjacent-output ctx current direction)]
    (seat/focus-output s adj)
    (when-let [tag-id (adj :primary-tag)
               tag (get-in ctx [:tags tag-id])]
      (when-let [target (entry-leaf tag direction)]
        (put tag :focused-id (target :window))
        (tree/update-active-path target)))))

# --- Directional focus (with cross-output fallback) ---

(defn focus-left [ctx s]
  (or (scroll-actions/focus-left ctx s)
      (cross-output-focus ctx s :left)))

(defn focus-right [ctx s]
  (or (scroll-actions/focus-right ctx s)
      (cross-output-focus ctx s :right)))

(defn focus-up [ctx s]
  (or (scroll-actions/focus-up ctx s)
      (cross-output-focus ctx s :up)))

(defn focus-down [ctx s]
  (or (scroll-actions/focus-down ctx s)
      (cross-output-focus ctx s :down)))

# --- Directional swap ---
(def swap-left scroll-actions/swap-left)
(def swap-right scroll-actions/swap-right)
(def swap-up scroll-actions/swap-up)
(def swap-down scroll-actions/swap-down)

# --- Join / Leave ---
(def join-left scroll-actions/join-left)
(def join-right scroll-actions/join-right)
(def join-up scroll-actions/join-up)
(def join-down scroll-actions/join-down)
(def leave scroll-actions/leave)

# --- Tabs ---
(def focus-tab-next scroll-actions/focus-tab-next)
(def focus-tab-prev scroll-actions/focus-tab-prev)
(def make-tabbed scroll-actions/make-tabbed)
(def make-split scroll-actions/make-split)
(def make-horizontal scroll-actions/make-horizontal)
(def make-vertical scroll-actions/make-vertical)

# --- Width ---
(def grow scroll-actions/grow)

# --- Insert mode ---
(def toggle-insert-mode scroll-actions/toggle-insert-mode)

# --- Close ---
(def close-focused scroll-actions/close-focused)

# --- Spawn ---
(def spawn scroll-actions/spawn)

# --- Output focus cycling ---

(defn focus-output-next [ctx s]
  (when-let [o (s :focused-output)]
    (def outputs (filter |(not ($ :removed)) (ctx :outputs)))
    (when (> (length outputs) 1)
      (def idx (find-index |(= $ o) outputs))
      (when idx
        (seat/focus-output s (outputs (% (+ idx 1) (length outputs))))))))

(defn focus-output-prev [ctx s]
  (when-let [o (s :focused-output)]
    (def outputs (filter |(not ($ :removed)) (ctx :outputs)))
    (when (> (length outputs) 1)
      (def idx (find-index |(= $ o) outputs))
      (when idx
        (seat/focus-output s (outputs (% (+ idx (- (length outputs) 1)) (length outputs))))))))

# --- Tag management ---

(defn focus-tag
  "Return an action that switches the focused output to a tag.
   If another output already shows that tag, focus moves there instead."
  [tag]
  (fn [ctx s]
    (when-let [o (s :focused-output)]
      (def other (find |(and (not= $ o) (($ :tags) tag))
                       (ctx :outputs)))
      (if other
        (seat/focus-output s other)
        (output/set-tags o {tag true})))))

(defn send-to-tag
  "Return an action that moves the focused window to a tag."
  [tag]
  (fn [ctx s]
    (when-let [w (s :focused)
               leaf (w :tree-leaf)]
      (def old-tag-id (w :tag))
      (when (= old-tag-id tag) (break))
      (def old-tag (get-in ctx [:tags old-tag-id]))
      # Remove from old tag's tree
      (when old-tag
        (def columns (old-tag :columns))
        (def col-idx (tree/find-column-index columns leaf))
        (def child-idx (or (tree/child-index leaf) 0))
        (def [col-removed result] (tree/remove-leaf columns leaf))
        # Update old tag's focus
        (when (= (old-tag :focused-id) w)
          (def successor (tree/focus-successor columns
                           (or col-idx 0) child-idx
                           (if col-removed nil result)))
          (if successor
            (do (put old-tag :focused-id (successor :window))
                (tree/update-active-path successor))
            (put old-tag :focused-id nil))))
      # Move window to new tag
      (put w :tag tag)
      # Insert into new tag's tree
      (def new-tag (state/ensure-tag ctx tag))
      (tree/insert-column (new-tag :columns) (length (new-tag :columns)) leaf)
      (put new-tag :focused-id w)
      (tree/update-active-path leaf)
      # Clear position so layout recomputes
      (put w :x nil)
      (put w :y nil))))
