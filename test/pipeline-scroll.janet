(import ./helper :as t)
(import tree)
(import scroll)
(import state)

# ============================================================
# state/ensure-tag
# ============================================================

(t/test-start "ensure-tag: creates new tag")
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(t/assert-truthy tag "returns tag")
(t/assert-eq (length (tag :columns)) 0)
(t/assert-eq (tag :camera) 0)
(t/assert-eq (tag :focused-id) nil)
(t/assert-eq (tag :insert-mode) :sibling)

(t/test-start "ensure-tag: returns existing tag")
(def tag2 (state/ensure-tag ctx 1))
(t/assert-is tag2 tag "same reference")

(t/test-start "ensure-tag: different ids are independent")
(def tag3 (state/ensure-tag ctx 2))
(t/assert-truthy (not= tag tag3))

# ============================================================
# Tree insertion (simulating init-new-windows logic)
# ============================================================

(t/test-start "new window in sibling mode: creates column")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(def w1 @{:wid 1 :tag 1})
(def leaf1 (tree/leaf w1 1.0))
(put w1 :tree-leaf leaf1)
(tree/insert-column (tag :columns) 0 leaf1)
(put tag :focused-id w1)
(tree/update-active-path leaf1)
(t/assert-eq (length (tag :columns)) 1)
(t/assert-is ((tag :columns) 0) leaf1)

# Add second window in sibling mode
(def w2 @{:wid 2 :tag 1})
(def leaf2 (tree/leaf w2 1.0))
(put w2 :tree-leaf leaf2)
# In sibling mode, insert after focused column
(def focus-col-idx (tree/find-column-index (tag :columns) leaf1))
(tree/insert-column (tag :columns) (inc focus-col-idx) leaf2)
(put tag :focused-id w2)
(tree/update-active-path leaf2)
(t/assert-eq (length (tag :columns)) 2)
(t/assert-is ((tag :columns) 1) leaf2)

(t/test-start "new window in child mode: wraps into container")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(put tag :insert-mode :child)
(def w1 @{:wid 1 :tag 1})
(def leaf1 (tree/leaf w1 1.0))
(put w1 :tree-leaf leaf1)
(tree/insert-column (tag :columns) 0 leaf1)
(put tag :focused-id w1)
(tree/update-active-path leaf1)

# Add w2 in child mode — focused is a bare column, wraps into vsplit
(def w2 @{:wid 2 :tag 1})
(def leaf2 (tree/leaf w2 1.0))
(put w2 :tree-leaf leaf2)
(tree/wrap-in-container (tag :columns) leaf1 :split :vertical leaf2 :after)
(put tag :focused-id w2)
(tree/update-active-path leaf2)
(t/assert-eq (length (tag :columns)) 1 "still one column")
(def col ((tag :columns) 0))
(t/assert-truthy (tree/container? col) "column is a container")
(t/assert-eq (length (col :children)) 2)

# ============================================================
# Window removal from tree
# ============================================================

(t/test-start "remove-closed-from-tree: removes and updates focus")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(def w1 @{:wid 1 :tag 1 :closed false})
(def w2 @{:wid 2 :tag 1 :closed false})
(def leaf1 (tree/leaf w1 1.0))
(def leaf2 (tree/leaf w2 1.0))
(put w1 :tree-leaf leaf1)
(put w2 :tree-leaf leaf2)
(tree/insert-column (tag :columns) 0 leaf1)
(tree/insert-column (tag :columns) 1 leaf2)
(put tag :focused-id w1)

# Close w1
(put w1 :closed true)
(def columns (tag :columns))
(def leaf (w1 :tree-leaf))
(def col-idx (tree/find-column-index columns leaf))
(def child-idx (or (tree/child-index leaf) 0))
(def [col-removed result] (tree/remove-leaf columns leaf))
(def successor (tree/focus-successor columns
                 (or col-idx 0) child-idx
                 (if col-removed nil result)))
(when successor
  (put tag :focused-id (successor :window))
  (tree/update-active-path successor))
(put w1 :tree-leaf nil)

(t/assert-eq (length (tag :columns)) 1 "one column left")
(t/assert-is (tag :focused-id) w2 "focus moved to w2")

(t/test-start "remove last window: focus becomes nil")
(put w2 :closed true)
(def leaf2b (w2 :tree-leaf))
(def columns (tag :columns))
(def col-idx (tree/find-column-index columns leaf2b))
(def child-idx (or (tree/child-index leaf2b) 0))
(def [col-removed result] (tree/remove-leaf columns leaf2b))
(def successor (tree/focus-successor columns
                 (or col-idx 0) child-idx
                 (if col-removed nil result)))
(if successor
  (put tag :focused-id (successor :window))
  (put tag :focused-id nil))

(t/assert-eq (length (tag :columns)) 0)
(t/assert-eq (tag :focused-id) nil)

# ============================================================
# Scroll layout integration
# ============================================================

(t/test-start "scroll-layout through tag state: basic")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(def w1 @{:wid 1 :tag 1})
(def leaf1 (tree/leaf w1 1.0))
(put w1 :tree-leaf leaf1)
(tree/insert-column (tag :columns) 0 leaf1)
(put tag :focused-id w1)
(tree/update-active-path leaf1)

(def config (ctx :config))
(def scroll-config @{:peek-width (config :peek-width)
                      :border-width (config :border-width)
                      :inner-gap (config :inner-gap)
                      :outer-gap (config :outer-gap)})
(def output {:x 0 :y 0 :w 1920 :h 1080})
(def usable {:x 0 :y 0 :w 1920 :h 1080})

(def result (scroll/scroll-layout (tag :columns) leaf1
                                   (tag :camera) output usable scroll-config))
(t/assert-eq (result :camera) 0)
(t/assert-eq (length (result :placements)) 1)
(def p (first (result :placements)))
(t/assert-is (p :window) w1)
(t/assert-eq (p :clip) nil "single window, no clipping")

(t/test-start "scroll-layout: three columns, middle focused")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(def windows (seq [i :range [0 3]] @{:wid i :tag 1}))
(def leaves (seq [i :range [0 3]]
  (def l (tree/leaf (windows i) 1.0))
  (put (windows i) :tree-leaf l)
  (tree/insert-column (tag :columns) i l)
  l))
(put tag :focused-id (windows 1))
(tree/update-active-path (leaves 1))

(def config (ctx :config))
(def scroll-config @{:peek-width (config :peek-width)
                      :border-width (config :border-width)
                      :inner-gap (config :inner-gap)
                      :outer-gap (config :outer-gap)})
(def output {:x 0 :y 0 :w 1920 :h 1080})
(def usable {:x 0 :y 0 :w 1920 :h 1080})

(def result (scroll/scroll-layout (tag :columns) (leaves 1)
                                   (tag :camera) output usable scroll-config))
(put tag :camera (result :camera))
(t/assert-truthy (> (result :camera) 0) "scrolled to show middle")
# Should have placements for visible windows
(t/assert-truthy (>= (length (result :placements)) 2) "at least 2 visible")
# Middle window should be fully visible (no clip)
(def mid-placement (find |(= ($ :window) (windows 1)) (result :placements)))
(t/assert-truthy mid-placement "middle window placed")
(t/assert-eq (mid-placement :clip) nil "middle not clipped")

(t/test-start "scroll-layout: vertical split column")
(tree/reset-ids)
(def ctx (t/make-ctx))
(def tag (state/ensure-tag ctx 1))
(def w1 @{:wid 1 :tag 1})
(def w2 @{:wid 2 :tag 1})
(def l1 (tree/leaf w1))
(def l2 (tree/leaf w2))
(def col (tree/container :split :vertical @[l1 l2] 1.0))
(tree/insert-column (tag :columns) 0 col)
(put tag :focused-id w1)
(tree/update-active-path l1)

(def config (ctx :config))
(def scroll-config @{:peek-width (config :peek-width)
                      :border-width (config :border-width)
                      :inner-gap (config :inner-gap)
                      :outer-gap (config :outer-gap)})
(def output {:x 0 :y 0 :w 1920 :h 1080})
(def usable {:x 0 :y 0 :w 1920 :h 1080})

(def result (scroll/scroll-layout (tag :columns) l1
                                   0 output usable scroll-config))
(t/assert-eq (length (result :placements)) 2 "both windows placed")
(def p1 (find |(= ($ :window) w1) (result :placements)))
(def p2 (find |(= ($ :window) w2) (result :placements)))
(t/assert-truthy (< (p1 :y) (p2 :y)) "first above second")
(t/assert-eq (p1 :w) (p2 :w) "same width")

(t/report)
