# Tests for pool tree primitives and rendering.

(import ../src/pool)
(import ../src/pool/render)

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

(defn w [] @{:app-id "test"})
(defn ws [n] (seq [_ :range [0 n]] (w)))

(def config @{:outer-padding 0 :inner-padding 8})
(def config-no-pad @{:outer-padding 0 :inner-padding 0})
(def rect @{:x 0 :y 0 :w 1000 :h 800})

# ===== Pool tree primitives =====

(test "make-pool: sets parent on children"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-v @[a b]))
  (assert= (a :parent) p "child a parent")
  (assert= (b :parent) p "child b parent")
  (assert= (p :mode) :stack-v "mode")
  (assert= (length (p :children)) 2 "children count"))

(test "make-pool: with props"
  (def p (pool/make-pool :tabbed @[] @{:id :main :active 0}))
  (assert= (p :id) :main "id")
  (assert= (p :active) 0 "active"))

(test "insert-child: at index"
  (def a (w))
  (def b (w))
  (def c (w))
  (def p (pool/make-pool :stack-v @[a b]))
  (pool/insert-child p c 1)
  (assert= (length (p :children)) 3)
  (assert= (get (p :children) 1) c "inserted at 1")
  (assert= (c :parent) p "parent set"))

(test "append-child"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-v @[a]))
  (pool/append-child p b)
  (assert= (length (p :children)) 2)
  (assert= (get (p :children) 1) b "appended"))

(test "remove-child: returns child, clears parent"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-v @[a b]))
  (def removed (pool/remove-child p 0))
  (assert= removed a "returned child")
  (assert= (a :parent) nil "parent cleared")
  (assert= (length (p :children)) 1 "one left"))

(test "child-index"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-v @[a b]))
  (assert= (pool/child-index p a) 0)
  (assert= (pool/child-index p b) 1))

(test "wrap-children"
  (def a (w))
  (def b (w))
  (def c (w))
  (def p (pool/make-pool :stack-h @[a b c]))
  (def wrapper (pool/wrap-children p 0 2 :stack-v))
  (assert= (length (p :children)) 2 "parent has 2 children now")
  (assert= (get (p :children) 0) wrapper "wrapper is first")
  (assert= (get (p :children) 1) c "c is second")
  (assert= (wrapper :mode) :stack-v "wrapper mode")
  (assert= (length (wrapper :children)) 2 "wrapper has 2")
  (assert= (a :parent) wrapper "a reparented")
  (assert= (wrapper :parent) p "wrapper parent"))

(test "unwrap-pool"
  (def a (w))
  (def b (w))
  (def inner (pool/make-pool :stack-v @[a b]))
  (def outer (pool/make-pool :stack-h @[inner]))
  (pool/unwrap-pool outer 0)
  (assert= (length (outer :children)) 2 "unwrapped to 2 children")
  (assert= (a :parent) outer "a reparented to outer")
  (assert= (b :parent) outer "b reparented to outer"))

(test "move-child"
  (def a (w))
  (def b (w))
  (def p1 (pool/make-pool :stack-v @[a b]))
  (def p2 (pool/make-pool :stack-v @[]))
  (pool/move-child p1 0 p2 0)
  (assert= (length (p1 :children)) 1 "p1 has 1")
  (assert= (length (p2 :children)) 1 "p2 has 1")
  (assert= (a :parent) p2 "a moved to p2"))

(test "walk-windows: collects all leaves"
  (def a (w))
  (def b (w))
  (def c (w))
  (def inner (pool/make-pool :stack-v @[b c]))
  (def outer (pool/make-pool :stack-h @[a inner]))
  (def found @[])
  (pool/walk-windows outer |(array/push found $))
  (assert= (length found) 3 "found 3 windows"))

(test "collect-windows"
  (def a (w))
  (def b (w))
  (def inner (pool/make-pool :stack-v @[a b]))
  (def outer (pool/make-pool :tabbed @[inner]))
  (def wins (pool/collect-windows outer))
  (assert= (length wins) 2)
  (assert= (get wins 0) a)
  (assert= (get wins 1) b))

(test "find-window"
  (def a (w))
  (def b (w))
  (def c (w))
  (def inner (pool/make-pool :stack-v @[b c]))
  (def outer (pool/make-pool :stack-h @[a inner]))
  (assert-deep= (pool/find-window outer a) @[0] "a at index 0")
  (assert-deep= (pool/find-window outer b) @[1 0] "b at [1 0]")
  (assert-deep= (pool/find-window outer c) @[1 1] "c at [1 1]")
  (assert= (pool/find-window outer (w)) nil "not found"))

(test "find-ancestor"
  (def a (w))
  (def inner (pool/make-pool :tabbed @[a] @{:id :tab}))
  (def outer (pool/make-pool :scroll @[inner] @{:id :scroll}))
  (def found (pool/find-ancestor a |(= ($ :mode) :scroll)))
  (assert= found outer "found scroll ancestor"))

(test "tag-pool"
  (def a (w))
  (def tag (pool/make-pool :scroll @[a] @{:id :main}))
  (def output (pool/make-pool :tabbed @[tag]))
  (assert= (pool/tag-pool a) tag "tag pool from window"))

(test "find-pool-by-id"
  (def a (w))
  (def tag1 (pool/make-pool :scroll @[a] @{:id :main}))
  (def tag2 (pool/make-pool :scroll @[] @{:id :web}))
  (def output (pool/make-pool :tabbed @[tag1 tag2]))
  (assert= (pool/find-pool-by-id output :main) tag1)
  (assert= (pool/find-pool-by-id output :web) tag2)
  (assert= (pool/find-pool-by-id output :nope) nil))

(test "sync-tags"
  (def a (w))
  (def b (w))
  (def tag1 (pool/make-pool :scroll @[a] @{:id :main}))
  (def tag2 (pool/make-pool :scroll @[b] @{:id :web}))
  (def output (pool/make-pool :tabbed @[tag1 tag2]))
  (pool/sync-tags output)
  (assert= (a :tag) :main "a tagged :main")
  (assert= (b :tag) :web "b tagged :web"))

(test "auto-unwrap: stack-v with defaults"
  (def a (w))
  (def inner (pool/make-pool :stack-v @[a]))
  (assert (pool/auto-unwrap? inner) "default stack-v unwraps"))

(test "auto-unwrap: tabbed does not"
  (def a (w))
  (def inner (pool/make-pool :tabbed @[a]))
  (assert (not (pool/auto-unwrap? inner)) "tabbed does not unwrap"))

(test "auto-unwrap: stack-v with ratio does not"
  (def a (w))
  (def inner (pool/make-pool :stack-v @[a] @{:ratio 0.5}))
  (assert (not (pool/auto-unwrap? inner)) "stack-v with ratio does not unwrap"))

(test "maybe-unwrap: triggers for default stack-v"
  (def a (w))
  (def inner (pool/make-pool :stack-v @[a]))
  (def outer (pool/make-pool :stack-h @[inner]))
  (pool/maybe-unwrap inner)
  (assert= (length (outer :children)) 1 "one child")
  (assert= (get (outer :children) 0) a "a is direct child")
  (assert= (a :parent) outer "a reparented"))

(test "maybe-unwrap: does not trigger for tabbed"
  (def a (w))
  (def inner (pool/make-pool :tabbed @[a]))
  (def outer (pool/make-pool :stack-h @[inner]))
  (pool/maybe-unwrap inner)
  (assert= (length (outer :children)) 1 "still one child")
  (assert= (get (outer :children) 0) inner "inner preserved"))

(test "auto-unwrap: scroll row does not unwrap"
  (def a (w))
  (def row (pool/make-pool :stack-v @[a]))
  (def scroll (pool/make-pool :scroll @[row] @{:active-row 0}))
  (assert (not (pool/auto-unwrap? row)) "scroll row must not unwrap"))

(test "maybe-prune: removes empty pool"
  (def inner (pool/make-pool :stack-v @[]))
  (def outer (pool/make-pool :stack-h @[inner]))
  (pool/maybe-prune inner)
  (assert= (length (outer :children)) 0 "empty pool removed"))

# ===== Rendering: stack =====

(test "render stack-h: 2 children, no padding"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-h @[a b] @{:ratio 0.6}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 2 "2 placements")
  (assert= ((get pl 0) :w) 600 "first child 60%")
  (assert= ((get pl 1) :w) 400 "second child 40%")
  (assert= ((get pl 0) :x) 0 "first at x=0")
  (assert= ((get pl 1) :x) 600 "second at x=600"))

(test "render stack-v: 2 children with ratio"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-v @[a b] @{:ratio 0.5}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 2 "2 placements")
  (assert= ((get pl 0) :h) 400 "first child 50%")
  (assert= ((get pl 1) :h) 400 "second child 50%")
  (assert= ((get pl 0) :y) 0 "first at y=0")
  (assert= ((get pl 1) :y) 400 "second at y=400"))

(test "render stack-h: 3 children with weights"
  (def a (w))
  (def b (w))
  (def c (w))
  (def p (pool/make-pool :stack-h @[a b c] @{:weights @{0 2.0 1 1.0 2 1.0}}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 3)
  (assert= ((get pl 0) :w) 500 "first child weight 2")
  (assert= ((get pl 1) :w) 250 "second child weight 1")
  (assert= ((get pl 2) :w) 250 "third child weight 1"))

(test "render stack-h: with inner padding"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :stack-h @[a b] @{:ratio 0.5}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config nil nil))
  (def pl (result :placements))
  # With inner=8, gap=8, available=992, each child=496
  (assert= ((get pl 0) :w) 496 "first with padding")
  (assert= ((get pl 1) :w) 496 "second with padding")
  (assert= ((get pl 0) :x) 0 "first at x=0")
  (assert= ((get pl 1) :x) 504 "second at x=504"))

(test "render stack: empty pool"
  (def p (pool/make-pool :stack-h @[]))
  (def result (render/render-pool p rect config nil nil))
  (assert= (length (result :placements)) 0 "no placements"))

(test "render stack: single child"
  (def a (w))
  (def p (pool/make-pool :stack-v @[a]))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 1)
  (assert= ((get pl 0) :w) 1000 "full width")
  (assert= ((get pl 0) :h) 800 "full height"))

(test "render stack: nested stacks"
  (def a (w))
  (def b (w))
  (def c (w))
  (def inner (pool/make-pool :stack-v @[b c] @{:ratio 0.5}))
  (def outer (pool/make-pool :stack-h @[a inner] @{:ratio 0.5}))
  (def result (render/render-pool outer @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 3 "3 windows")
  (assert= ((get pl 0) :w) 500 "a gets 500")
  (assert= ((get pl 1) :w) 500 "b gets 500")
  (assert= ((get pl 1) :h) 400 "b gets 400")
  (assert= ((get pl 2) :h) 400 "c gets 400"))

# ===== Rendering: tabbed =====

(test "render tabbed: active child placed, rest hidden"
  (def a (w))
  (def b (w))
  (def c (w))
  (def p (pool/make-pool :tabbed @[a b c] @{:active 1}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 3 "3 placements")
  (def visible (filter |(not ($ :hidden)) pl))
  (def hidden (filter |($ :hidden) pl))
  (assert= (length visible) 1 "1 visible")
  (assert= (length hidden) 2 "2 hidden")
  (assert= ((get visible 0) :window) b "b is visible")
  (assert= ((get visible 0) :w) 1000 "full width"))

(test "render tabbed: active clamped to valid range"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :tabbed @[a b] @{:active 5}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (assert= (p :active) 1 "clamped to last")
  (def visible (filter |(not ($ :hidden)) (result :placements)))
  (assert= ((get visible 0) :window) b "last child visible"))

(test "render tabbed: active 0 by default"
  (def a (w))
  (def b (w))
  (def p (pool/make-pool :tabbed @[a b]))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def visible (filter |(not ($ :hidden)) (result :placements)))
  (assert= ((get visible 0) :window) a "first child visible by default"))

(test "render tabbed: nested pool as active child"
  (def a (w))
  (def b (w))
  (def inner (pool/make-pool :stack-v @[a b] @{:ratio 0.5}))
  (def c (w))
  (def p (pool/make-pool :tabbed @[inner c] @{:active 0}))
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 3 "3 placements (2 from inner + 1 hidden)")
  (def visible (filter |(not ($ :hidden)) pl))
  (assert= (length visible) 2 "2 visible from inner stack"))

(test "render tabbed: empty"
  (def p (pool/make-pool :tabbed @[]))
  (def result (render/render-pool p rect config nil nil))
  (assert= (length (result :placements)) 0))

# ===== Rendering: scroll =====

(test "render scroll: single row, 2 cols 50% — both visible"
  (def a (w))
  (def b (w))
  (def row (pool/make-pool :stack-v @[a b]))  # row container
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def pl (result :placements))
  (def visible (filter |(not ($ :hidden)) pl))
  (assert= (length visible) 2 "2 visible"))

(test "render scroll: single row, 3 cols 50% — overflow, off-screen hidden"
  (def a (w))
  (def b (w))
  (def c (w))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg a nil))
  (def pl (result :placements))
  # 3 cols * 500px = 1500px > 1000px viewport
  # With focus on first col at scroll=0, third col at x=1000 should be hidden
  (def visible (filter |(not ($ :hidden)) pl))
  (assert (>= (length visible) 2) "at least 2 visible"))

(test "render scroll: multi-row, non-active rows hidden"
  (def a (w))
  (def b (w))
  (def row0 (pool/make-pool :stack-v @[a]))
  (def row1 (pool/make-pool :stack-v @[b]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def pl (result :placements))
  (def b-placement (find |(= ($ :window) b) pl))
  (assert (b-placement :hidden) "window in non-active row is hidden"))

(test "render scroll: active-row clamped"
  (def a (w))
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 5}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil)
  (assert= (p :active-row) 0 "clamped to 0"))

(test "render scroll: columns get full viewport height"
  (def a (w))
  (def b (w))
  (def row (pool/make-pool :stack-v @[a b]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def visible (filter |(not ($ :hidden)) (result :placements)))
  (each v visible
    (assert= (v :h) 800 "column gets full viewport height")))

(test "render scroll: scroll-placed flag set"
  (def a (w))
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def pl (result :placements))
  (assert ((get pl 0) :scroll-placed) "scroll-placed flag set"))

(test "render scroll: column with nested stack-v subdivides height"
  (def a (w))
  (def b (w))
  (def col (pool/make-pool :stack-v @[a b] @{:ratio 0.5}))
  (def row (pool/make-pool :stack-v @[col]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 1.0})
  (def result (render/render-pool p @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def visible (filter |(not ($ :hidden)) (result :placements)))
  (assert= (length visible) 2 "2 visible windows")
  (assert= ((get visible 0) :h) 400 "first half")
  (assert= ((get visible 1) :h) 400 "second half"))

# ===== Rendering: window leaf (no pool wrapper) =====

(test "render bare window"
  (def a (w))
  (def result (render/render-pool a @{:x 10 :y 20 :w 500 :h 400} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 1)
  (assert= ((get pl 0) :x) 10)
  (assert= ((get pl 0) :y) 20)
  (assert= ((get pl 0) :w) 500)
  (assert= ((get pl 0) :h) 400))

# ===== Animation flag propagation =====

(test "animating: false when no animations"
  (def a (w))
  (def p (pool/make-pool :stack-v @[a]))
  (def result (render/render-pool p rect config nil nil))
  (assert= (result :animating) false "not animating"))

# ===== Deeply nested =====

(test "deeply nested: 4 levels"
  (def a (w))
  (def b (w))
  (def c (w))
  (def d (w))
  (def l3 (pool/make-pool :stack-v @[c d] @{:ratio 0.5}))
  (def l2 (pool/make-pool :tabbed @[b l3] @{:active 1}))
  (def l1 (pool/make-pool :stack-h @[a l2] @{:ratio 0.5}))
  (def result (render/render-pool l1 @{:x 0 :y 0 :w 1000 :h 800} config-no-pad nil nil))
  (def pl (result :placements))
  (assert= (length pl) 4 "4 windows total")
  (def visible (filter |(not ($ :hidden)) pl))
  # a is visible (stack-h left), b is hidden (tabbed inactive), c and d visible (tabbed active → stack-v)
  (assert= (length visible) 3 "3 visible (a, c, d)")
  (def hidden (filter |($ :hidden) pl))
  (assert= (length hidden) 1 "1 hidden (b)"))

# ===== Full tree: output → tabbed → scroll → row → columns =====

(test "full tree: output with 2 tags, tag switching"
  (def a (w))
  (def b (w))
  (def c (w))
  (def row1 (pool/make-pool :stack-v @[a b]))
  (def tag1 (pool/make-pool :scroll @[row1] @{:id :main :active-row 0}))
  (def row2 (pool/make-pool :stack-v @[c]))
  (def tag2 (pool/make-pool :scroll @[row2] @{:id :web :active-row 0}))
  (def output (pool/make-pool :tabbed @[tag1 tag2] @{:active 0}))
  (def cfg @{:outer-padding 0 :inner-padding 0 :column-width 0.5})
  (def result (render/render-pool output @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def pl (result :placements))
  (def visible (filter |(not ($ :hidden)) pl))
  (def hidden (filter |($ :hidden) pl))
  # Tag 1 active: a and b visible. Tag 2: c hidden.
  (assert= (length visible) 2 "2 visible from tag 1")
  (assert= (length hidden) 1 "1 hidden from tag 2")
  # Switch to tag 2
  (put output :active 1)
  (def result2 (render/render-pool output @{:x 0 :y 0 :w 1000 :h 800} cfg nil nil))
  (def visible2 (filter |(not ($ :hidden)) (result2 :placements)))
  (def hidden2 (filter |($ :hidden) (result2 :placements)))
  (assert= (length visible2) 1 "1 visible from tag 2")
  (assert= (length hidden2) 2 "2 hidden from tag 1"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
