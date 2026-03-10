# Tests for pool actions (Phase 2).
# All tree-manipulation actions: consume, expel, swap, zoom, set-mode,
# resize, focus-pool, send-to-pool, toggle-pool, float, cycle-preset,
# window insertion/removal, auto-unwrap.

(import ../src/pool)

(import ../src/pool/actions)

(var test-count 0)
(var fail-count 0)

(defmacro test [name & body]
  ~(do
    (++ test-count)
    (try
      (do ,;body)
      ([err fib]
        (++ fail-count)
        (eprintf "FAIL: %s\n  %s" ,name (string err))
        (debug/stacktrace fib err "")))))

(defmacro assert= [a b &opt msg]
  ~(let [va ,a vb ,b]
     (unless (= va vb)
       (error (string (or ,msg "") " expected " (string/format "%q" vb)
                       " got " (string/format "%q" va))))))

(defmacro assert-deep= [a b &opt msg]
  ~(let [va ,a vb ,b]
     (unless (deep= va vb)
       (error (string (or ,msg "") " expected " (string/format "%q" vb)
                       " got " (string/format "%q" va))))))

# --- Helpers ---
(defn w [&opt name] @{:app-id (or name "test")})

# ===== consume =====

(test "consume: pull right neighbor into stack-v"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  # Focused on a, consume :right should wrap a+b into a new stack-v
  (actions/consume root a :right)
  # a's parent should now be a sub-pool containing a and b
  (def parent (a :parent))
  (assert= (parent :mode) :stack-v "wrapper is stack-v")
  (assert= (length (parent :children)) 2 "wrapper has 2 children")
  (assert= (get (parent :children) 0) a)
  (assert= (get (parent :children) 1) b))

(test "consume: pull left neighbor into stack-v"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/consume root b :left)
  (def parent (b :parent))
  (assert= (length (parent :children)) 2)
  (assert= (get (parent :children) 0) a)
  (assert= (get (parent :children) 1) b))

(test "consume: no-op at edge"
  (def a (w "a"))
  (def b (w "b"))
  (def row (pool/make-pool :stack-v @[a b]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  # a is at index 0, consume :left is a no-op
  (actions/consume root a :left)
  (assert= (length (row :children)) 2 "no change"))

(test "consume: already in sub-pool, absorbs neighbor from parent"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def group (pool/make-pool :stack-v @[a b]))
  (def row (pool/make-pool :stack-v @[group c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  # Focused on a (inside group), consume :right should pull c into group
  (actions/consume root a :right)
  (assert= (length (group :children)) 3 "group absorbed c")
  (assert= (get (group :children) 2) c))

# ===== expel =====

(test "expel: move window out of sub-pool"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def group (pool/make-pool :stack-v @[a b]))
  (def row (pool/make-pool :stack-v @[group c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/expel root a)
  # a should now be a direct child of row, inserted after group
  (assert= (a :parent) row "a's parent is row")
  (assert= (length (group :children)) 1 "group lost a child"))

(test "expel: auto-unwrap when group reaches 1 child"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def group (pool/make-pool :stack-v @[a b]))
  (def row (pool/make-pool :stack-v @[group c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/expel root a)
  # group had [a, b], after expel a, group has [b] and should auto-unwrap
  # since it's a plain stack-v. b should now be a direct child of row.
  (assert= (b :parent) row "b promoted to row after auto-unwrap"))

(test "expel: no-op at tag level"
  (def a (w "a"))
  (def row (pool/make-pool :stack-v @[a]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  # a is a direct child of a row in the tag — expel should no-op
  (actions/expel root a)
  (assert= (a :parent) row "a still in row, no change"))

(test "expel: tabbed pool with 1 child does NOT auto-unwrap"
  (def a (w "a"))
  (def b (w "b"))
  (def tabs (pool/make-pool :tabbed @[a b] @{:active 0}))
  (def row (pool/make-pool :stack-v @[tabs]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/expel root a)
  # tabbed pool should persist even with 1 child (user intent)
  (assert= (tabs :mode) :tabbed "tabbed pool preserved")
  (assert= (length (tabs :children)) 1 "tabs has 1 child"))

# ===== swap =====

(test "swap: exchange siblings in stack-v"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c]))
  (actions/swap p a :down)
  (assert= (get (p :children) 0) b)
  (assert= (get (p :children) 1) a)
  (assert= (get (p :children) 2) c))

(test "swap: exchange siblings in stack-h"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b]))
  (actions/swap p a :right)
  (assert= (get (p :children) 0) b)
  (assert= (get (p :children) 1) a))

(test "swap: no-op at edge (no cross-pool for single pool)"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (actions/swap p b :down)
  # b is already last, no sibling to swap with, no parent to bubble to
  (assert= (get (p :children) 1) b "b stays at end"))

(test "swap: cross-pool between scroll rows"
  (def a (w "a"))
  (def b (w "b"))
  (def row0 (pool/make-pool :stack-v @[a]))
  (def row1 (pool/make-pool :stack-v @[b]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  # swap a :down should move a into row1
  (actions/swap p a :down)
  (assert= (a :parent) row1 "a moved to row1"))

(test "swap: weights stay with position, not window"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b] @{:weights @{0 2.0 1 1.0}}))
  (actions/swap p a :down)
  # After swap: b is at 0, a is at 1. Weights should be unchanged
  # (weight 2.0 stays at position 0, which is now b)
  (assert= (get (p :weights) 0) 2.0 "weight stays at position 0")
  (assert= (get (p :weights) 1) 1.0 "weight stays at position 1"))

(test "swap: in tabbed, updates :active to follow swapped window"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :tabbed @[a b c] @{:active 0}))
  # a is active, swap :down moves a to index 1
  (actions/swap p a :down)
  (assert= (p :active) 1 ":active follows the window"))

(test "swap: auto-create new row when moving down past last scroll row"
  (def a (w "a"))
  (def b (w "b"))
  (def row0 (pool/make-pool :stack-v @[b a]))
  (def p (pool/make-pool :scroll @[row0] @{:active-row 0}))
  # a is at bottom of only row, swap :down should create a new row below
  (actions/swap p a :down)
  (assert= (length (p :children)) 2 "new row created")
  (assert= (a :parent) (get (p :children) 1) "a is in new row")
  (assert= (p :active-row) 1 "active row follows")
  (assert= (length (row0 :children)) 1 "old row has b left"))

(test "swap: auto-create new row when moving up past first scroll row"
  (def a (w "a"))
  (def b (w "b"))
  (def row0 (pool/make-pool :stack-v @[a b]))
  (def p (pool/make-pool :scroll @[row0] @{:active-row 0}))
  # a is at top of only row, swap :up should create a new row above
  (actions/swap p a :up)
  (assert= (length (p :children)) 2 "new row created")
  (assert= (a :parent) (get (p :children) 0) "a is in new row at top")
  (assert= (p :active-row) 0 "active row is 0"))

(test "swap: auto-prune empty row after moving last window out"
  (def a (w "a"))
  (def b (w "b"))
  (def row0 (pool/make-pool :stack-v @[a]))
  (def row1 (pool/make-pool :stack-v @[b]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  # a is alone in row0, swap :down moves to row1 — row0 becomes empty and should be pruned
  (actions/swap p a :down)
  (assert= (length (p :children)) 1 "empty row pruned")
  (assert= (a :parent) (get (p :children) 0) "a joined row with b"))

# ===== zoom =====

(test "zoom: move to first position in parent"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c]))
  (actions/zoom p c)
  (assert= (get (p :children) 0) c "c is now first"))

(test "zoom: already first, no-op"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (actions/zoom p a)
  (assert= (get (p :children) 0) a "a stays first"))

(test "zoom: in scroll, zoom to first column in active row"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/zoom p c)
  (assert= (get (row :children) 0) c "c is first column"))

# ===== set-mode =====

(test "set-mode: change parent pool mode"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (def root (pool/make-pool :tabbed @[p] @{:active 0}))
  (actions/set-mode root a :stack-h)
  (assert= (p :mode) :stack-h))

(test "set-mode: :next cycles modes"
  (def a (w "a"))
  (def p (pool/make-pool :stack-v @[a]))
  (def root (pool/make-pool :tabbed @[p] @{:active 0}))
  (actions/set-mode root a :next)
  # stack-v -> stack-h -> tabbed -> scroll -> stack-v
  (assert= (p :mode) :stack-h "cycled to stack-h"))

(test "set-mode: :next skips scroll when inside scroll ancestor"
  (def a (w "a"))
  (def col (pool/make-pool :stack-v @[a]))
  (def row (pool/make-pool :stack-v @[col]))
  (def scroll (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def root (pool/make-pool :tabbed @[scroll] @{:active 0}))
  # cycle from stack-v, should skip :scroll
  (actions/set-mode root a :next)
  (assert= (col :mode) :stack-h "cycled to stack-h")
  (actions/set-mode root a :next)
  (assert= (col :mode) :tabbed "cycled to tabbed, skipped scroll"))

(test "set-mode: :tag target changes tag-level pool"
  (def a (w "a"))
  (def col (pool/make-pool :stack-v @[a]))
  (def row (pool/make-pool :stack-v @[col]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (actions/set-mode root a :stack-h :tag)
  (assert= (tag :mode) :stack-h "tag mode changed"))

# ===== resize =====

(test "resize: adjust ratio in 2-child stack-h"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b] @{:ratio 0.5}))
  (actions/resize p a 0.05)
  # Should increase ratio by delta
  (assert= (p :ratio) 0.55))

(test "resize: adjust weight in 3-child stack-v"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c] @{:weights @{0 1.0 1 1.0 2 1.0}}))
  (actions/resize p b 0.2)
  # b is at index 1, its weight should increase
  (assert (> (get (p :weights) 1) 1.0) "b's weight increased"))

(test "resize: :reset equalizes"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b] @{:ratio 0.7}))
  (actions/resize p a :reset)
  (assert= (p :ratio) 0.5 "ratio reset to 0.5"))

(test "resize: :reset clears weights"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c] @{:weights @{0 2.0 1 0.5 2 1.5}}))
  (actions/resize p a :reset)
  (assert (or (nil? (p :weights)) (empty? (p :weights))) "weights cleared"))

(test "resize: :cycle cycles scroll column width presets"
  (def a (w "a"))
  (put a :width 0.5)
  (put a :presets [0.5 0.7 1.0])
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/resize p a :cycle)
  (assert= (a :width) 0.7 "cycled to next preset"))

(test "resize: numeric delta on scroll column width"
  (def a (w "a"))
  (put a :width 0.5)
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/resize p a 0.1)
  (assert= (a :width) 0.6 "width increased"))

# ===== focus-pool (tag switching) =====

(test "focus-pool: switch active tag"
  (def a (w "a"))
  (def b (w "b"))
  (def tag1 (pool/make-pool :scroll @[] @{:id :main}))
  (def tag2 (pool/make-pool :scroll @[] @{:id :web}))
  (def root (pool/make-pool :tabbed @[tag1 tag2] @{:active 0}))
  (actions/focus-pool root :web)
  (assert= (root :active) 1 "switched to :web"))

(test "focus-pool: no-op if already active"
  (def tag1 (pool/make-pool :scroll @[] @{:id :main}))
  (def root (pool/make-pool :tabbed @[tag1] @{:active 0}))
  (actions/focus-pool root :main)
  (assert= (root :active) 0 "still :main"))

(test "focus-pool: non-existent id is no-op"
  (def tag1 (pool/make-pool :scroll @[] @{:id :main}))
  (def root (pool/make-pool :tabbed @[tag1] @{:active 0}))
  (actions/focus-pool root :nonexistent)
  (assert= (root :active) 0 "unchanged"))

# ===== send-to-pool =====

(test "send-to-pool: move window to another tag"
  (def a (w "a"))
  (def b (w "b"))
  (def row1 (pool/make-pool :stack-v @[a b]))
  (def tag1 (pool/make-pool :scroll @[row1] @{:id :main :active-row 0}))
  (def row2 (pool/make-pool :stack-v @[]))
  (def tag2 (pool/make-pool :scroll @[row2] @{:id :web :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag1 tag2] @{:active 0}))
  (actions/send-to-pool root a :web)
  # a should now be in tag2's active row
  (assert= (a :parent) row2 "a moved to tag2 row")
  (assert= (length (row1 :children)) 1 "row1 lost a child"))

(test "send-to-pool: auto-prune empty pool after send"
  (def a (w "a"))
  (def group (pool/make-pool :stack-v @[a]))
  (def row (pool/make-pool :stack-v @[group]))
  (def tag1 (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def row2 (pool/make-pool :stack-v @[]))
  (def tag2 (pool/make-pool :scroll @[row2] @{:id :web :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag1 tag2] @{:active 0}))
  (actions/send-to-pool root a :web)
  # group should be pruned (empty after removal), row may also be pruned
  (assert= (a :parent) row2 "a in target"))

# ===== toggle-pool =====

(test "toggle-pool: toggle second tag visible"
  (def tag1 (pool/make-pool :scroll @[] @{:id :main}))
  (def tag2 (pool/make-pool :scroll @[] @{:id :web}))
  (def root (pool/make-pool :tabbed @[tag1 tag2] @{:active 0}))
  (actions/toggle-pool root :web)
  # After toggle, both tags should be visible. Implementation detail:
  # root may have :multi-active or equivalent
  (assert (or (root :multi-active) (= (root :active) 1))
          "web tag toggled visible"))

# ===== insert-window (window routing) =====

(test "insert-window: new window appears after focused in parent"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "new"))
  (def p (pool/make-pool :stack-v @[a b]))
  (actions/insert-window p a c)
  (assert= (get (p :children) 0) a)
  (assert= (get (p :children) 1) c "new window after focused")
  (assert= (get (p :children) 2) b))

(test "insert-window: in tabbed pool, new window becomes new tab"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "new"))
  (def p (pool/make-pool :tabbed @[a b] @{:active 0}))
  (actions/insert-window p a c)
  (assert= (length (p :children)) 3 "tab added")
  # New tab inserted after active
  (assert= (get (p :children) 1) c "new tab after active"))

(test "insert-window: in scroll, new window is new column after focused"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "new"))
  (def row (pool/make-pool :stack-v @[a b]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  # Focused on a (column 0), new window should appear as column 1
  (actions/insert-window p a c)
  (assert= (get (row :children) 1) c "new column after focused"))

# ===== remove-window =====

(test "remove-window: basic removal"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c]))
  (actions/remove-window p b)
  (assert= (length (p :children)) 2)
  (assert= (get (p :children) 0) a)
  (assert= (get (p :children) 1) c))

(test "remove-window: auto-unwrap stack-v with default weights"
  (def a (w "a"))
  (def b (w "b"))
  (def group (pool/make-pool :stack-v @[a b]))
  (def row (pool/make-pool :stack-v @[group]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/remove-window root a)
  # group had [a, b], now has [b]. Auto-unwrap: b promoted to row
  (assert= (b :parent) row "b promoted after auto-unwrap"))

(test "remove-window: tabbed pool active adjusts on removal"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :tabbed @[a b c] @{:active 2}))
  (def root (pool/make-pool :stack-v @[p]))
  (actions/remove-window root c)
  # Was active=2, after removing last child, clamp to length-1
  (assert= (p :active) 1 "active clamped"))

(test "remove-window: empty pool is pruned"
  (def a (w "a"))
  (def group (pool/make-pool :stack-v @[a]))
  (def row (pool/make-pool :stack-v @[group (w "b")]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/remove-window root a)
  # group is now empty, should be removed from row
  (assert= (length (row :children)) 1 "empty group pruned"))

(test "remove-window: tabbed pool with 1 child persists"
  (def a (w "a"))
  (def b (w "b"))
  (def tabs (pool/make-pool :tabbed @[a b] @{:active 0}))
  (def row (pool/make-pool :stack-v @[tabs]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  (actions/remove-window root a)
  (assert= (tabs :mode) :tabbed "tabbed persists with 1 child")
  (assert= (length (tabs :children)) 1))

# ===== cycle-preset =====

(test "cycle-preset: scroll -> master-stack"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (actions/cycle-preset root a)
  # After cycling from scroll, tag should become master-stack (stack-h)
  (assert= (tag :mode) :stack-h "changed to master-stack")
  (assert (tag :ratio) "has ratio set"))

(test "cycle-preset: master-stack -> monocle"
  (def a (w "a"))
  (def b (w "b"))
  (def tag (pool/make-pool :stack-h @[a b] @{:id :main :ratio 0.55}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (actions/cycle-preset root a)
  (assert= (tag :mode) :tabbed "changed to monocle"))

# ===== float =====

(test "float-toggle: float removes from tree"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (def root (pool/make-pool :tabbed @[p] @{:active 0}))
  (actions/float-toggle root a)
  (assert= (length (p :children)) 1 "a removed from pool")
  (assert (a :floating) "a is marked floating"))

(test "float-toggle: unfloat inserts back"
  (def a (w "a"))
  (def b (w "b"))
  (put a :floating true)
  (def p (pool/make-pool :stack-v @[b]))
  (def root (pool/make-pool :tabbed @[p] @{:active 0}))
  # Unfloat should insert a back at the focused position
  (actions/float-toggle root a)
  (assert (not (a :floating)) "a is no longer floating")
  (assert= (a :parent) p "a inserted into pool"))

# ===== Edge cases =====

(test "consume: into tabbed pool absorbs as new tab"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def tabs (pool/make-pool :tabbed @[a b] @{:active 0}))
  (def row (pool/make-pool :stack-v @[tabs c]))
  (def root (pool/make-pool :scroll @[row] @{:active-row 0}))
  # consume from tabbed pool should absorb c as a new tab
  (actions/consume root a :right)
  (assert= (length (tabs :children)) 3 "c absorbed as tab"))

(test "swap: in tabbed, swap cycles active index"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :tabbed @[a b] @{:active 0}))
  (actions/swap p a :down)
  (assert= (get (p :children) 0) b)
  (assert= (get (p :children) 1) a)
  (assert= (p :active) 1 "active follows swapped window"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
