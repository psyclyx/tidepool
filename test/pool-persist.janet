# Tests for pool persistence (Phase 4).
# Serialize pool tree to JDN, restore from JDN with window matching.

(import ../src/pool)

# Stub persistence module — replace with real import when implemented:
# (import ../src/pool/persist)
(defn serialize [outputs] (error "pool/persist/serialize not yet implemented"))
(defn restore [data windows] (error "pool/persist/restore not yet implemented"))
(defn pp-jdn [val &opt indent] (error "pool/persist/pp-jdn not yet implemented"))

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
(defn w [app-id &opt title]
  @{:app-id app-id :title (or title "~")})

# ===== serialize =====

(test "serialize: window leaves become {:app-id :title}"
  (def a (w "foot" "~"))
  (def b (w "firefox" "GitHub"))
  (def row (pool/make-pool :stack-v @[a b]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (def output @{:connector "DP-1" :pool root})
  (def result (serialize @[output]))
  # Result should be a string (JDN)
  (assert (string? result) "result is a string")
  # Parse it back
  (def parsed (parse result))
  (assert (parsed :outputs) "has :outputs key")
  (def out (get (parsed :outputs) 0))
  (assert= (out :connector) "DP-1")
  (def p (out :pool))
  (assert= (p :mode) :tabbed)
  (def tag-p (get (p :children) 0))
  (assert= (tag-p :id) :main)
  (assert= (tag-p :mode) :scroll)
  (def row-p (get (tag-p :children) 0))
  (def leaf-a (get (row-p :children) 0))
  (def leaf-b (get (row-p :children) 1))
  (assert= (leaf-a :app-id) "foot")
  (assert= (leaf-b :app-id) "firefox")
  (assert= (leaf-b :title) "GitHub"))

(test "serialize: preserves pool properties"
  (def a (w "foot"))
  (def b (w "foot"))
  (def group (pool/make-pool :stack-v @[a b] @{:ratio 0.6 :weights @{0 2.0}}))
  (def row (pool/make-pool :stack-v @[group]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (def result (serialize @[@{:connector "DP-1" :pool root}]))
  (def parsed (parse result))
  (def out-p (get (get (parsed :outputs) 0) :pool))
  (def tag-p (get (out-p :children) 0))
  (def row-p (get (tag-p :children) 0))
  (def grp (get (row-p :children) 0))
  (assert= (grp :ratio) 0.6 "ratio preserved")
  (assert= (get (grp :weights) 0) 2.0 "weight preserved"))

(test "serialize: strips transient state"
  (def a (w "foot"))
  (put a :parent @{})  # transient
  (put a :x 100)       # transient position
  (put a :y 200)
  (def tag (pool/make-pool :scroll @[(pool/make-pool :stack-v @[a])]
            @{:id :main :active-row 0 :scroll-offset-x @{0 150}}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (def result (serialize @[@{:connector "DP-1" :pool root}]))
  (def parsed (parse result))
  (def out-p2 (get (get (parsed :outputs) 0) :pool))
  (def tag-p (get (out-p2 :children) 0))
  # scroll-offset-x should be zeroed or stripped
  (def sox (tag-p :scroll-offset-x))
  (assert (or (nil? sox) (= (get sox 0) 0) (empty? sox))
          "scroll offset zeroed"))

(test "serialize: zeroes scroll-offset-x"
  (def a (w "foot"))
  (def row (pool/make-pool :stack-v @[a]))
  (def tag (pool/make-pool :scroll @[row]
            @{:id :main :active-row 0 :scroll-offset-x @{0 500}}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (def result (serialize @[@{:connector "DP-1" :pool root}]))
  (def parsed (parse result))
  (def out-p3 (get (get (parsed :outputs) 0) :pool))
  (def tag-p (get (out-p3 :children) 0))
  (when-let [sox (tag-p :scroll-offset-x)]
    (assert (or (nil? (get sox 0)) (= (get sox 0) 0))
            "scroll offset zeroed on save")))

# ===== restore =====

(test "restore: matches windows by app-id + title"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"} @{:app-id "firefox" :title "GitHub"}]}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def firefox (w "firefox" "GitHub"))
  (def windows @[foot firefox])
  (def result (restore (parse saved) windows))
  # Result should be a table of outputs with restored pool trees
  (def out (get (result :outputs) 0))
  (assert= (out :connector) "DP-1")
  (def p (out :pool))
  (assert= (p :mode) :tabbed)
  # Windows should be matched into the tree
  (def leaves (pool/collect-windows p))
  (assert= (length leaves) 2)
  # The matched windows should be the actual window objects
  (assert= (get leaves 0) foot "foot matched")
  (assert= (get leaves 1) firefox "firefox matched"))

(test "restore: unmatched tree leaves are pruned"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"} @{:app-id "emacs" :title "scratch"}]}]}]}}]}`)
  # Only foot is available, emacs is not
  (def foot (w "foot" "~"))
  (def result (restore (parse saved) @[foot]))
  (def leaves (pool/collect-windows (get (get (result :outputs) 0) :pool)))
  # Only foot should be in the tree, emacs leaf pruned
  (assert= (length leaves) 1)
  (assert= (get leaves 0) foot))

(test "restore: unmatched windows appended to first pool"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"}]}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def extra (w "alacritty" "bash"))
  (def result (restore (parse saved) @[foot extra]))
  (def leaves (pool/collect-windows (get (get (result :outputs) 0) :pool)))
  # Both should be in the tree — extra appended
  (assert= (length leaves) 2 "unmatched window appended"))

(test "restore: duplicate app-id+title matched in order"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :stack-v :id :main :children @[@{:app-id "foot" :title "~"} @{:app-id "foot" :title "~"} @{:app-id "foot" :title "~"}]}]}}]}`)
  (def t1 (w "foot" "~"))
  (def t2 (w "foot" "~"))
  (def t3 (w "foot" "~"))
  (def result (restore (parse saved) @[t1 t2 t3]))
  (def leaves (pool/collect-windows (get (get (result :outputs) 0) :pool)))
  (assert= (length leaves) 3 "all 3 terminals matched")
  # Order should be preserved (first match wins)
  (assert= (get leaves 0) t1)
  (assert= (get leaves 1) t2)
  (assert= (get leaves 2) t3))

(test "restore: parent pointers are set on restored tree"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :stack-v :id :main :children @[@{:app-id "foot" :title "~"} @{:app-id "firefox" :title "Docs"}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def firefox (w "firefox" "Docs"))
  (def result (restore (parse saved) @[foot firefox]))
  (def p (get (get (result :outputs) 0) :pool))
  # Every child should have :parent set
  (assert (foot :parent) "foot has parent")
  (assert (firefox :parent) "firefox has parent")
  (assert= (foot :parent) (firefox :parent) "same parent (stack-v)")
  (assert= ((foot :parent) :parent) p "stack-v's parent is root tabbed"))

(test "restore: empty pool after pruning is removed"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:mode :stack-v :children @[@{:app-id "gone" :title "x"}]}]}]}]}}]}`)
  # No windows available — entire inner pool should be pruned
  (def result (restore (parse saved) @[]))
  (def tag (get (get (result :outputs) 0) :pool))
  # Tag should still exist (tags never pruned) but be empty or have empty row
  (assert= (tag :mode) :tabbed "root persists"))

# ===== pp-jdn =====

(test "pp-jdn: produces valid parseable JDN"
  (def data @{:mode :tabbed :active 0 :children @[@{:app-id "foot" :title "~"}]})
  (def result (pp-jdn data))
  (assert (string? result) "result is string")
  (def parsed (parse result))
  (assert= (parsed :mode) :tabbed "round-trips"))

(test "pp-jdn: nested structure is indented"
  (def data @{:mode :tabbed :children @[@{:mode :stack-v :children @[@{:app-id "a" :title "b"}]}]})
  (def result (pp-jdn data))
  # Should contain newlines (pretty-printed)
  (assert (string/find "\n" result) "contains newlines")
  # Should contain indentation
  (assert (string/find "  " result) "contains indentation"))

(test "pp-jdn: empty children"
  (def data @{:mode :tabbed :children @[]})
  (def result (pp-jdn data))
  (def parsed (parse result))
  (assert-deep= (parsed :children) @[] "empty children round-trip"))

# ===== Round-trip =====

(test "round-trip: serialize then restore recovers tree structure"
  (def a (w "foot" "term1"))
  (def b (w "firefox" "GitHub"))
  (def c (w "foot" "term2"))
  (def group (pool/make-pool :tabbed @[b c] @{:active 1}))
  (def row (pool/make-pool :stack-v @[a group]))
  (def tag (pool/make-pool :scroll @[row] @{:id :main :active-row 0}))
  (def root (pool/make-pool :tabbed @[tag] @{:active 0}))
  (def serialized (serialize @[@{:connector "DP-1" :pool root}]))
  # Create fresh windows
  (def a2 (w "foot" "term1"))
  (def b2 (w "firefox" "GitHub"))
  (def c2 (w "foot" "term2"))
  (def result (restore (parse serialized) @[a2 b2 c2]))
  (def restored-pool (get (get (result :outputs) 0) :pool))
  # Structure check: tabbed > scroll > stack-v > [window, tabbed > [window, window]]
  (assert= (restored-pool :mode) :tabbed)
  (def restored-tag (get (restored-pool :children) 0))
  (assert= (restored-tag :mode) :scroll)
  (assert= (restored-tag :id) :main)
  (def restored-row (get (restored-tag :children) 0))
  (def restored-group (get (restored-row :children) 1))
  (assert= (restored-group :mode) :tabbed)
  (assert= (restored-group :active) 1 "active tab preserved")
  (def leaves (pool/collect-windows restored-pool))
  (assert= (length leaves) 3 "all windows matched"))

(test "round-trip: multiple outputs"
  (def a (w "foot" "~"))
  (def b (w "foot" "~"))
  (def tag1 (pool/make-pool :stack-v @[a] @{:id :main}))
  (def root1 (pool/make-pool :tabbed @[tag1] @{:active 0}))
  (def tag2 (pool/make-pool :stack-v @[b] @{:id :main}))
  (def root2 (pool/make-pool :tabbed @[tag2] @{:active 0}))
  (def serialized (serialize @[@{:connector "DP-1" :pool root1}
                                @{:connector "HDMI-1" :pool root2}]))
  (def a2 (w "foot" "~"))
  (def b2 (w "foot" "~"))
  (def result (restore (parse serialized) @[a2 b2]))
  (assert= (length (result :outputs)) 2 "both outputs restored")
  (assert= (get (get (result :outputs) 0) :connector) "DP-1")
  (assert= (get (get (result :outputs) 1) :connector) "HDMI-1"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
