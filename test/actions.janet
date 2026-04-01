(import ./helper :as t)
(import actions)
(import output)
(import seat)

# ============================================================
# focus-next
# ============================================================

(t/test-start "focus-next: cycles forward")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w1 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/focus-next ctx s)
(t/assert-eq (s :focused) w2 "focus moves to w2")

(t/test-start "focus-next: wraps around")
(put s :focused w3)
(actions/focus-next ctx s)
(t/assert-eq (s :focused) w1 "wraps to w1")

(t/test-start "focus-next: skips floating windows")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1 :float true}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w1 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/focus-next ctx s)
(t/assert-eq (s :focused) w3 "skips float, goes to w3")

(t/test-start "focus-next: skips closed windows")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1 :closed true}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w1 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/focus-next ctx s)
(t/assert-eq (s :focused) w3 "skips closed")

(t/test-start "focus-next: single window stays focused")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def s (t/make-seat {:focused w1 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1] :seats @[s]}))
(actions/focus-next ctx s)
(t/assert-eq (s :focused) w1)

(t/test-start "focus-next: no focused output is noop")
(def s (t/make-seat))
(def ctx (t/make-ctx))
(actions/focus-next ctx s)
(t/assert-falsey (s :focused))

# ============================================================
# focus-prev
# ============================================================

(t/test-start "focus-prev: cycles backward")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w2 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/focus-prev ctx s)
(t/assert-eq (s :focused) w1 "focus moves to w1")

(t/test-start "focus-prev: wraps around")
(put s :focused w1)
(put s :focus-changed nil)
(actions/focus-prev ctx s)
(t/assert-eq (s :focused) w3 "wraps to w3")

# ============================================================
# swap-next
# ============================================================

(t/test-start "swap-next: swaps in windows array")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w1 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/swap-next ctx s)
# w1 and w2 should be swapped in the windows array
(t/assert-eq ((ctx :windows) 0) w2 "w2 now first")
(t/assert-eq ((ctx :windows) 1) w1 "w1 now second")
(t/assert-eq ((ctx :windows) 2) w3 "w3 unchanged")

(t/test-start "swap-next: wraps around")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1}))
(def s (t/make-seat {:focused w2 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2] :seats @[s]}))
(actions/swap-next ctx s)
(t/assert-eq ((ctx :windows) 0) w2 "wrapped swap")
(t/assert-eq ((ctx :windows) 1) w1)

# ============================================================
# swap-prev
# ============================================================

(t/test-start "swap-prev: swaps backward")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1}))
(def w3 (t/make-window 3 {:tag 1}))
(def s (t/make-seat {:focused w2 :focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :windows @[w1 w2 w3] :seats @[s]}))
(actions/swap-prev ctx s)
(t/assert-eq ((ctx :windows) 0) w2)
(t/assert-eq ((ctx :windows) 1) w1)

# ============================================================
# focus-tag / send-to-tag
# ============================================================

(t/test-start "focus-tag: switches output tags")
(def o (t/make-output {:tags @{1 true}}))
(def s (t/make-seat {:focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :seats @[s]}))
(def action (actions/focus-tag 3))
(action ctx s)
(t/assert-truthy ((o :tags) 3) "tag 3 set")
(t/assert-falsey ((o :tags) 1) "tag 1 cleared")

(t/test-start "send-to-tag: moves window to tag")
(def w (t/make-window 1 {:tag 1}))
(def s (t/make-seat {:focused w}))
(def action (actions/send-to-tag 5))
(action (t/make-ctx) s)
(t/assert-eq (w :tag) 5)

(t/report)
