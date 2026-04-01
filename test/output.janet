(import ./helper :as t)
(import output)

# ============================================================
# usable-area
# ============================================================

(t/test-start "usable-area: no exclusive zone")
(def o (t/make-output))
(def a (output/usable-area o))
(t/assert-eq (a :x) 0)
(t/assert-eq (a :y) 0)
(t/assert-eq (a :w) 1920)
(t/assert-eq (a :h) 1080)

(t/test-start "usable-area: with exclusive zone")
(def o (t/make-output {:non-exclusive-area [0 30 1920 1050]}))
(def a (output/usable-area o))
(t/assert-eq (a :x) 0)
(t/assert-eq (a :y) 30)
(t/assert-eq (a :w) 1920)
(t/assert-eq (a :h) 1050)

# ============================================================
# visible
# ============================================================

(t/test-start "visible: filters by tag")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 2}))
(def w3 (t/make-window 3 {:tag 1}))
(def result (output/visible o @[w1 w2 w3]))
(t/assert-eq (length result) 2)

(t/test-start "visible: excludes closing windows")
(def o (t/make-output {:tags @{1 true}}))
(def w1 (t/make-window 1 {:tag 1}))
(def w2 (t/make-window 2 {:tag 1 :closing true}))
(def result (output/visible o @[w1 w2]))
(t/assert-eq (length result) 1)

# ============================================================
# build-tag-map
# ============================================================

(t/test-start "build-tag-map: maps tags to outputs")
(def o1 (t/make-output {:tags @{1 true 2 true}}))
(def o2 (t/make-output {:tags @{3 true}}))
(def m (output/build-tag-map @[o1 o2]))
(t/assert-eq (m 1) o1)
(t/assert-eq (m 2) o1)
(t/assert-eq (m 3) o2)
(t/assert-falsey (m 4))

# ============================================================
# rgb-to-u32-rgba
# ============================================================

(t/test-start "rgb-to-u32-rgba: white")
(def [r g b a] (output/rgb-to-u32-rgba 0xffffff))
(t/assert-eq r 0xffffffff)
(t/assert-eq g 0xffffffff)
(t/assert-eq b 0xffffffff)
(t/assert-eq a 0xffffffff)

(t/test-start "rgb-to-u32-rgba: black")
(def [r g b a] (output/rgb-to-u32-rgba 0x000000))
(t/assert-eq r 0)
(t/assert-eq g 0)
(t/assert-eq b 0)
(t/assert-eq a 0xffffffff)

(t/test-start "rgb-to-u32-rgba: red")
(def [r g b a] (output/rgb-to-u32-rgba 0xff0000))
(t/assert-eq r 0xffffffff)
(t/assert-eq g 0)
(t/assert-eq b 0)
(t/assert-eq a 0xffffffff)

(t/test-start "rgb-to-u32-rgba: arbitrary color")
(def [r g b a] (output/rgb-to-u32-rgba 0x646464))
# 0x64 = 100, scaled: 100 * (0xffffffff / 0xff) = 100 * 16843009 = 1684300900
(t/assert-eq r 1684300900)
(t/assert-eq g 1684300900)
(t/assert-eq b 1684300900)

# ============================================================
# set-tags
# ============================================================

(t/test-start "set-tags: replaces tags")
(def o (t/make-output {:tags @{1 true 2 true}}))
(output/set-tags o {3 true 4 true})
(t/assert-falsey ((o :tags) 1))
(t/assert-falsey ((o :tags) 2))
(t/assert-truthy ((o :tags) 3))
(t/assert-truthy ((o :tags) 4))

(t/report)
