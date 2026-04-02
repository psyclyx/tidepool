(import ./helper :as t)
(import tree)
(import scroll-actions :as sa)

# --- Test helpers ---

(defn make-tag [columns &opt focused-window]
  @{:columns columns
    :camera 0
    :focused-id focused-window
    :insert-mode :sibling})

(defn make-scroll-ctx [tag &opt config-overrides]
  (def config (t/make-config))
  (put config :default-column-width 1.0)
  (put config :width-presets @[0.33 0.5 0.66 0.8 1.0])
  (put config :peek-width 8)
  (when config-overrides (merge-into config config-overrides))
  @{:config config
    :tags @{1 tag}
    :outputs @[]
    :windows @[]
    :seats @[]})

(defn make-scroll-seat [&opt focused-window]
  @{:focused focused-window
    :focused-output @{:primary-tag 1 :tags @{1 true}}
    :pending-actions @[]})

(defn make-cols [& leaves]
  "Build a columns array with properly wrapped leaves."
  (def cols @[])
  (each l leaves
    (tree/insert-column cols (length cols) l))
  cols)

# ============================================================
# Directional focus
# ============================================================

(t/test-start "find-directional-neighbor: left across columns")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def cols (make-cols la lb))
(t/assert-is (sa/find-directional-neighbor cols lb :left) la)

(t/test-start "find-directional-neighbor: right across columns")
(t/assert-is (sa/find-directional-neighbor cols la :right) lb)

(t/test-start "find-directional-neighbor: left at start = nil")
(t/assert-eq (sa/find-directional-neighbor cols la :left) nil)

(t/test-start "find-directional-neighbor: right at end = nil")
(t/assert-eq (sa/find-directional-neighbor cols lb :right) nil)

(t/test-start "find-directional-neighbor: down in vertical split")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def c (tree/container :split :vertical @[la lb]))
(def cols @[c])
(t/assert-is (sa/find-directional-neighbor cols la :down) lb)

(t/test-start "find-directional-neighbor: up in vertical split")
(t/assert-is (sa/find-directional-neighbor cols lb :up) la)

(t/test-start "find-directional-neighbor: down at bottom = nil")
(t/assert-eq (sa/find-directional-neighbor cols lb :down) nil)

(t/test-start "find-directional-neighbor: up at top = nil")
(t/assert-eq (sa/find-directional-neighbor cols la :up) nil)

(t/test-start "find-directional-neighbor: left from nested vsplit exits to prev column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(def vsplit (tree/container :split :vertical @[lb lc]))
(def cols @[])
(tree/insert-column cols 0 la)
(array/push cols vsplit)
(t/assert-is (sa/find-directional-neighbor cols lb :left) la)
(t/assert-is (sa/find-directional-neighbor cols lc :left) la)

(t/test-start "find-directional-neighbor: right into vsplit enters first leaf")
(t/assert-is (sa/find-directional-neighbor cols la :right) lb)

(t/test-start "find-directional-neighbor: horizontal within vertical column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(def hsplit (tree/container :split :horizontal @[lb lc]))
(def vsplit (tree/container :split :vertical @[la hsplit]))
(def cols @[vsplit])
(t/assert-is (sa/find-directional-neighbor cols lb :right) lc)
(t/assert-is (sa/find-directional-neighbor cols lc :left) lb)
(t/assert-is (sa/find-directional-neighbor cols la :down) lb "down enters hsplit first-leaf")

# ============================================================
# Focus actions with ctx/seat
# ============================================================

(t/test-start "focus-right: updates tag focus")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def cols (make-cols la lb))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/focus-right ctx seat)
(t/assert-is (tag :focused-id) wb)

(t/test-start "focus-left: updates tag focus")
(sa/focus-left ctx seat)
(t/assert-is (tag :focused-id) wa)

(t/test-start "focus-right: no-op at end")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa))
(def tag (make-tag (make-cols la) wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/focus-right ctx seat)
(t/assert-is (tag :focused-id) wa "unchanged")

# ============================================================
# Swap
# ============================================================

(t/test-start "swap-right: structural swap, focus follows")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def cols (make-cols la lb))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-right ctx seat)
# Nodes swapped positions: la (with wa) is now in column 1, lb (with wb) in column 0
(t/assert-is (la :window) wa "la keeps its window")
(t/assert-is (lb :window) wb "lb keeps its window")
(t/assert-is (tree/first-leaf (cols 0)) lb "lb now first")
(t/assert-is (tree/first-leaf (cols 1)) la "la now second")
(t/assert-is (tag :focused-id) wa "focus followed")

(t/test-start "swap-down: structural swap in vertical split")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def c (tree/container :split :vertical @[la lb]))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-down ctx seat)
(t/assert-is ((c :children) 0) lb "lb now first child")
(t/assert-is ((c :children) 1) la "la now second child")

(t/test-start "swap-right: with container swaps subtrees, not contents")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(def vsplit (tree/container :split :vertical @[lb lc]))
(def cols @[])
(tree/insert-column cols 0 la)
(array/push cols vsplit)
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-right ctx seat)
# la's column wrapper swapped with vsplit — la is now column 1, vsplit is column 0
(t/assert-is (cols 0) vsplit "vsplit now first")
(t/assert-is (tree/first-leaf (cols 1)) la "la now second")
(t/assert-is (la :window) wa "la still holds wa")
(t/assert-eq (length (vsplit :children)) 2 "vsplit unchanged")

(t/test-start "swap-down at edge: extracts leaf from vertical container")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def vsplit (tree/container :split :vertical @[la lb]))
(def cols @[vsplit])
(def tag (make-tag cols wb))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wb))
(sa/swap-down ctx seat)
# lb was at bottom of vsplit, should extract to a new column after vsplit
(t/assert-eq (length cols) 2 "now two columns")
(t/assert-is (tree/first-leaf (cols 0)) la "la stays in original column")
(t/assert-is (tree/first-leaf (cols 1)) lb "lb extracted to new column")

(t/test-start "swap-up at edge: extracts leaf from vertical container")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def vsplit (tree/container :split :vertical @[la lb]))
(def cols @[vsplit])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-up ctx seat)
# la was at top of vsplit, should extract to a new column before vsplit
(t/assert-eq (length cols) 2 "now two columns")
(t/assert-is (tree/first-leaf (cols 0)) la "la extracted before")
(t/assert-is (tree/first-leaf (cols 1)) lb "lb stays in original column")

# ============================================================
# Join
# ============================================================

(t/test-start "join-right: two columns become vertical split")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def cols (make-cols la lb))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/join-right ctx seat)
# la should have been removed from its column, joined into lb's column
(t/assert-eq (length cols) 1 "one column left")
(def col (cols 0))
(t/assert-truthy (tree/container? col) "column is a container")
# Both windows should be in the remaining column
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 2 "both leaves in column")
# The join creates a vertical split inside the column
(t/assert-is ((tree/first-leaf ((col :children) 0)) :window) wb)

(t/test-start "join-left: joins into left neighbor")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def cols (make-cols la lb))
(def tag (make-tag cols wb))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wb))
(sa/join-left ctx seat)
(t/assert-eq (length cols) 1)
(def col (cols 0))
(t/assert-truthy (tree/container? col))
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 2)

(t/test-start "join-down: into existing vertical split")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(def c (tree/container :split :vertical @[la lb]))
(def cols @[c])
(tree/insert-column cols 1 lc)
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/join-down ctx seat)
(t/assert-eq (length cols) 2 "still two columns")
(def col (cols 0))
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 2 "both windows in first column")

(t/test-start "join: no-op when no neighbor")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa))
(def cols (make-cols la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/join-right ctx seat)
(t/assert-eq (length cols) 1 "unchanged")

# ============================================================
# Leave
# ============================================================

(t/test-start "leave: extracts from container to new column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def c (tree/container :split :vertical @[la lb] 0.8))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/leave ctx seat)
(t/assert-eq (length cols) 2 "new column created")
# First col still has lb (root container preserved with single child)
(t/assert-is (tree/first-leaf (cols 0)) lb "lb remains in first column")
# Second col is la in a new wrapper
(t/assert-is (tree/first-leaf (cols 1)) la "la extracted to new column")
(t/assert-eq (la :width) 1.0 "default width")
(t/assert-is (tag :focused-id) wa "focus followed")

(t/test-start "leave: no-op if already top-level")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa))
(def cols (make-cols la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/leave ctx seat)
(t/assert-eq (length cols) 1 "unchanged")

# ============================================================
# Width cycling
# ============================================================

(t/test-start "cycle-width-forward: from 0.5 to 0.66")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa 0.5))
(def cols (make-cols la))
(def col (tree/column-of la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/cycle-width-forward ctx seat)
(t/assert-eq (col :width) 0.66)

(t/test-start "cycle-width-backward: from 0.5 to 0.33")
(put col :width 0.5)
(sa/cycle-width-backward ctx seat)
(t/assert-eq (col :width) 0.33)

(t/test-start "cycle-width-forward: clamped at max")
(put col :width 1.0)
(sa/cycle-width-forward ctx seat)
(t/assert-eq (col :width) 1.0 "stays at max")

(t/test-start "cycle-width-backward: clamped at min")
(put col :width 0.33)
(sa/cycle-width-backward ctx seat)
(t/assert-eq (col :width) 0.33 "stays at min")

(t/test-start "cycle-width: works on nested leaf's column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def c (tree/container :split :vertical @[la lb] 0.5))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/cycle-width-forward ctx seat)
(t/assert-eq (c :width) 0.66 "column width changed, not leaf")

# ============================================================
# Insert mode
# ============================================================

(t/test-start "toggle-insert-mode")
(tree/reset-ids)
(def tag (make-tag @[] nil))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat nil))
(t/assert-eq (tag :insert-mode) :sibling "default")
(sa/toggle-insert-mode ctx seat)
(t/assert-eq (tag :insert-mode) :child)
(sa/toggle-insert-mode ctx seat)
(t/assert-eq (tag :insert-mode) :sibling)

# ============================================================
# Container mode conversion
# ============================================================

(t/test-start "make-tabbed: converts parent container")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def c (tree/container :split :vertical @[la lb]))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/make-tabbed ctx seat)
(t/assert-eq (c :mode) :tabbed)

(t/test-start "make-split: converts back")
(sa/make-split ctx seat)
(t/assert-eq (c :mode) :split)

(t/test-start "make-horizontal: sets orientation")
(sa/make-horizontal ctx seat)
(t/assert-eq (c :orientation) :horizontal)

(t/test-start "make-vertical: sets orientation back")
(sa/make-vertical ctx seat)
(t/assert-eq (c :orientation) :vertical)

# ============================================================
# Tab cycling
# ============================================================

(t/test-start "focus-tab-next: cycles active tab")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def tb (tree/container :tabbed :horizontal @[la lb]))
(def cols @[tb])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/focus-tab-next ctx seat)
(t/assert-eq (tb :active) 1)
(t/assert-is (tag :focused-id) wb)

(t/test-start "focus-tab-prev: cycles back")
(sa/focus-tab-prev ctx seat)
(t/assert-eq (tb :active) 0)
(t/assert-is (tag :focused-id) wa)

(t/test-start "focus-tab-next: no-op at end")
(put tb :active 1)
(put tag :focused-id wb)
(sa/focus-tab-next ctx seat)
(t/assert-eq (tb :active) 1 "stays at end")

(t/test-start "focus-tab-prev: no-op at start")
(put tb :active 0)
(put tag :focused-id wa)
(sa/focus-tab-prev ctx seat)
(t/assert-eq (tb :active) 0 "stays at start")

(t/report)
