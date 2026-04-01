(import ./helper :as t)
(import state)

# ============================================================
# remove-destroyed
# ============================================================

(t/test-start "remove-destroyed: empty array")
(def arr @[])
(state/remove-destroyed arr)
(t/assert-eq (length arr) 0)

(t/test-start "remove-destroyed: nothing to remove")
(def arr @[@{:name "a"} @{:name "b"}])
(state/remove-destroyed arr)
(t/assert-eq (length arr) 2)

(t/test-start "remove-destroyed: removes flagged entries")
(def arr @[@{:name "a"} @{:name "b" :pending-destroy true} @{:name "c"}])
(state/remove-destroyed arr)
(t/assert-eq (length arr) 2)
(t/assert-eq ((arr 0) :name) "a")
(t/assert-eq ((arr 1) :name) "c")

(t/test-start "remove-destroyed: removes all")
(def arr @[@{:pending-destroy true} @{:pending-destroy true}])
(state/remove-destroyed arr)
(t/assert-eq (length arr) 0)

(t/test-start "remove-destroyed: consecutive flagged")
(def arr @[@{:name "a" :pending-destroy true}
           @{:name "b" :pending-destroy true}
           @{:name "c"}])
(state/remove-destroyed arr)
(t/assert-eq (length arr) 1)
(t/assert-eq ((arr 0) :name) "c")

# ============================================================
# reconcile-tags
# ============================================================

(t/test-start "reconcile-tags: single output gets tag")
(def o1 (t/make-output {:tags @{1 true}}))
(def ctx (t/make-ctx {:outputs @[o1] :seats @[]}))
(state/reconcile-tags ctx)
(t/assert-eq (o1 :primary-tag) 1)

(t/test-start "reconcile-tags: two outputs unique tags")
(def o1 (t/make-output {:tags @{1 true}}))
(def o2 (t/make-output {:tags @{2 true}}))
(def ctx (t/make-ctx {:outputs @[o1 o2] :seats @[]}))
(state/reconcile-tags ctx)
(t/assert-eq (o1 :primary-tag) 1)
(t/assert-eq (o2 :primary-tag) 2)

(t/test-start "reconcile-tags: focused output wins conflict")
(def o1 (t/make-output {:tags @{1 true}}))
(def o2 (t/make-output {:tags @{1 true}}))
(def s (t/make-seat {:focused-output o1}))
(def ctx (t/make-ctx {:outputs @[o1 o2] :seats @[s]}))
(state/reconcile-tags ctx)
# o1 should keep tag 1, o2 should lose it
(t/assert-truthy ((o1 :tags) 1) "focused keeps tag")
(t/assert-falsey ((o2 :tags) 1) "other loses tag")

(t/test-start "reconcile-tags: orphaned tag assigned to empty output")
(def o1 (t/make-output {:tags @{1 true}}))
(def o2 (t/make-output {:tags @{}}))
(def w (t/make-window 1 {:tag 2}))
(def ctx (t/make-ctx {:outputs @[o1 o2] :windows @[w] :seats @[]}))
(state/reconcile-tags ctx)
# Tag 2 from window should be assigned to empty o2
(t/assert-truthy ((o2 :tags) 2) "orphan tag assigned")

(t/test-start "reconcile-tags: primary-tag picks minimum")
(def o1 (t/make-output {:tags @{3 true 5 true 1 true}}))
(def ctx (t/make-ctx {:outputs @[o1] :seats @[]}))
(state/reconcile-tags ctx)
(t/assert-eq (o1 :primary-tag) 1)

(t/test-start "reconcile-tags: empty tags falls back to 1")
(def o1 (t/make-output {:tags @{}}))
(def ctx (t/make-ctx {:outputs @[o1] :seats @[]}))
(state/reconcile-tags ctx)
(t/assert-eq (o1 :primary-tag) 1)

# ============================================================
# init
# ============================================================

(t/test-start "init: sets all required keys")
(def ctx (state/init @{}))
(t/assert-truthy (ctx :config) "has config")
(t/assert-truthy (ctx :outputs) "has outputs")
(t/assert-truthy (ctx :windows) "has windows")
(t/assert-truthy (ctx :seats) "has seats")
(t/assert-truthy (ctx :render-order) "has render-order")
(t/assert-truthy (ctx :tag-layouts) "has tag-layouts")
(t/assert-truthy (ctx :tag-focus) "has tag-focus")

(t/report)
