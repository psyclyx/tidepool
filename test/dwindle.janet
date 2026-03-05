# Tests for dwindle layout and geometry-based navigation (see layout/dwindle, layout/init).

(import ../src/layout/dwindle)

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

# Geometry-based navigation (mirrors layout/init navigate-by-geometry).
(defn nav [results focused-idx dir]
  (def current (get results focused-idx))
  (def cx (+ (current :x) (/ (current :w) 2)))
  (def cy (+ (current :y) (/ (current :h) 2)))
  (var best nil)
  (var best-dist math/inf)
  (for i 0 (length results)
    (def other (get results i))
    (when (and (not= i focused-idx) (not (other :hidden)))
      (def valid
        (case dir
          :right (>= (other :x) (+ (current :x) (current :w)))
          :left (<= (+ (other :x) (other :w)) (current :x))
          :down (>= (other :y) (+ (current :y) (current :h)))
          :up (<= (+ (other :y) (other :h)) (current :y))))
      (when valid
        (def dx (- (+ (other :x) (/ (other :w) 2)) cx))
        (def dy (- (+ (other :y) (/ (other :h) 2)) cy))
        (def dist (+ (* dx dx) (* dy dy)))
        (when (< dist best-dist)
          (set best i)
          (set best-dist dist)))))
  best)

# Test helpers
(def usable {:x 0 :y 0 :w 1000 :h 1000})
(def config @{:outer-padding 0 :inner-padding 0})
(defn make-windows [n] (seq [i :range [0 n]] @{:id i}))
(def default-params @{:dwindle-ratio 0.5})

(defn dwindle-geometry [n &opt params]
  (default params default-params)
  (dwindle/layout usable (make-windows n) params config nil))


# Navigation tests (geometry-based)
#
# Dwindle tree structure (3 windows):
#   +-------+-------+
#   |       |   1   |
#   |   0   +-------+
#   |       |   2   |
#   +-------+-------+
#
# Split 0 (even=vertical): window 0 left, rest right
# Split 1 (odd=horizontal): window 1 top, rest bottom

(test "nav: 1 window — all directions return nil"
  (def geo (dwindle-geometry 1))
  (each dir [:left :right :up :down]
    (assert= (nav geo 0 dir) nil
      (string/format "1 window, dir %q" dir))))

(test "nav: 2 windows — right from 0, left from 1"
  (def geo (dwindle-geometry 2))
  (assert= (nav geo 0 :right) 1)
  (assert= (nav geo 1 :left) 0))

(test "nav: 2 windows — vertical-only split has no up/down"
  (def geo (dwindle-geometry 2))
  (assert= (nav geo 0 :down) nil)
  (assert= (nav geo 0 :up) nil)
  (assert= (nav geo 1 :down) nil)
  (assert= (nav geo 1 :up) nil))

(test "nav: 3 windows — right from 0 goes to 1 (nearest right)"
  (def geo (dwindle-geometry 3))
  (assert= (nav geo 0 :right) 1))

(test "nav: 3 windows — down from 1 goes to 2"
  (def geo (dwindle-geometry 3))
  (assert= (nav geo 1 :down) 2))

(test "nav: 3 windows — left from 2 goes to 0"
  (def geo (dwindle-geometry 3))
  (assert= (nav geo 2 :left) 0))

(test "nav: 3 windows — up from 2 goes to 1"
  (def geo (dwindle-geometry 3))
  (assert= (nav geo 2 :up) 1))

(test "nav: 3 windows — last window has no right/down"
  (def geo (dwindle-geometry 3))
  (assert= (nav geo 2 :right) nil)
  (assert= (nav geo 2 :down) nil))

(test "nav: 3 windows — full-height window has no up/down"
  (def geo (dwindle-geometry 3))
  # Window 0 spans the full height — nothing is above or below it
  (assert= (nav geo 0 :left) nil "0 left")
  (assert= (nav geo 0 :up) nil "0 up")
  (assert= (nav geo 0 :down) nil "0 down"))

# 4 windows:
#   +-------+-------+
#   |       |   1   |
#   |   0   +---+---+
#   |       | 2 | 3 |
#   +-------+---+---+

(test "nav: 4 windows — right from 2 goes to 3"
  (def geo (dwindle-geometry 4))
  (assert= (nav geo 2 :right) 3))

(test "nav: 4 windows — left from 3 goes to 2"
  (def geo (dwindle-geometry 4))
  (assert= (nav geo 3 :left) 2))

(test "nav: 4 windows — up from 3 goes to 1"
  (def geo (dwindle-geometry 4))
  (assert= (nav geo 3 :up) 1))

(test "nav: 4 windows — left from 2 goes to 0"
  (def geo (dwindle-geometry 4))
  (assert= (nav geo 2 :left) 0))

# 5 windows:
#   +-------+----------+
#   |       |    1     |
#   |   0   +-----+----+
#   |       |  2  | 3  |
#   |       |     +----+
#   |       |     | 4  |
#   +-------+-----+----+

(test "nav: 5 windows — down from 3 goes to 4"
  (def geo (dwindle-geometry 5))
  (assert= (nav geo 3 :down) 4))

(test "nav: 5 windows — up from 4 goes to 3"
  (def geo (dwindle-geometry 5))
  (assert= (nav geo 4 :up) 3))

(test "nav: 5 windows — left from 4 goes to 2"
  (def geo (dwindle-geometry 5))
  (assert= (nav geo 4 :left) 2))

(test "nav: 5 windows — right from 2 goes to 3"
  (def geo (dwindle-geometry 5))
  (assert= (nav geo 2 :right) 3))


# Layout / per-split ratio tests

(defn layout-widths [n params]
  (def results (dwindle/layout usable (make-windows n) params config nil))
  (map |($ :w) results))

(defn layout-heights [n params]
  (def results (dwindle/layout usable (make-windows n) params config nil))
  (map |($ :h) results))

(test "layout: uniform ratio 0.5 — 3 windows split evenly"
  (def params @{:dwindle-ratio 0.5})
  (def ws (layout-widths 3 params))
  (def hs (layout-heights 3 params))
  # Window 0 gets 50% width, full height
  (assert= (get ws 0) 500 "win 0 width")
  (assert= (get hs 0) 1000 "win 0 height")
  # Windows 1 and 2 get 50% width, 50% height each
  (assert= (get ws 1) 500 "win 1 width")
  (assert= (get hs 1) 500 "win 1 height")
  (assert= (get ws 2) 500 "win 2 width")
  (assert= (get hs 2) 500 "win 2 height"))

(test "layout: per-split ratio overrides default"
  (def params @{:dwindle-ratio 0.5 :dwindle-ratios @{0 0.7}})
  (def ws (layout-widths 3 params))
  # Window 0 gets 70% of 1000 = 700
  (assert= (get ws 0) 700 "win 0 width with 0.7 ratio")
  # Windows 1 and 2 share remaining 300, split 0.5 horizontally
  (assert= (get ws 1) 300 "win 1 width")
  (assert= (get ws 2) 300 "win 2 width"))

(test "layout: per-split ratio on horizontal split"
  (def params @{:dwindle-ratio 0.5 :dwindle-ratios @{1 0.3}})
  (def hs (layout-heights 3 params))
  # Window 0 full height
  (assert= (get hs 0) 1000 "win 0 full height")
  # Window 1 gets 30% of 1000 = 300
  (assert= (get hs 1) 300 "win 1 height with 0.3 ratio")
  # Window 2 gets remaining 700
  (assert= (get hs 2) 700 "win 2 height"))

(test "layout: ratios nil — falls back to dwindle-ratio"
  (def params @{:dwindle-ratio 0.6})
  (def ws (layout-widths 2 params))
  (assert= (get ws 0) 600 "win 0 width at 0.6")
  (assert= (get ws 1) 400 "win 1 width"))

(test "layout: only specified splits are overridden"
  (def params @{:dwindle-ratio 0.5 :dwindle-ratios @{0 0.4}})
  (def ws (layout-widths 4 params))
  (def hs (layout-heights 4 params))
  # Split 0: window 0 gets 40% width
  (assert= (get ws 0) 400 "win 0 at 0.4")
  # Split 1: default 0.5 height
  (assert= (get hs 1) 500 "win 1 default 0.5 height")
  # Split 2: default 0.5 width of remaining 600
  (assert= (get ws 2) 300 "win 2 default 0.5 of remaining"))


(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
