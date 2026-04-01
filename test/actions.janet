(import ./helper :as t)
(import actions)
(import output)
(import tree)
(import state)

# ============================================================
# Re-exports exist
# ============================================================

(t/test-start "re-exports: directional actions exist")
(t/assert-truthy actions/focus-left "focus-left")
(t/assert-truthy actions/focus-right "focus-right")
(t/assert-truthy actions/focus-up "focus-up")
(t/assert-truthy actions/focus-down "focus-down")
(t/assert-truthy actions/swap-left "swap-left")
(t/assert-truthy actions/swap-right "swap-right")
(t/assert-truthy actions/close-focused "close-focused")
(t/assert-truthy actions/toggle-insert-mode "toggle-insert-mode")
(t/assert-truthy actions/cycle-width-forward "cycle-width-forward")

# ============================================================
# focus-tag
# ============================================================

(t/test-start "focus-tag: switches output tags")
(def o (t/make-output {:tags @{1 true}}))
(def s (t/make-seat {:focused-output o}))
(def ctx (t/make-ctx {:outputs @[o] :seats @[s]}))
(def action (actions/focus-tag 3))
(action ctx s)
(t/assert-truthy ((o :tags) 3) "tag 3 set")
(t/assert-falsey ((o :tags) 1) "tag 1 cleared")

(t/test-start "focus-tag: no focused output is noop")
(def s2 (t/make-seat))
(def action2 (actions/focus-tag 2))
(action2 (t/make-ctx) s2)
(t/assert-falsey (s2 :focused-output))

# ============================================================
# send-to-tag
# ============================================================

(t/test-start "send-to-tag: moves window to tag")
(def w (t/make-window 1 {:tag 1}))
(def leaf (tree/leaf w))
(put w :tree-leaf leaf)
(def col (tree/container :split :horizontal @[leaf]))
(def tag @{:columns @[col] :camera 0 :focused-id w :insert-mode :sibling})
(def ctx (t/make-ctx {:tags @{1 tag} :windows @[w]}))
(def s (t/make-seat {:focused w :focused-output (t/make-output {:tags @{1 true}})}))
(def action (actions/send-to-tag 5))
(action ctx s)
(t/assert-eq (w :tag) 5 "window moved to tag 5")
(t/assert-truthy (get-in ctx [:tags 5]) "tag 5 created")

(t/test-start "send-to-tag: same tag is noop")
(def w2 (t/make-window 2 {:tag 3}))
(def leaf2 (tree/leaf w2))
(put w2 :tree-leaf leaf2)
(def s2 (t/make-seat {:focused w2}))
(def action2 (actions/send-to-tag 3))
(action2 (t/make-ctx) s2)
(t/assert-eq (w2 :tag) 3 "tag unchanged")

(t/test-start "send-to-tag: no focused window is noop")
(def s3 (t/make-seat))
(def action3 (actions/send-to-tag 2))
(action3 (t/make-ctx) s3)
(t/assert-falsey (s3 :focused))

(t/report)
