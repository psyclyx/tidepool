(import ./helper :as t)
(import anim)

# ============================================================
# Easing functions
# ============================================================

(t/test-start "ease-out-cubic: boundaries")
(t/assert-eq (anim/ease-out-cubic 0) 0)
(t/assert-eq (anim/ease-out-cubic 1) 1)

(t/test-start "ease-out-cubic: midpoint > 0.5 (fast start)")
(t/assert-truthy (> (anim/ease-out-cubic 0.5) 0.5))

(t/test-start "ease-out-quad: boundaries")
(t/assert-eq (anim/ease-out-quad 0) 0)
(t/assert-eq (anim/ease-out-quad 1) 1)

(t/test-start "linear: identity")
(t/assert-eq (anim/linear 0) 0)
(t/assert-eq (anim/linear 0.5) 0.5)
(t/assert-eq (anim/linear 1) 1)

# ============================================================
# Core math
# ============================================================

(t/test-start "lerp: basic")
(t/assert-eq (anim/lerp 0 100 0) 0)
(t/assert-eq (anim/lerp 0 100 1) 100)
(t/assert-eq (anim/lerp 0 100 0.5) 50)
(t/assert-eq (anim/lerp 10 20 0.25) 12.5)

(t/test-start "close-enough?: within epsilon")
(t/assert-truthy (anim/close-enough? 10.3 10 0.5))
(t/assert-falsey (anim/close-enough? 10.6 10 0.5))
(t/assert-truthy (anim/close-enough? 10 10))

# ============================================================
# Spring creation
# ============================================================

(t/test-start "make-spring: creates animation state")
(def s (anim/make-spring 0 100 200))
(t/assert-eq (s :start) 0)
(t/assert-eq (s :target) 100)
(t/assert-eq (s :current) 0)
(t/assert-eq (s :elapsed) 0)
(t/assert-eq (s :duration) 200)

(t/test-start "make-spring: nil when already at target")
(t/assert-eq (anim/make-spring 100 100 200) nil)
(t/assert-eq (anim/make-spring 99.8 100 200) nil "within epsilon")

# ============================================================
# Advance
# ============================================================

(t/test-start "advance: progresses animation")
(def s (anim/make-spring 0 100 200))
(def result (anim/advance s 100 anim/linear))
(t/assert-truthy result "still animating")
(t/assert-eq (s :elapsed) 100)
(t/assert-eq (s :current) 50 "halfway with linear easing")

(t/test-start "advance: completes at duration")
(def s (anim/make-spring 0 100 200))
(t/assert-eq (anim/advance s 200 anim/linear) nil "done")

(t/test-start "advance: completes past duration")
(def s (anim/make-spring 0 100 200))
(t/assert-eq (anim/advance s 300 anim/linear) nil)

(t/test-start "advance: nil spring returns nil")
(t/assert-eq (anim/advance nil 100 anim/linear) nil)

(t/test-start "advance: with easing")
(def s (anim/make-spring 0 100 200))
(anim/advance s 100 anim/ease-out-cubic)
# ease-out-cubic(0.5) = 1 - (0.5)^3 = 1 - 0.125 = 0.875
(t/assert-eq (s :current) 87.5 "eased value")

# ============================================================
# Retarget
# ============================================================

(t/test-start "retarget: redirects in-flight animation")
(def s (anim/make-spring 0 100 200))
(anim/advance s 100 anim/linear) # current = 50
(def s2 (anim/retarget s 200 200))
(t/assert-truthy s2)
(t/assert-eq (s2 :start) 50 "starts from current position")
(t/assert-eq (s2 :target) 200)
(t/assert-eq (s2 :elapsed) 0 "fresh timer")

(t/test-start "retarget: nil spring starts from target as current")
(def s (anim/retarget nil 100 200))
# nil spring means "at rest at new-target" → make-spring(100, 100, ...) → nil
# Wait, that's not right. If spring is nil, current is new-target, so it's already there.
(t/assert-eq s nil "already at target")

(t/test-start "retarget: nil spring with different position")
# This case doesn't arise naturally since nil means at rest,
# but let's verify the function handles it
(def s (anim/retarget nil 100 200))
(t/assert-eq s nil)

# ============================================================
# Window animation
# ============================================================

(t/test-start "set-targets: creates springs for y/w/h changes")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 50 800 600 200 0 800 600)
(t/assert-truthy (get-in w [:anim :y]) "y spring created")
(t/assert-eq (get-in w [:anim :w]) nil "w unchanged, no spring")
(t/assert-eq (get-in w [:anim :h]) nil "h unchanged, no spring")

(t/test-start "set-targets: no springs when unchanged")
(def w @{:y 50 :w 800 :h 600})
(anim/set-targets w 50 800 600 200 50 800 600)
(t/assert-eq (get-in w [:anim :y]) nil)

(t/test-start "tick-window: advances springs")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 100 800 600 200 0 800 600)
(def active (anim/tick-window w 100 anim/linear))
(t/assert-truthy active "still animating")
(t/assert-eq (get-in w [:anim :y :current]) 50 "halfway")

(t/test-start "tick-window: completes and clears")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 100 800 600 200 0 800 600)
(anim/tick-window w 200 anim/linear)
(t/assert-eq (get-in w [:anim :y]) nil "spring removed")

(t/test-start "animating?: true when springs active")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 100 800 600 200 0 800 600)
(t/assert-truthy (anim/animating? w))

(t/test-start "animating?: false when no springs")
(def w @{:y 50 :w 800 :h 600})
(anim/set-targets w 50 800 600 200 50 800 600)
(t/assert-falsey (anim/animating? w))

# ============================================================
# Open / Close animation
# ============================================================

(t/test-start "start-open: creates open spring")
(def w @{})
(anim/start-open w 150)
(t/assert-truthy (get-in w [:anim :open]))
(t/assert-eq (get-in w [:anim :open :start]) 0)
(t/assert-eq (get-in w [:anim :open :target]) 1)

(t/test-start "start-close: creates close spring and sets closing")
(def w @{})
(anim/start-close w 120)
(t/assert-truthy (get-in w [:anim :close]))
(t/assert-truthy (w :closing))

(t/test-start "tick-window: close animation clears closing flag when done")
(def w @{})
(anim/start-close w 100)
(t/assert-truthy (w :closing))
(anim/tick-window w 100 anim/linear)
(t/assert-falsey (w :closing) "closing cleared after animation")

# ============================================================
# Camera animation
# ============================================================

(t/test-start "set-camera-target: creates camera spring")
(def tag @{:camera 500 :camera-anim nil})
(anim/set-camera-target tag 500 200 0)
(t/assert-truthy (tag :camera-anim))
(t/assert-eq ((tag :camera-anim) :target) 500)
(t/assert-eq ((tag :camera-anim) :start) 0)

(t/test-start "set-camera-target: no-op when already at target")
(def tag @{:camera 500 :camera-anim nil})
(anim/set-camera-target tag 500 200 500)
(t/assert-eq (tag :camera-anim) nil)

(t/test-start "set-camera-target: no-op without prev-cam when at target")
(def tag @{:camera 500 :camera-anim nil})
(anim/set-camera-target tag 500 200)
(t/assert-eq (tag :camera-anim) nil)

(t/test-start "tick-camera: advances and sets visual")
(def tag @{:camera 100 :camera-anim nil})
(anim/set-camera-target tag 100 200 0)
(def active (anim/tick-camera tag 100 anim/linear))
(t/assert-truthy active)
(t/assert-eq (tag :camera-visual) 50)

(t/test-start "tick-camera: completes and snaps")
(def tag @{:camera 200 :camera-anim nil})
(anim/set-camera-target tag 200 200 100)
(anim/tick-camera tag 200 anim/linear)
(t/assert-eq (tag :camera-anim) nil "spring cleared")
(t/assert-eq (tag :camera-visual) 200 "snapped to tag :camera")

(t/test-start "set-camera-target: retargets in-flight")
(def tag @{:camera 100 :camera-anim nil})
(anim/set-camera-target tag 100 200 0)
(anim/tick-camera tag 100 anim/linear) # visual = 50
(put tag :camera 200)
(anim/set-camera-target tag 200 200 100) # retarget from 50 to 200
(t/assert-eq ((tag :camera-anim) :start) 50)
(t/assert-eq ((tag :camera-anim) :target) 200)

(t/test-start "set-camera-target: initializes camera-visual on spring creation")
(def tag @{:camera 500 :camera-anim nil :camera-visual nil})
(anim/set-camera-target tag 500 200 0)
(t/assert-eq (tag :camera-visual) 0)

# ============================================================
# resolve helpers
# ============================================================

(t/test-start "resolve-y: reads from active spring")
(def w @{:y 50 :anim @{:y @{:current 40}}})
(t/assert-eq (anim/resolve-y w) 40)

(t/test-start "resolve-y: falls back to target when no spring")
(def w @{:y 50})
(t/assert-eq (anim/resolve-y w) 50)

(t/test-start "resolve-dimensions: reads from active spring")
(def w @{:w 800 :h 600 :anim @{:w @{:current 750} :h @{:current 580}}})
(def [rw rh] (anim/resolve-dimensions w))
(t/assert-eq rw 750)
(t/assert-eq rh 580)

(t/test-start "resolve-dimensions: falls back to target when no spring")
(def w @{:w 800 :h 600})
(def [rw rh] (anim/resolve-dimensions w))
(t/assert-eq rw 800)
(t/assert-eq rh 600)

# ============================================================
# any-animating?
# ============================================================

(t/test-start "any-animating?: false when nothing active")
(def ctx @{:windows @[] :tags @{}})
(t/assert-falsey (anim/any-animating? ctx))

(t/test-start "any-animating?: true when window animating")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 100 800 600 200 0 800 600)
(def ctx @{:windows @[w] :tags @{}})
(t/assert-truthy (anim/any-animating? ctx))

(t/test-start "any-animating?: true when camera animating")
(def tag @{:camera 100 :camera-anim nil})
(anim/set-camera-target tag 100 200 0)
(def ctx @{:windows @[] :tags @{1 tag}})
(t/assert-truthy (anim/any-animating? ctx))

# ============================================================
# Nil-safety and mid-flight retarget
# ============================================================

(t/test-start "set-targets: nil prev-w/prev-h with no existing spring creates no spring")
(def w @{:y 50 :w 800 :h 600})
(anim/set-targets w 100 800 600 200 50 nil nil)
(t/assert-truthy (get-in w [:anim :y]) "y spring created from prev-y")
(t/assert-eq (get-in w [:anim :w]) nil "no w spring — nil rest, target matches")
(t/assert-eq (get-in w [:anim :h]) nil "no h spring — nil rest, target matches")

(t/test-start "set-targets: nil prev with existing spring retargets from spring current")
(def w @{:y 0 :w 800 :h 600})
(anim/set-targets w 100 900 700 200 0 800 600)
(t/assert-truthy (get-in w [:anim :w]) "w spring created")
# Tick partway
(anim/tick-window w 100 anim/linear)
(def mid-w (get-in w [:anim :w :current]))
# Retarget with nil prev (simulates manage-dirty re-render cycle)
(anim/set-targets w 100 950 700 200 0 nil nil)
(t/assert-truthy (get-in w [:anim :w]) "w spring retargeted")
(t/assert-eq (get-in w [:anim :w :start]) mid-w "starts from spring current")
(t/assert-eq (get-in w [:anim :w :target]) 950 "targets new value")

(t/test-start "set-targets: nil new-val does not create spring")
(def w @{:y 50 :w 800 :h 600})
(anim/set-targets w 100 nil nil 200 50 800 600)
(t/assert-truthy (get-in w [:anim :y]) "y spring created")
(t/assert-eq (get-in w [:anim :w]) nil "no w spring — nil new-val")
(t/assert-eq (get-in w [:anim :h]) nil "no h spring — nil new-val")

(t/report)
