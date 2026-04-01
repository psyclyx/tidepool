(import ./helper :as t)
(import window)

(def config (t/make-config))

# ============================================================
# set-position
# ============================================================

(t/test-start "set-position")
(def w (t/make-window 1))
(window/set-position w 100 200)
(t/assert-eq (w :x) 100)
(t/assert-eq (w :y) 200)

# ============================================================
# propose-dimensions
# ============================================================

(t/test-start "propose-dimensions: subtracts border")
(def w (t/make-window 1))
(window/propose-dimensions w 400 300 config)
# border-width=4, so proposed = max(1, dim - 2*4)
(t/assert-eq (w :proposed-w) 392)
(t/assert-eq (w :proposed-h) 292)

(t/test-start "propose-dimensions: clamps to 1")
(def w (t/make-window 1))
(window/propose-dimensions w 5 5 config)
# 5 - 8 = -3, clamped to 1
(t/assert-eq (w :proposed-w) 1)
(t/assert-eq (w :proposed-h) 1)

(t/test-start "propose-dimensions: zero border")
(def w (t/make-window 1))
(window/propose-dimensions w 400 300 (t/make-config {:border-width 0}))
(t/assert-eq (w :proposed-w) 400)
(t/assert-eq (w :proposed-h) 300)

# ============================================================
# fixed-size?
# ============================================================

(t/test-start "fixed-size?: true when min=max>0")
(def w (t/make-window 1 {:min-w 800 :max-w 800 :min-h 600 :max-h 600}))
(t/assert-truthy (window/fixed-size? w))

(t/test-start "fixed-size?: false when min!=max")
(def w (t/make-window 1 {:min-w 400 :max-w 800 :min-h 300 :max-h 600}))
(t/assert-falsey (window/fixed-size? w))

(t/test-start "fixed-size?: false when zeros")
(def w (t/make-window 1 {:min-w 0 :max-w 0 :min-h 0 :max-h 0}))
(t/assert-falsey (window/fixed-size? w))

(t/test-start "fixed-size?: false when partially set")
(def w (t/make-window 1 {:min-w 800 :max-w 800 :min-h 0 :max-h 0}))
(t/assert-falsey (window/fixed-size? w))

# ============================================================
# tag-output
# ============================================================

(t/test-start "tag-output: finds matching output")
(def o1 (t/make-output {:tags @{1 true}}))
(def o2 (t/make-output {:tags @{2 true}}))
(def w (t/make-window 1 {:tag 2}))
(t/assert-eq (window/tag-output w @[o1 o2]) o2)

(t/test-start "tag-output: returns nil when no match")
(def w (t/make-window 1 {:tag 5}))
(t/assert-falsey (window/tag-output w @[o1 o2]))

# ============================================================
# set-float
# ============================================================

(t/test-start "set-float: sets float and changed flag")
(def w (t/make-window 1))
(window/set-float w true)
(t/assert-truthy (w :float))
(t/assert-truthy (w :float-changed))

# ============================================================
# set-borders
# ============================================================

(t/test-start "set-borders: focused")
(def w (t/make-window 1))
(window/set-borders w :focused config)
(t/assert-eq (w :border-rgb) 0xffffff)
(t/assert-eq (w :border-width) 4)

(t/test-start "set-borders: normal")
(def w (t/make-window 1))
(window/set-borders w :normal config)
(t/assert-eq (w :border-rgb) 0x646464)

(t/test-start "set-borders: urgent")
(def w (t/make-window 1))
(window/set-borders w :urgent config)
(t/assert-eq (w :border-rgb) 0xff0000)

(t/test-start "set-borders: unknown defaults to normal")
(def w (t/make-window 1))
(window/set-borders w :bogus config)
(t/assert-eq (w :border-rgb) 0x646464)

# ============================================================
# compute-visibility
# ============================================================

(t/test-start "compute-visibility: visible on active tag")
(def o1 (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 2}))
(window/compute-visibility @[o1] @[w1 w2])
(t/assert-truthy (w1 :visible))
(t/assert-falsey (w2 :visible))

(t/test-start "compute-visibility: closed windows not visible")
(def o1 (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1 :closed true}))
(window/compute-visibility @[o1] @[w1])
(t/assert-falsey (w1 :visible))

(t/test-start "compute-visibility: layout-hidden not visible")
(def o1 (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1 :layout-hidden true}))
(window/compute-visibility @[o1] @[w1])
(t/assert-falsey (w1 :visible))

(t/test-start "compute-visibility: multi-output union")
(def o1 (t/make-output {:tags @{1 true}}))
(def o2 (t/make-output {:tags @{2 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 2}))
(def w3 (t/make-window 3 {:tag 3}))
(window/compute-visibility @[o1 o2] @[w1 w2 w3])
(t/assert-truthy (w1 :visible))
(t/assert-truthy (w2 :visible))
(t/assert-falsey (w3 :visible))

# ============================================================
# swap
# ============================================================

(t/test-start "swap: swaps window positions in array")
(def w1 (t/make-window 1))
(def w2 (t/make-window 2))
(def w3 (t/make-window 3))
(def ctx (t/make-ctx {:windows @[w1 w2 w3]}))
(window/swap ctx w1 w3)
(t/assert-eq ((ctx :windows) 0) w3)
(t/assert-eq ((ctx :windows) 2) w1)
(t/assert-eq ((ctx :windows) 1) w2 "middle unchanged")

(t/report)
