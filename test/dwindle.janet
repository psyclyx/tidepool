# Tests for dwindle layout navigation and resize (see layout/dwindle).

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

# Navigation tests
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
  (each dir [:left :right :up :down]
    (assert= (dwindle/navigate 1 1 0 dir nil) nil
      (string/format "1 window, dir %q" dir))))

(test "nav: 2 windows — right from 0 enters right subtree"
  (assert= (dwindle/navigate 2 1 0 :right nil) 1))

(test "nav: 2 windows — left from 1 returns to 0"
  (assert= (dwindle/navigate 2 1 1 :left nil) 0))

(test "nav: 2 windows — vertical-only split has no up/down"
  (assert= (dwindle/navigate 2 1 0 :down nil) nil)
  (assert= (dwindle/navigate 2 1 0 :up nil) nil)
  (assert= (dwindle/navigate 2 1 1 :down nil) nil)
  (assert= (dwindle/navigate 2 1 1 :up nil) nil))

(test "nav: 3 windows — right from 0 goes to 1"
  (assert= (dwindle/navigate 3 1 0 :right nil) 1))

(test "nav: 3 windows — down from 1 goes to 2"
  (assert= (dwindle/navigate 3 1 1 :down nil) 2))

(test "nav: 3 windows — left from 2 jumps to 0 (enclosing vertical split)"
  (assert= (dwindle/navigate 3 1 2 :left nil) 0))

(test "nav: 3 windows — up from 2 goes to 1 (enclosing horizontal split)"
  (assert= (dwindle/navigate 3 1 2 :up nil) 1))

(test "nav: 3 windows — last window has no right/down"
  (assert= (dwindle/navigate 3 1 2 :right nil) nil)
  (assert= (dwindle/navigate 3 1 2 :down nil) nil))

(test "nav: 3 windows — window 0 has no left/up"
  (assert= (dwindle/navigate 3 1 0 :left nil) nil)
  (assert= (dwindle/navigate 3 1 0 :up nil) nil))

# 4 windows:
#   +-------+-------+
#   |       |   1   |
#   |   0   +---+---+
#   |       | 2 | 3 |
#   +-------+---+---+

(test "nav: 4 windows — right from 2 goes to 3"
  (assert= (dwindle/navigate 4 1 2 :right nil) 3))

(test "nav: 4 windows — left from 3 goes to 2"
  (assert= (dwindle/navigate 4 1 3 :left nil) 2))

(test "nav: 4 windows — up from 3 goes to 1"
  (assert= (dwindle/navigate 4 1 3 :up nil) 1))

(test "nav: 4 windows — left from 2 jumps to 0"
  (assert= (dwindle/navigate 4 1 2 :left nil) 0))

# 5 windows:
#   +-------+----------+
#   |       |    1     |
#   |   0   +-----+----+
#   |       |  2  | 3  |
#   |       |     +----+
#   |       |     | 4  |
#   +-------+-----+----+

(test "nav: 5 windows — down from 3 goes to 4"
  (assert= (dwindle/navigate 5 1 3 :down nil) 4))

(test "nav: 5 windows — up from 4 goes to 3"
  (assert= (dwindle/navigate 5 1 4 :up nil) 3))

(test "nav: 5 windows — left from 4 goes to 2"
  (assert= (dwindle/navigate 5 1 4 :left nil) 2))

(test "nav: 5 windows — left from 3 goes to 2"
  (assert= (dwindle/navigate 5 1 3 :left nil) 2))

(test "nav: 5 windows — right from 2 goes to 3"
  (assert= (dwindle/navigate 5 1 2 :right nil) 3))

# Exhaustive direction checks for 3-window layout (the user's example)
(test "nav: 3 windows — complete direction table"
  # Window 0 (left, full height): right→1, others→nil
  (assert= (dwindle/navigate 3 1 0 :right nil) 1 "0 right")
  (assert= (dwindle/navigate 3 1 0 :left nil) nil "0 left")
  (assert= (dwindle/navigate 3 1 0 :up nil) nil "0 up")
  (assert= (dwindle/navigate 3 1 0 :down nil) nil "0 down")
  # Window 1 (top-right): down→2, left→0, others→nil
  (assert= (dwindle/navigate 3 1 1 :down nil) 2 "1 down")
  (assert= (dwindle/navigate 3 1 1 :left nil) 0 "1 left")
  (assert= (dwindle/navigate 3 1 1 :right nil) nil "1 right")
  (assert= (dwindle/navigate 3 1 1 :up nil) nil "1 up")
  # Window 2 (bottom-right): left→0, up→1, others→nil
  (assert= (dwindle/navigate 3 1 2 :left nil) 0 "2 left")
  (assert= (dwindle/navigate 3 1 2 :up nil) 1 "2 up")
  (assert= (dwindle/navigate 3 1 2 :right nil) nil "2 right")
  (assert= (dwindle/navigate 3 1 2 :down nil) nil "2 down"))


# Layout / per-split ratio tests

(def usable {:x 0 :y 0 :w 1000 :h 1000})
(def config @{:outer-padding 0 :inner-padding 0})
(defn make-windows [n] (seq [i :range [0 n]] @{:id i}))

(defn layout-widths [n params]
  (def wins (make-windows n))
  (def results (dwindle/layout usable wins params config nil))
  (map |($ :w) results))

(defn layout-heights [n params]
  (def wins (make-windows n))
  (def results (dwindle/layout usable wins params config nil))
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
