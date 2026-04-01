(import ./helper :as t)
(import scroll)
(import tree)

# Standard test config
(def pw 8)    # peek-width
(def bw 4)    # border-width
(def ig 8)    # inner-gap
(def og 4)    # outer-gap
(def output-w 1920)
(def output-h 1080)

# --- base-width ---

(t/test-start "base-width: standard config")
(def base-w (scroll/base-width output-w pw bw ig og))
# output-w - 2*(og + pw + bw + ig) = 1920 - 2*(4+8+4+8) = 1920 - 48 = 1872
(t/assert-eq base-w 1872)

(t/test-start "base-width: larger peek")
(def base-w2 (scroll/base-width 1920 32 4 8 4))
# 1920 - 2*(4+32+4+8) = 1920 - 96 = 1824
(t/assert-eq base-w2 1824)

(t/test-start "base-width: tiny output clamps to 1")
(t/assert-eq (scroll/base-width 10 8 4 8 4) 1)

# --- peek-total ---

(t/test-start "peek-total")
(t/assert-eq (scroll/peek-total 8 4) 12)
(t/assert-eq (scroll/peek-total 32 4) 36)

# --- node-pixel-width ---

(t/test-start "node-pixel-width: 100%")
(t/assert-eq (scroll/node-pixel-width 1.0 1872) 1872)

(t/test-start "node-pixel-width: 50%")
(t/assert-eq (scroll/node-pixel-width 0.5 1872) 936)

(t/test-start "node-pixel-width: two 50% = one 100%")
(t/assert-eq (* 2 (scroll/node-pixel-width 0.5 1872))
             (scroll/node-pixel-width 1.0 1872))

# --- virtual-positions ---

(t/test-start "virtual-positions: single column")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 1.0))
(def vp (scroll/virtual-positions @[l1] 1872 og ig))
(t/assert-eq (length vp) 1)
(t/assert-eq ((vp 0) :vx) 4 "starts at outer-gap")
(t/assert-eq ((vp 0) :vw) 1872)

(t/test-start "virtual-positions: two columns")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 0.5))
(def l2 (tree/leaf @{:wid 2} 0.5))
(def vp (scroll/virtual-positions @[l1 l2] 1872 og ig))
(t/assert-eq (length vp) 2)
(t/assert-eq ((vp 0) :vx) 4)
(t/assert-eq ((vp 0) :vw) 936)
(t/assert-eq ((vp 1) :vx) (+ 4 936 8) "second starts after first + gap")
(t/assert-eq ((vp 1) :vw) 936)

(t/test-start "virtual-positions: empty")
(def vp (scroll/virtual-positions @[] 1872 og ig))
(t/assert-eq (length vp) 0)

# --- virtual-total ---

(t/test-start "virtual-total: single column")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 1.0))
(def vp (scroll/virtual-positions @[l1] 1872 og ig))
# og + 1872 + og = 4 + 1872 + 4 = 1880
(t/assert-eq (scroll/virtual-total vp og) 1880)

(t/test-start "virtual-total: two 50% columns")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 0.5))
(def l2 (tree/leaf @{:wid 2} 0.5))
(def vp (scroll/virtual-positions @[l1 l2] 1872 og ig))
# og + 936 + ig + 936 + og = 4 + 936 + 8 + 936 + 4 = 1888
(t/assert-eq (scroll/virtual-total vp og) 1888)

(t/test-start "virtual-total: empty")
(t/assert-eq (scroll/virtual-total @[] og) 8)

# --- camera-update ---

(def pt (scroll/peek-total pw bw))

(t/test-start "camera: single column, no scrolling needed")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 1.0))
(def vp (scroll/virtual-positions @[l1] 1872 og ig))
(def cam (scroll/camera-update 0 output-w vp 0 pt og ig))
(t/assert-eq cam 0 "no need to scroll")

(t/test-start "camera: focus first of three, snaps to 0")
(tree/reset-ids)
(def cols (seq [i :range [0 3]] (tree/leaf @{:wid i} 1.0)))
(def vp (scroll/virtual-positions cols 1872 og ig))
(def cam (scroll/camera-update 999 output-w vp 0 pt og ig))
(t/assert-eq cam 0 "first column, camera at start")

(t/test-start "camera: focus middle of three, scrolls to show it")
(tree/reset-ids)
(def cols (seq [i :range [0 3]] (tree/leaf @{:wid i} 1.0)))
(def vp (scroll/virtual-positions cols 1872 og ig))
# Starting from cam=0, focusing column 1
(def cam (scroll/camera-update 0 output-w vp 1 pt og ig))
# needed-left = col1.vx - ig - pt - og = 1884 - 8 - 12 - 4 = 1860
# needed-right = col1.vx + col1.vw + ig + pt + og = 1884+1872+8+12+4 = 3780
# needed-span = 3780 - 1860 = 1920 (exactly output-w!)
(t/assert-eq cam 1860 "scrolls to show focused + peek")

(t/test-start "camera: focus last of three")
(tree/reset-ids)
(def cols (seq [i :range [0 3]] (tree/leaf @{:wid i} 1.0)))
(def vp (scroll/virtual-positions cols 1872 og ig))
(def cam (scroll/camera-update 0 output-w vp 2 pt og ig))
# Last column: no right neighbor
# needed-left = col2.vx - ig - pt - og = 3764 - 8 - 12 - 4 = 3740
# needed-right = col2.vx + col2.vw + og = 3764 + 1872 + 4 = 5640
# needed-span = 5640 - 3740 = 1900 < 1920
# cam_x + output_w < needed_right: new_cam = 5640 - 1920 = 3720
(def vtotal (scroll/virtual-total vp og))
(def max-cam (max 0 (- vtotal output-w)))
(t/assert-eq cam max-cam "scrolls to end")

(t/test-start "camera: minimum scroll — already visible, don't move")
(tree/reset-ids)
(def cols (seq [i :range [0 3]] (tree/leaf @{:wid i} 1.0)))
(def vp (scroll/virtual-positions cols 1872 og ig))
# If we're already at the right position for col 1, don't move
(def cam (scroll/camera-update 1860 output-w vp 1 pt og ig))
(t/assert-eq cam 1860 "already in position")

(t/test-start "camera: everything fits, no scroll")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 0.3))
(def l2 (tree/leaf @{:wid 2} 0.3))
(def vp (scroll/virtual-positions @[l1 l2] 1872 og ig))
(def cam (scroll/camera-update 0 output-w vp 0 pt og ig))
(t/assert-eq cam 0 "all fits, no scroll")

(t/test-start "camera: empty columns")
(def cam (scroll/camera-update 0 output-w @[] nil pt og ig))
(t/assert-eq cam 0)

(t/test-start "camera: oversized column gets centered")
(tree/reset-ids)
(def big (tree/leaf @{:wid 1} 2.0))
(def vp (scroll/virtual-positions @[big] 1872 og ig))
# Column is 3744px, output is 1920. Center it.
# center = (4 + 3744/2) - 1920/2 = 1876 - 960 = 916
(def cam (scroll/camera-update 0 output-w vp 0 pt og ig))
# vtotal = 4 + 3744 + 4 = 3752, max-cam = 3752 - 1920 = 1832
# centered cam = 4 + 3744/2 - 1920/2 = 916, clamped to [0, 1832]
(t/assert-eq cam 916 "centered oversized column")

# --- screen-x ---

(t/test-start "screen-x: basic")
(t/assert-eq (scroll/screen-x 100 50 0) 50)
(t/assert-eq (scroll/screen-x 100 0 0) 100)
(t/assert-eq (scroll/screen-x 100 100 0) 0)

(t/test-start "screen-x: with output offset")
(t/assert-eq (scroll/screen-x 100 50 1920) 1970)

# --- clip-rect ---

(t/test-start "clip-rect: fully visible, returns nil")
(def clip (scroll/clip-rect 100 800 0 600 0 0 1920 1080))
(t/assert-eq clip nil)

(t/test-start "clip-rect: clipped on left")
(def clip (scroll/clip-rect -100 800 0 600 0 0 1920 1080))
(t/assert-eq (clip :clip-x) 100)
(t/assert-eq (clip :clip-y) 0)
(t/assert-eq (clip :clip-w) 700)
(t/assert-eq (clip :clip-h) 600)

(t/test-start "clip-rect: clipped on right")
(def clip (scroll/clip-rect 1500 800 0 600 0 0 1920 1080))
(t/assert-eq (clip :clip-x) 0)
(t/assert-eq (clip :clip-w) 420)

(t/test-start "clip-rect: clipped both sides")
(def clip (scroll/clip-rect -100 2200 0 600 0 0 1920 1080))
(t/assert-eq (clip :clip-x) 100)
(t/assert-eq (clip :clip-w) 1920)

# --- visible? ---

(t/test-start "visible?: fully on screen")
(t/assert-truthy (scroll/visible? 100 800 0 1920))

(t/test-start "visible?: partially left")
(t/assert-truthy (scroll/visible? -100 800 0 1920))

(t/test-start "visible?: fully off left")
(t/assert-falsey (scroll/visible? -800 800 0 1920))

(t/test-start "visible?: fully off right")
(t/assert-falsey (scroll/visible? 1920 800 0 1920))

(t/test-start "visible?: just touching right edge")
(t/assert-falsey (scroll/visible? 1920 800 0 1920) "at edge = not visible")

# --- layout-node ---

(t/test-start "layout-node: single leaf")
(tree/reset-ids)
(def w1 @{:wid 1})
(def l1 (tree/leaf w1))
(def result (scroll/layout-node l1 {:x 10 :y 20 :w 800 :h 600} ig bw))
(t/assert-eq (length result) 1)
(t/assert-is ((result 0) :window) w1)
(t/assert-eq ((result 0) :x) 10)
(t/assert-eq ((result 0) :y) 20)
(t/assert-eq ((result 0) :w) 800)
(t/assert-eq ((result 0) :h) 600)

(t/test-start "layout-node: vertical split, 2 children")
(tree/reset-ids)
(def w1 @{:wid 1})
(def w2 @{:wid 2})
(def l1 (tree/leaf w1))
(def l2 (tree/leaf w2))
(def c (tree/container :split :vertical @[l1 l2]))
(def result (scroll/layout-node c {:x 0 :y 0 :w 800 :h 600} ig bw))
(t/assert-eq (length result) 2)
# total gap = 8 * 1 = 8, usable-h = 592, cell-h = 296
(t/assert-eq ((result 0) :w) 800)
(t/assert-eq ((result 0) :h) 296)
(t/assert-eq ((result 0) :y) 0)
(t/assert-eq ((result 1) :y) 304 "second child after gap")
(t/assert-eq ((result 1) :h) 296)

(t/test-start "layout-node: horizontal split, 2 children")
(tree/reset-ids)
(def w1 @{:wid 1})
(def w2 @{:wid 2})
(def l1 (tree/leaf w1))
(def l2 (tree/leaf w2))
(def c (tree/container :split :horizontal @[l1 l2]))
(def result (scroll/layout-node c {:x 0 :y 0 :w 800 :h 600} ig bw))
(t/assert-eq (length result) 2)
# total gap = 8, usable-w = 792, cell-w = 396
(t/assert-eq ((result 0) :h) 600)
(t/assert-eq ((result 0) :w) 396)
(t/assert-eq ((result 0) :x) 0)
(t/assert-eq ((result 1) :x) 404 "second child after gap")
(t/assert-eq ((result 1) :w) 396)

(t/test-start "layout-node: 3 children, remainder distribution")
(tree/reset-ids)
(def leaves (seq [i :range [0 3]] (tree/leaf @{:wid i})))
(def c (tree/container :split :vertical leaves))
(def result (scroll/layout-node c {:x 0 :y 0 :w 100 :h 100} ig bw))
(t/assert-eq (length result) 3)
# total gap = 16, usable-h = 84, cell-h = 28, remainder = 0
(t/assert-eq ((result 0) :h) 28)
(t/assert-eq ((result 1) :h) 28)
(t/assert-eq ((result 2) :h) 28)

(t/test-start "layout-node: tabbed shows only active child")
(tree/reset-ids)
(def w1 @{:wid 1})
(def w2 @{:wid 2})
(def l1 (tree/leaf w1))
(def l2 (tree/leaf w2))
(def tb (tree/container :tabbed :horizontal @[l1 l2]))
(def result (scroll/layout-node tb {:x 0 :y 0 :w 800 :h 600} ig bw))
(t/assert-eq (length result) 1)
(t/assert-is ((result 0) :window) w1 "active=0 shows first")
(t/assert-eq ((result 0) :w) 800 "gets full rect")

(t/test-start "layout-node: nested split in split")
(tree/reset-ids)
(def wa @{:wid 1})
(def wb @{:wid 2})
(def wc @{:wid 3})
(def la (tree/leaf wa))
(def lb (tree/leaf wb))
(def lc (tree/leaf wc))
(def inner (tree/container :split :horizontal @[lb lc]))
(def outer (tree/container :split :vertical @[la inner]))
(def result (scroll/layout-node outer {:x 0 :y 0 :w 800 :h 600} ig bw))
(t/assert-eq (length result) 3)
# Vertical split: usable-h=592, cell-h=296
(t/assert-eq ((result 0) :h) 296 "top leaf")
(t/assert-eq ((result 0) :w) 800)
# Inner horizontal: cell-w of 800, gap=8, usable=792, each=396
(t/assert-eq ((result 1) :w) 396 "inner left")
(t/assert-eq ((result 2) :w) 396 "inner right")
(t/assert-eq ((result 1) :y) 304 "inner starts after gap")

# --- scroll-layout (integration) ---

(def config @{:peek-width pw :border-width bw :inner-gap ig :outer-gap og})
(def output {:x 0 :y 0 :w 1920 :h 1080})
(def usable {:x 0 :y 0 :w 1920 :h 1080})

(t/test-start "scroll-layout: single window, centered-ish")
(tree/reset-ids)
(def w1 @{:wid 1})
(def l1 (tree/leaf w1 1.0))
(def cols @[l1])
(def result (scroll/scroll-layout cols l1 0 output usable config))
(t/assert-eq (result :camera) 0)
(t/assert-eq (length (result :placements)) 1)
(def p (first (result :placements)))
(t/assert-is (p :window) w1)
(t/assert-eq (p :x) 4 "outer-gap from left")
(t/assert-eq (p :y) 4 "outer-gap from top")
(t/assert-eq (p :w) 1872)
(t/assert-eq (p :h) 1072)
(t/assert-eq (p :clip) nil "fully visible")

(t/test-start "scroll-layout: two small windows, no scroll")
(tree/reset-ids)
(def w1 @{:wid 1})
(def w2 @{:wid 2})
(def l1 (tree/leaf w1 0.4))
(def l2 (tree/leaf w2 0.4))
(def cols @[l1 l2])
(def result (scroll/scroll-layout cols l1 0 output usable config))
(t/assert-eq (result :camera) 0 "everything fits")
(t/assert-eq (length (result :placements)) 2)

(t/test-start "scroll-layout: three 100% windows, focus middle")
(tree/reset-ids)
(def windows (seq [i :range [0 3]] @{:wid i}))
(def cols (seq [i :range [0 3]] (tree/leaf (windows i) 1.0)))
(def result (scroll/scroll-layout cols (tree/first-leaf (cols 1)) 0 output usable config))
(t/assert-eq (result :camera) 1860 "scrolled to show middle")
# Should have placements for visible columns
(t/assert-truthy (> (length (result :placements)) 0))

(t/test-start "scroll-layout: clipping on partially visible window")
(tree/reset-ids)
(def windows (seq [i :range [0 3]] @{:wid i}))
(def cols (seq [i :range [0 3]] (tree/leaf (windows i) 1.0)))
# Focus col 1, cam should be 1860
(def result (scroll/scroll-layout cols (tree/first-leaf (cols 1)) 0 output usable config))
# Col 0: vx=4, screen_x = 0 + 4 - 1860 = -1856. visible? -1856+1872=16 > 0, yes
# Its clip should have clip-x > 0
(def col0-placement (find |(= ($ :window) (windows 0)) (result :placements)))
(when col0-placement
  (t/assert-truthy (col0-placement :clip) "first column should be clipped")
  (t/assert-truthy (> ((col0-placement :clip) :clip-x) 0) "clipped on left"))

(t/test-start "scroll-layout: with usable area offset (layer shell)")
(tree/reset-ids)
(def w1 @{:wid 1})
(def l1 (tree/leaf w1 1.0))
(def cols @[l1])
(def usable-bar {:x 0 :y 32 :w 1920 :h 1048})
(def result (scroll/scroll-layout cols l1 0 output usable-bar config))
(def p (first (result :placements)))
(t/assert-eq (p :y) 36 "offset by usable + outer-gap")
(t/assert-eq (p :h) 1040 "reduced by usable height - 2*outer-gap")

(t/test-start "scroll-layout: vertical split column")
(tree/reset-ids)
(def w1 @{:wid 1})
(def w2 @{:wid 2})
(def l1 (tree/leaf w1))
(def l2 (tree/leaf w2))
(def col (tree/container :split :vertical @[l1 l2] 1.0))
(def cols @[col])
(def result (scroll/scroll-layout cols l1 0 output usable config))
(t/assert-eq (length (result :placements)) 2)
(def p1 (find |(= ($ :window) w1) (result :placements)))
(def p2 (find |(= ($ :window) w2) (result :placements)))
(t/assert-truthy (< (p1 :y) (p2 :y)) "first above second")
(t/assert-eq (p1 :w) 1872 "full column width")

(t/test-start "scroll-layout: nil focus-leaf")
(tree/reset-ids)
(def l1 (tree/leaf @{:wid 1} 1.0))
(def cols @[l1])
(def result (scroll/scroll-layout cols nil 0 output usable config))
(t/assert-eq (result :camera) 0)
(t/assert-eq (length (result :placements)) 1)

(t/test-start "scroll-layout: empty columns")
(def result (scroll/scroll-layout @[] nil 0 output usable config))
(t/assert-eq (result :camera) 0)
(t/assert-eq (length (result :placements)) 0)

(t/test-start "scroll-layout: multi-output offset")
(tree/reset-ids)
(def w1 @{:wid 1})
(def l1 (tree/leaf w1 1.0))
(def cols @[l1])
(def output2 {:x 1920 :y 0 :w 1920 :h 1080})
(def usable2 {:x 1920 :y 0 :w 1920 :h 1080})
(def result (scroll/scroll-layout cols l1 0 output2 usable2 config))
(def p (first (result :placements)))
(t/assert-eq (p :x) 1924 "offset by second output position")

(t/report)
