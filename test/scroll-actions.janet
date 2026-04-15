(import ./helper :as t)
(import tree)
(import scroll-actions :as sa)

# --- Test helpers ---

(defn make-tag [columns &opt focused-window]
  @{:columns columns
    :camera 0
    :focused-id focused-window})

(defn make-scroll-ctx [tag &opt config-overrides]
  (def config (t/make-config))
  (put config :default-column-width 1.0)
  (put config :width-presets @[0.5 0.66 0.8 1.0])
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
# Inner split at depth 1 = vertical orientation
(def inner (tree/container :split @[la lb]))
(def col (tree/container :split @[inner]))
(def cols @[col])
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
# Inner split at depth 1 = vertical, so lb/lc are stacked vertically
(def vsplit (tree/container :split @[lb lc]))
(def col2 (tree/container :split @[vsplit]))
(def cols @[])
(tree/insert-column cols 0 la)
(array/push cols col2)
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
# hsplit at depth 2 = horizontal, vsplit at depth 1 = vertical, col at depth 0
(def hsplit (tree/container :split @[lb lc]))
(def vsplit (tree/container :split @[la hsplit]))
(def col (tree/container :split @[vsplit]))
(def cols @[col])
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
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
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
(put wa :tree-leaf la)
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
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
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
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
# Inner split at depth 1 = vertical
(def c (tree/container :split @[la lb]))
(def col (tree/container :split @[c]))
(def cols @[col])
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
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(put wc :tree-leaf lc)
# vsplit at depth 1 = vertical, inside col2 at depth 0
(def vsplit (tree/container :split @[lb lc]))
(def col2 (tree/container :split @[vsplit]))
(def cols @[])
(tree/insert-column cols 0 la)
(array/push cols col2)
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-right ctx seat)
# la's column wrapper swapped with col2
(t/assert-is (cols 0) col2 "col2 now first")
(t/assert-is (tree/first-leaf (cols 1)) la "la now second")
(t/assert-is (la :window) wa "la still holds wa")
(t/assert-eq (length (vsplit :children)) 2 "vsplit unchanged")

(t/test-start "swap-down at edge: extracts leaf from vertical container")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
# Inner split at depth 1 = vertical
(def vsplit (tree/container :split @[la lb]))
(def col (tree/container :split @[vsplit]))
(def cols @[col])
(def tag (make-tag cols wb))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wb))
(sa/swap-down ctx seat)
# lb was at bottom of vsplit, extracts as sibling of vsplit inside col
(t/assert-eq (length cols) 1 "still one column")
(t/assert-eq (length (col :children)) 2 "col has 2 children now")

(t/test-start "swap-up at edge: extracts leaf within column wrapper")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
# Inner split at depth 1 = vertical, inside col at depth 0
(def vsplit (tree/container :split @[la lb]))
(def col (tree/container :split @[vsplit]))
(def cols @[col])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/swap-up ctx seat)
# la was at top of vsplit, extracts as sibling of vsplit inside col
(t/assert-eq (length cols) 1 "still one column")
(t/assert-eq (length (col :children)) 2 "col has 2 children now")

# ============================================================
# Absorb (pull neighbor into focused window's group)
# ============================================================

(t/test-start "absorb-right: pulls right neighbor into focused column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def cols (make-cols la lb))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/absorb-right ctx seat)
# wb should have been pulled into wa's column
(t/assert-eq (length cols) 1 "one column left")
(def col (cols 0))
(t/assert-truthy (tree/container? col) "column is a container")
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 2 "both leaves in column")
# Focus stays on wa
(t/assert-is (tag :focused-id) wa "focus stays on absorber")

(t/test-start "absorb-left: pulls left neighbor into focused column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def cols (make-cols la lb))
(def tag (make-tag cols wb))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wb))
(sa/absorb-left ctx seat)
(t/assert-eq (length cols) 1)
(def col (cols 0))
(t/assert-truthy (tree/container? col))
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 2)
(t/assert-is (tag :focused-id) wb "focus stays on absorber")

(t/test-start "absorb-right: pulls neighbor into existing multi-child container")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(put wc :tree-leaf lc)
# inner at depth 1 = vertical, la above lb
(def inner (tree/container :split @[la lb]))
(def col1 (tree/container :split @[inner]))
(def cols @[col1])
(tree/insert-column cols 1 lc)
(def tag (make-tag cols lb))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat lb))
# lb in vertical split, absorb-right pulls from next column
(sa/absorb-right ctx seat)
# lc should have been pulled into inner alongside lb
(def col (cols 0))
(def col-leaves (tree/all-leaves col))
(t/assert-eq (length col-leaves) 3 "all three leaves in first column")

(t/test-start "absorb: no-op when no neighbor")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa))
(put wa :tree-leaf la)
(def cols (make-cols la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/absorb-right ctx seat)
(t/assert-eq (length cols) 1 "unchanged")

# ============================================================
# Eject (push focused window out of its group)
# ============================================================

(t/test-start "eject: extracts from container to new column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def c (tree/container :split @[la lb] 0.8))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/eject ctx seat)
(t/assert-eq (length cols) 2 "new column created")
# First col still has lb (root container preserved with single child)
(t/assert-is (tree/first-leaf (cols 0)) lb "lb remains in first column")
# Second col is la in a new wrapper
(t/assert-is (tree/first-leaf (cols 1)) la "la extracted to new column")
(t/assert-is (tag :focused-id) wa "focus followed")

(t/test-start "eject: no-op if already top-level")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa))
(put wa :tree-leaf la)
(def cols (make-cols la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/eject ctx seat)
(t/assert-eq (length cols) 1 "unchanged")

# ============================================================
# Width cycling
# ============================================================

(t/test-start "grow: from 0.5 to 0.66")
(tree/reset-ids)
(def wa @{:wid 1})
(def la (tree/leaf wa 0.5))
(put wa :tree-leaf la)
(def cols (make-cols la))
(def col (tree/column-of la))
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/grow ctx seat)
(t/assert-eq (col :width) 0.66)

(t/test-start "grow: wraps from max to min")
(put col :width 1.0)
(sa/grow ctx seat)
(t/assert-eq (col :width) 0.5 "wraps to first preset")

(t/test-start "grow: works on nested leaf's column")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def c (tree/container :split @[la lb] 0.5))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/grow ctx seat)
(t/assert-eq (c :width) 0.66 "column width changed, not leaf")

# ============================================================
# Container mode toggle
# ============================================================

(t/test-start "toggle-split-tabbed: converts split to tabbed")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def c (tree/container :split @[la lb]))
(def cols @[c])
(def tag (make-tag cols wa))
(def ctx (make-scroll-ctx tag))
(def seat (make-scroll-seat wa))
(sa/toggle-split-tabbed ctx seat)
(t/assert-eq (c :mode) :tabbed)

(t/test-start "toggle-split-tabbed: converts tabbed back to split")
(sa/toggle-split-tabbed ctx seat)
(t/assert-eq (c :mode) :split)

# ============================================================
# Tab cycling
# ============================================================

(t/test-start "focus-tab-next: cycles active tab")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(put wa :tree-leaf la)
(put wb :tree-leaf lb)
(def tb (tree/container :tabbed @[la lb]))
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
