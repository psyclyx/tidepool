# Tests for pool navigation (Phase 1).
# navigate [root focused dir] -> target window or nil

(import ../src/pool)
(import ../src/pool/render)

(import ../src/pool/navigate)

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

# --- Helpers ---
(defn w [&opt name] (def win @{:app-id (or name "test")}) win)

# ===== stack-h navigation =====

(test "stack-h: right moves to next sibling"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-h @[a b c]))
  (assert= (navigate/navigate p a :right) b))

(test "stack-h: left moves to prev sibling"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b]))
  (assert= (navigate/navigate p b :left) a))

(test "stack-h: right at end returns nil"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b]))
  (assert= (navigate/navigate p b :right) nil))

(test "stack-h: left at start returns nil"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b]))
  (assert= (navigate/navigate p a :left) nil))

(test "stack-h: up/down bubble up (return nil at root)"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-h @[a b]))
  (assert= (navigate/navigate p a :up) nil)
  (assert= (navigate/navigate p a :down) nil))

# ===== stack-v navigation =====

(test "stack-v: down moves to next sibling"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :stack-v @[a b c]))
  (assert= (navigate/navigate p a :down) b))

(test "stack-v: up moves to prev sibling"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (assert= (navigate/navigate p b :up) a))

(test "stack-v: down at end returns nil"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :stack-v @[a b]))
  (assert= (navigate/navigate p b :down) nil))

(test "stack-v: left/right bubble up (return nil at root)"
  (def a (w "a"))
  (def p (pool/make-pool :stack-v @[a]))
  (assert= (navigate/navigate p a :left) nil)
  (assert= (navigate/navigate p a :right) nil))

# ===== tabbed navigation =====

(test "tabbed: down cycles to next tab"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :tabbed @[a b c] @{:active 0}))
  (assert= (navigate/navigate p a :down) b)
  (assert= (p :active) 1 "active updated"))

(test "tabbed: up cycles to prev tab"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def p (pool/make-pool :tabbed @[a b c] @{:active 2}))
  (assert= (navigate/navigate p c :up) b)
  (assert= (p :active) 1 "active updated"))

(test "tabbed: down wraps from last to first"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :tabbed @[a b] @{:active 1}))
  (assert= (navigate/navigate p b :down) a)
  (assert= (p :active) 0))

(test "tabbed: up wraps from first to last"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :tabbed @[a b] @{:active 0}))
  (assert= (navigate/navigate p a :up) b)
  (assert= (p :active) 1))

(test "tabbed: left/right bubble up (return nil at root)"
  (def a (w "a"))
  (def b (w "b"))
  (def p (pool/make-pool :tabbed @[a b] @{:active 0}))
  (assert= (navigate/navigate p a :left) nil)
  (assert= (navigate/navigate p a :right) nil))

(test "tabbed: single child, cycling returns nil"
  (def a (w "a"))
  (def p (pool/make-pool :tabbed @[a] @{:active 0}))
  (assert= (navigate/navigate p a :down) nil)
  (assert= (navigate/navigate p a :up) nil))

# ===== scroll navigation =====

(test "scroll: left/right moves between columns in active row"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row (pool/make-pool :stack-v @[a b c]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (assert= (navigate/navigate p a :right) b)
  (assert= (navigate/navigate p b :right) c)
  (assert= (navigate/navigate p c :right) nil)
  (assert= (navigate/navigate p b :left) a)
  (assert= (navigate/navigate p a :left) nil))

(test "scroll: up/down crosses rows"
  (def a (w "a"))
  (def b (w "b"))
  (def row0 (pool/make-pool :stack-v @[a]))
  (def row1 (pool/make-pool :stack-v @[b]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  # Down from row 0 → row 1
  (def target (navigate/navigate p a :down))
  (assert= target b "down crosses to row 1")
  (assert= (p :active-row) 1 "active-row updated"))

(test "scroll: up from first row returns nil"
  (def a (w "a"))
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (assert= (navigate/navigate p a :up) nil))

(test "scroll: down from last row returns nil"
  (def a (w "a"))
  (def row (pool/make-pool :stack-v @[a]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  (assert= (navigate/navigate p a :down) nil))

(test "scroll: entering new row focuses first column (from above)"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def row0 (pool/make-pool :stack-v @[a]))
  (def row1 (pool/make-pool :stack-v @[b c]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 1}))
  (def target (navigate/navigate p b :up))
  (assert= target a "up from row 1 goes to row 0"))

# ===== Cross-pool navigation (bubble up + descend) =====

(test "cross-pool: stack-v inside stack-h, right crosses to sibling"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def left (pool/make-pool :stack-v @[a b]))
  (def outer (pool/make-pool :stack-h @[left c]))
  (assert= (navigate/navigate outer a :right) c "right from stack-v bubbles to stack-h"))

(test "cross-pool: right into stack-v enters from top"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def right (pool/make-pool :stack-v @[b c]))
  (def outer (pool/make-pool :stack-h @[a right]))
  (assert= (navigate/navigate outer a :right) b "enters stack-v from top"))

(test "cross-pool: left into stack-v enters from top"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def left (pool/make-pool :stack-v @[b c]))
  (def outer (pool/make-pool :stack-h @[left a]))
  (assert= (navigate/navigate outer a :left) b "enters stack-v from top (left)"))

(test "cross-pool: entering tabbed pool picks active child"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def tabs (pool/make-pool :tabbed @[b c] @{:active 1}))
  (def outer (pool/make-pool :stack-h @[a tabs]))
  (assert= (navigate/navigate outer a :right) c "enters tabbed at active"))

(test "cross-pool: down from stack-h child into sibling's stack-v"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def top (pool/make-pool :stack-h @[a b]))
  (def outer (pool/make-pool :stack-v @[top c]))
  (assert= (navigate/navigate outer a :down) c "down from stack-h bubbles to stack-v"))

# ===== Nested scroll + stack-v within column =====

(test "scroll column with stack-v: up/down navigates within column first"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def col (pool/make-pool :stack-v @[a b]))
  (def row (pool/make-pool :stack-v @[col c]))
  (def p (pool/make-pool :scroll @[row] @{:active-row 0}))
  # Down within the stack-v column
  (assert= (navigate/navigate p a :down) b "down within stack-v column"))

(test "scroll column with stack-v: down at bottom of column goes to next row"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def col (pool/make-pool :stack-v @[a b]))
  (def row0 (pool/make-pool :stack-v @[col]))
  (def row1 (pool/make-pool :stack-v @[c]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  (def target (navigate/navigate p b :down))
  (assert= target c "down at column bottom crosses to next row"))

(test "scroll column with tabbed: down cycles tabs, doesn't cross rows"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def col (pool/make-pool :tabbed @[a b] @{:active 0}))
  (def row0 (pool/make-pool :stack-v @[col]))
  (def row1 (pool/make-pool :stack-v @[c]))
  (def p (pool/make-pool :scroll @[row0 row1] @{:active-row 0}))
  (def target (navigate/navigate p a :down))
  (assert= target b "down cycles tab, doesn't cross row")
  (assert= (p :active-row) 0 "still on row 0"))

# ===== Deep nesting =====

(test "3-level: output → scroll → row → stack-h → stack-v → window"
  (def a (w "a"))
  (def b (w "b"))
  (def c (w "c"))
  (def right-col (pool/make-pool :stack-v @[b c]))
  (def row (pool/make-pool :stack-v @[a right-col]))
  (def tag (pool/make-pool :scroll @[row] @{:active-row 0 :id :main}))
  (def output (pool/make-pool :tabbed @[tag] @{:active 0}))
  # Navigate from a → right into stack-v, get b (top)
  (assert= (navigate/navigate output a :right) b)
  # Navigate from b down within stack-v → c
  (assert= (navigate/navigate output b :down) c)
  # Navigate from c left → a
  (assert= (navigate/navigate output c :left) a))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
