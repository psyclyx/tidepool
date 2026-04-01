(import ./helper :as t)
(import layout)

(def config (t/make-config))
(def area {:x 0 :y 0 :w 1920 :h 1080})
(def params @{:main-ratio 0.55 :main-count 1})

# --- Empty ---

(t/test-start "layout: no windows")
(def r (layout/master-stack area @[] params config))
(t/assert-eq (length r) 0)

# --- Single window fills area ---

(t/test-start "layout: single window")
(def w1 (t/make-window 1))
(def r (layout/master-stack area @[w1] params config))
(t/assert-eq (length r) 1)
# Should fill total area minus padding on all sides
# total-w = 1920 - 2*4 = 1912, total-h = 1080 - 2*4 = 1072
# single column: col-x=4, col-w=1912
# cell: x = 0 + 4 + 8 = 12, y = 0 + 4 + 0 + 8 = 12
# w = 1912 - 16 = 1896, h = 1072 - 16 = 1056
(t/assert-eq ((r 0) :x) 12)
(t/assert-eq ((r 0) :y) 12)
(t/assert-eq ((r 0) :w) 1896)
(t/assert-eq ((r 0) :h) 1056)
(t/assert-eq ((r 0) :window) w1)

# --- Two windows: master + stack ---

(t/test-start "layout: two windows master-stack")
(def w2 (t/make-window 2))
(def r (layout/master-stack area @[w1 w2] params config))
(t/assert-eq (length r) 2)
# main-w = round(1912 * 0.55) = 1052, side-w = 1912 - 1052 = 860
# Master: x = 0+4+8 = 12, w = 1052-16 = 1036
# Stack:  x = 0+4+1052+8 = 1064, w = 860-16 = 844
(t/assert-eq ((r 0) :x) 12 "master x")
(t/assert-eq ((r 0) :w) 1036 "master w")
(t/assert-eq ((r 1) :x) 1064 "stack x")
(t/assert-eq ((r 1) :w) 844 "stack w")
# Both should have full height
(t/assert-eq ((r 0) :h) 1056 "master h")
(t/assert-eq ((r 1) :h) 1056 "stack h")

# --- Three windows: 1 master + 2 stack ---

(t/test-start "layout: three windows")
(def w3 (t/make-window 3))
(def r (layout/master-stack area @[w1 w2 w3] params config))
(t/assert-eq (length r) 3)
# Stack splits vertically: total-h=1072, 2 cells: 536 each
# Stack window heights: 536 - 16 = 520
(t/assert-eq ((r 1) :h) 520 "stack1 h")
(t/assert-eq ((r 2) :h) 520 "stack2 h")
# Stack y positions should differ
(t/assert-truthy (< ((r 1) :y) ((r 2) :y)) "stack ordering")

# --- main-count > window count ---

(t/test-start "layout: main-count exceeds windows")
(def big-main @{:main-ratio 0.55 :main-count 5})
(def r (layout/master-stack area @[w1 w2] big-main config))
(t/assert-eq (length r) 2)
# All windows go into main column (side-count = 0)
# Both should have same x
(t/assert-eq ((r 0) :x) ((r 1) :x) "same column x")

# --- Remainder distribution ---

(t/test-start "layout: height remainder distribution")
# 3 windows in a 100-high area: 100/3 = 33 rem 1
(def small-area {:x 0 :y 0 :w 200 :h 100})
(def small-params @{:main-ratio 0.55 :main-count 5})  # all main
(def small-config (t/make-config {:outer-padding 0 :inner-padding 0}))
(def r (layout/master-stack small-area @[w1 w2 w3] small-params small-config))
# First window gets +1 pixel from remainder
(t/assert-eq ((r 0) :h) 34 "first gets remainder")
(t/assert-eq ((r 1) :h) 33 "second normal")
(t/assert-eq ((r 2) :h) 33 "third normal")

# --- Zero-size area ---

(t/test-start "layout: zero-size area")
(def zero-area {:x 0 :y 0 :w 0 :h 0})
(def r (layout/master-stack zero-area @[w1] params config))
(t/assert-eq (length r) 1)

# --- Custom main-ratio ---

(t/test-start "layout: custom main-ratio 0.7")
(def wide-params @{:main-ratio 0.7 :main-count 1})
(def r (layout/master-stack area @[w1 w2] wide-params config))
# main-w = round(1912 * 0.7) = 1338
(t/assert-eq ((r 0) :w) (- 1338 (* 2 8)) "70% master width")

(t/report)
