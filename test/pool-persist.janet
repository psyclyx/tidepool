# Tests for pool persistence.
# Serialize tag pools to JDN, restore from JDN with window matching.

(import ../src/pool)

(import ../src/pool/persist)

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
  (def tag (pool/make-pool :scroll @[row] @{:id 1 :active-row 0}))
  (def output @{:connector "DP-1" :tag-pools @{1 tag} :active-tag 1})
  (def result (persist/serialize @[output]))
  (assert (string? result) "result is a string")
  (def parsed (parse result))
  (assert (parsed :outputs) "has :outputs key")
  (def out (get (parsed :outputs) 0))
  (assert= (out :connector) "DP-1")
  (assert= (out :active-tag) 1)
  (def tp (get (out :tag-pools) 1))
  (assert= (tp :id) 1)
  (assert= (tp :mode) :scroll)
  (def row-p (get (tp :children) 0))
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
  (def tag (pool/make-pool :scroll @[row] @{:id 1 :active-row 0}))
  (def result (persist/serialize @[@{:connector "DP-1" :tag-pools @{1 tag} :active-tag 1}]))
  (def parsed (parse result))
  (def tp (get (get (get (parsed :outputs) 0) :tag-pools) 1))
  (def row-p (get (tp :children) 0))
  (def grp (get (row-p :children) 0))
  (assert= (grp :ratio) 0.6 "ratio preserved")
  (assert= (get (grp :weights) 0) 2.0 "weight preserved"))

(test "serialize: strips transient state"
  (def a (w "foot"))
  (put a :parent @{})
  (put a :x 100)
  (put a :y 200)
  (def tag (pool/make-pool :scroll @[(pool/make-pool :stack-v @[a])]
            @{:id 1 :active-row 0 :scroll-offset-x @{0 150}}))
  (def result (persist/serialize @[@{:connector "DP-1" :tag-pools @{1 tag} :active-tag 1}]))
  (def parsed (parse result))
  (def tp (get (get (get (parsed :outputs) 0) :tag-pools) 1))
  (def sox (tp :scroll-offset-x))
  (assert (or (nil? sox) (= (get sox 0) 0) (empty? sox))
          "scroll offset zeroed"))

(test "serialize: zeroes scroll-offset-x"
  (def a (w "foot"))
  (def row (pool/make-pool :stack-v @[a]))
  (def tag (pool/make-pool :scroll @[row]
            @{:id 1 :active-row 0 :scroll-offset-x @{0 500}}))
  (def result (persist/serialize @[@{:connector "DP-1" :tag-pools @{1 tag} :active-tag 1}]))
  (def parsed (parse result))
  (def tp (get (get (get (parsed :outputs) 0) :tag-pools) 1))
  (when-let [sox (tp :scroll-offset-x)]
    (assert (or (nil? (get sox 0)) (= (get sox 0) 0))
            "scroll offset zeroed on save")))

# ===== restore =====

(test "restore: legacy format with :pool key"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"} @{:app-id "firefox" :title "GitHub"}]}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def firefox (w "firefox" "GitHub"))
  (def result (persist/restore (parse saved) @[foot firefox]))
  (def out (get (result :outputs) 0))
  (assert= (out :connector) "DP-1")
  # Legacy restore puts tag children into tag-pools
  (def tp (out :tag-pools))
  (assert (> (length tp) 0) "tag-pools populated from legacy")
  # Find the tag pool that has windows
  (var total-leaves 0)
  (eachp [_ p] tp
    (+= total-leaves (length (pool/collect-windows p))))
  (assert= total-leaves 2 "windows matched"))

(test "restore: unmatched tree leaves are pruned"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"} @{:app-id "emacs" :title "scratch"}]}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def result (persist/restore (parse saved) @[foot]))
  (var total 0)
  (eachp [_ p] (get (get (result :outputs) 0) :tag-pools)
    (+= total (length (pool/collect-windows p))))
  (assert= total 1 "only foot in tree"))

(test "restore: unmatched windows appended to first pool"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:app-id "foot" :title "~"}]}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def extra (w "alacritty" "bash"))
  (def result (persist/restore (parse saved) @[foot extra]))
  (var total 0)
  (eachp [_ p] (get (get (result :outputs) 0) :tag-pools)
    (+= total (length (pool/collect-windows p))))
  (assert= total 2 "unmatched window appended"))

(test "restore: duplicate app-id+title matched in order"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :stack-v :id :main :children @[@{:app-id "foot" :title "~"} @{:app-id "foot" :title "~"} @{:app-id "foot" :title "~"}]}]}}]}`)
  (def t1 (w "foot" "~"))
  (def t2 (w "foot" "~"))
  (def t3 (w "foot" "~"))
  (def result (persist/restore (parse saved) @[t1 t2 t3]))
  (var total 0)
  (eachp [_ p] (get (get (result :outputs) 0) :tag-pools)
    (+= total (length (pool/collect-windows p))))
  (assert= total 3 "all 3 terminals matched"))

(test "restore: parent pointers are set on restored tree"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :stack-v :id :main :children @[@{:app-id "foot" :title "~"} @{:app-id "firefox" :title "Docs"}]}]}}]}`)
  (def foot (w "foot" "~"))
  (def firefox (w "firefox" "Docs"))
  (def result (persist/restore (parse saved) @[foot firefox]))
  (assert (foot :parent) "foot has parent")
  (assert (firefox :parent) "firefox has parent")
  (assert= (foot :parent) (firefox :parent) "same parent (stack-v)"))

(test "restore: empty pool after pruning"
  (def saved `@{:outputs @[@{:connector "DP-1" :pool @{:mode :tabbed :active 0 :children @[@{:mode :scroll :id :main :active-row 0 :children @[@{:mode :stack-v :children @[@{:mode :stack-v :children @[@{:app-id "gone" :title "x"}]}]}]}]}}]}`)
  (def result (persist/restore (parse saved) @[]))
  (def out (get (result :outputs) 0))
  (assert (out :tag-pools) "tag-pools exists"))

# ===== pp-jdn =====

(test "pp-jdn: produces valid parseable JDN"
  (def data @{:mode :tabbed :active 0 :children @[@{:app-id "foot" :title "~"}]})
  (def result (persist/pp-jdn data))
  (assert (string? result) "result is string")
  (def parsed (parse result))
  (assert= (parsed :mode) :tabbed "round-trips"))

(test "pp-jdn: nested structure is indented"
  (def data @{:mode :tabbed :children @[@{:mode :stack-v :children @[@{:app-id "a" :title "b"}]}]})
  (def result (persist/pp-jdn data))
  (assert (string/find "\n" result) "contains newlines")
  (assert (string/find "  " result) "contains indentation"))

(test "pp-jdn: empty children"
  (def data @{:mode :tabbed :children @[]})
  (def result (persist/pp-jdn data))
  (def parsed (parse result))
  (assert-deep= (parsed :children) @[] "empty children round-trip"))

# ===== Round-trip =====

(test "round-trip: serialize then restore recovers tree structure"
  (def a (w "foot" "term1"))
  (def b (w "firefox" "GitHub"))
  (def c (w "foot" "term2"))
  (def group (pool/make-pool :tabbed @[b c] @{:active 1}))
  (def row (pool/make-pool :stack-v @[a group]))
  (def tag (pool/make-pool :scroll @[row] @{:id 1 :active-row 0}))
  (def serialized (persist/serialize @[@{:connector "DP-1" :tag-pools @{1 tag} :active-tag 1}]))
  (def a2 (w "foot" "term1"))
  (def b2 (w "firefox" "GitHub"))
  (def c2 (w "foot" "term2"))
  (def result (persist/restore (parse serialized) @[a2 b2 c2]))
  (def out (get (result :outputs) 0))
  (assert= (out :active-tag) 1 "active-tag preserved")
  (def restored-tag (get (out :tag-pools) 1))
  (assert= (restored-tag :mode) :scroll)
  (assert= (restored-tag :id) 1)
  (def restored-row (get (restored-tag :children) 0))
  (def restored-group (get (restored-row :children) 1))
  (assert= (restored-group :mode) :tabbed)
  (assert= (restored-group :active) 1 "active tab preserved")
  (def leaves (pool/collect-windows restored-tag))
  (assert= (length leaves) 3 "all windows matched"))

(test "round-trip: multiple outputs"
  (def a (w "foot" "~"))
  (def b (w "foot" "~"))
  (def tag1 (pool/make-pool :stack-v @[a] @{:id 1}))
  (def tag2 (pool/make-pool :stack-v @[b] @{:id 1}))
  (def serialized (persist/serialize @[@{:connector "DP-1" :tag-pools @{1 tag1} :active-tag 1}
                                @{:connector "HDMI-1" :tag-pools @{1 tag2} :active-tag 1}]))
  (def a2 (w "foot" "~"))
  (def b2 (w "foot" "~"))
  (def result (persist/restore (parse serialized) @[a2 b2]))
  (assert= (length (result :outputs)) 2 "both outputs restored")
  (assert= (get (get (result :outputs) 0) :connector) "DP-1")
  (assert= (get (get (result :outputs) 1) :connector) "HDMI-1"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
