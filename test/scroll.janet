# Tests for scroll layout — uses real scroll module, no reimplementations.

(import ../src/layout/scroll :as scroll)

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

(defmacro assert-true [a &opt msg]
  ~(unless ,a (error (string (or ,msg "expected truthy")))))

(defmacro assert-false [a &opt msg]
  ~(when ,a (error (string (or ,msg "expected falsy")))))

# --- Test infrastructure ---

(def base-config @{:outer-padding 4 :inner-padding 8 :border-width 4
                   :column-row-height 0 :animate false})

(defn make-params [output &opt overrides]
  (def p @{:column-width 0.5 :scroll-offset 0 :active-row 0
           :output-bounds [(output :x) (output :y) (output :w) (output :h)]})
  (when overrides (merge-into p overrides))
  p)

(defn make-usable [output &opt bar-h]
  (default bar-h 0)
  {:x (output :x) :y (+ (output :y) bar-h)
   :w (output :w) :h (- (output :h) bar-h)})

(defn make-windows [n]
  (seq [i :range [0 n]] @{:row 0}))

(defn visible-results [results]
  (filter |(not ($ :hidden)) results))

(defn count-visible [results]
  (length (visible-results results)))

# --- Property assertions ---

(defn assert-visible-overlap-output [results output msg]
  "All visible results overlap with the output bounds (peeking windows extend past)."
  (each r (visible-results results)
    (assert-true (< (r :x) (+ (output :x) (output :w)))
      (string/format "%s: x=%d >= output-right=%d (no overlap)" msg (r :x) (+ (output :x) (output :w))))
    (assert-true (> (+ (r :x) (r :w)) (output :x))
      (string/format "%s: x+w=%d <= output-x=%d (no overlap)" msg (+ (r :x) (r :w)) (output :x)))
    (assert-true (< (r :y) (+ (output :y) (output :h)))
      (string/format "%s: y=%d >= output-bottom=%d (no overlap)" msg (r :y) (+ (output :y) (output :h))))
    (assert-true (> (+ (r :y) (r :h)) (output :y))
      (string/format "%s: y+h=%d <= output-y=%d (no overlap)" msg (+ (r :y) (r :h)) (output :y)))))

(defn assert-focused-within-output [results focused output msg]
  "Focused window is fully within output bounds (not just peeking)."
  (when focused
    (def r (find |(= ($ :window) focused) results))
    (when (and r (not (r :hidden)))
      (assert-true (>= (r :x) (output :x))
        (string/format "%s: focused x=%d < output-x=%d" msg (r :x) (output :x)))
      (assert-true (<= (+ (r :x) (r :w)) (+ (output :x) (output :w)))
        (string/format "%s: focused x+w=%d > output-right=%d" msg (+ (r :x) (r :w)) (+ (output :x) (output :w)))))))

(defn assert-focused-visible [results focused msg]
  "Focused window is never hidden."
  (when focused
    (def r (find |(= ($ :window) focused) results))
    (assert-true r (string msg ": focused window not in results"))
    (assert-false (r :hidden) (string msg ": focused window is hidden"))))

(defn assert-no-border-overlap [results bw msg]
  "Adjacent visible windows don't overlap (including borders)."
  (def vis (sort (filter |(not ($ :hidden)) results)
                 (fn [a b] (< (a :x) (b :x)))))
  (for i 0 (- (length vis) 1)
    (def a (get vis i))
    (def b (get vis (+ i 1)))
    (def a-right (+ (a :x) (a :w) (* 2 bw)))
    (def b-left (- (b :x) bw))
    # Allow for 1px rounding tolerance
    (assert-true (>= (- b-left a-right) -1)
      (string/format "%s: overlap a-right=%d b-left=%d" msg a-right b-left))))

(defn assert-scroll-valid [params total-content-w total-w msg]
  "Scroll offset is within [0, max-scroll]."
  (def max-scroll (max 0 (- total-content-w total-w)))
  (def scroll (params :scroll-offset))
  (assert-true (>= scroll 0)
    (string/format "%s: scroll=%d < 0" msg scroll))
  (assert-true (<= scroll max-scroll)
    (string/format "%s: scroll=%d > max-scroll=%d" msg scroll max-scroll)))

# --- Output definitions ---

(def single {:x 0 :y 0 :w 1920 :h 1080})
(def gawfolk {:x 0 :y 0 :w 3840 :h 2560})
(def left-out {:x 0 :y 0 :w 1920 :h 1080})
(def right-out {:x 1920 :y 0 :w 1920 :h 1080})
(def big-left {:x 0 :y 0 :w 3840 :h 2560})
(def small-right {:x 3840 :y 0 :w 1920 :h 1080})
(def stacked-top {:x 0 :y 0 :w 1920 :h 1080})
(def stacked-bottom {:x 0 :y 1080 :w 1920 :h 1080})

# ===================================================================
# Unit tests: compute-scroll-target (pure function)
# ===================================================================

(defn make-col [&opt ratio] @[@{:col-width ratio}])
(defn make-cols [n &opt ratio]
  (seq [i :range [0 n]] (make-col ratio)))

(test "scroll-target: 2 cols 50% — no scroll needed"
  (def cols (make-cols 2))
  (def outer 4)
  (def inner 8)
  (def total-w (- 3840 (* 2 outer)))
  (def content-w (- total-w (* 2 inner)))
  (def col-xs (scroll/x-positions cols content-w 0.5))
  (def tcw (scroll/total-content-width cols col-xs content-w 0.5 inner))
  (assert= tcw total-w "total-content-w should equal total-w")
  (def scroll (scroll/compute-scroll-target
    :total-w total-w :total-content-w tcw
    :inner inner :bw 4
    :focused-x inner :focused-col-w (scroll/col-width (first cols) content-w 0.5)
    :focused-col-idx 0 :num-cols 2
    :current-scroll 0))
  (assert= scroll 0 "no scroll when content fits"))

(test "scroll-target: 3 cols 50%, focus col 0 — flush left"
  (def cols (make-cols 3))
  (def inner 8)
  (def total-w (- 3840 8))
  (def content-w (- total-w 16))
  (def col-xs (scroll/x-positions cols content-w 0.5))
  (def tcw (scroll/total-content-width cols col-xs content-w 0.5 inner))
  (def scroll (scroll/compute-scroll-target
    :total-w total-w :total-content-w tcw
    :inner inner :bw 4
    :focused-x inner :focused-col-w (scroll/col-width (first cols) content-w 0.5)
    :focused-col-idx 0 :num-cols 3
    :current-scroll 0))
  (assert= scroll 0 "first column flush left"))

(test "scroll-target: 3 cols 50%, focus col 2 — flush right"
  (def cols (make-cols 3))
  (def inner 8)
  (def total-w (- 3840 8))
  (def content-w (- total-w 16))
  (def col-xs (scroll/x-positions cols content-w 0.5))
  (def tcw (scroll/total-content-width cols col-xs content-w 0.5 inner))
  (def cw (scroll/col-width (first cols) content-w 0.5))
  (def focused-x (+ inner (get col-xs 2)))
  (def scroll (scroll/compute-scroll-target
    :total-w total-w :total-content-w tcw
    :inner inner :bw 4
    :focused-x focused-x :focused-col-w cw
    :focused-col-idx 2 :num-cols 3
    :current-scroll 0))
  (assert= scroll (- (+ focused-x cw) total-w)
    "last column right edge flush with viewport"))

(test "scroll-target: 3 cols 50%, focus col 1 — both peeks"
  (def cols (make-cols 3))
  (def inner 8)
  (def total-w (- 3840 8))
  (def content-w (- total-w 16))
  (def col-xs (scroll/x-positions cols content-w 0.5))
  (def tcw (scroll/total-content-width cols col-xs content-w 0.5 inner))
  (def cw (scroll/col-width (first cols) content-w 0.5))
  (def scroll (scroll/compute-scroll-target
    :total-w total-w :total-content-w tcw
    :inner inner :bw 4
    :focused-x (+ inner (get col-xs 1)) :focused-col-w cw
    :focused-col-idx 1 :num-cols 3
    :current-scroll 0))
  (assert= scroll (- inner 4) "scroll accounts for border offset"))

(test "scroll-target: content fits — no scroll"
  (def cols (make-cols 2))
  (def inner 8)
  (def total-w (- 3840 8))
  (def content-w (- total-w 16))
  (def col-xs (scroll/x-positions cols content-w 0.5))
  (def tcw (scroll/total-content-width cols col-xs content-w 0.5 inner))
  (def scroll (scroll/compute-scroll-target
    :total-w total-w :total-content-w tcw
    :inner inner :bw 4
    :focused-x inner :focused-col-w (scroll/col-width (first cols) content-w 0.5)
    :focused-col-idx 0 :num-cols 2
    :current-scroll 0))
  (assert= scroll 0 "no scroll when content fits"))

# ===================================================================
# Integration tests: scroll/layout on a single output
# ===================================================================

(test "layout: single output, 2 windows — both visible"
  (def wins (make-windows 2))
  (def params (make-params single))
  (def results (scroll/layout (make-usable single) wins params base-config (first wins)))
  (assert= (count-visible results) 2 "2 visible")
  (assert-visible-overlap-output results single "single-2")
  (assert-focused-visible results (first wins) "single-2 focus")
  (assert-focused-within-output results (first wins) single "single-2 contained"))

(test "layout: single output, 1 window — visible"
  (def wins (make-windows 1))
  (def params (make-params single))
  (def results (scroll/layout (make-usable single) wins params base-config (first wins)))
  (assert= (count-visible results) 1)
  (assert-visible-overlap-output results single "single-1"))

(test "layout: single output, 3 cols, focus each — focused always visible"
  (def wins (make-windows 3))
  (for fi 0 3
    (each w wins (put w :column nil))
    (def params (make-params single))
    (def results (scroll/layout (make-usable single) wins params base-config (get wins fi)))
    (assert-focused-visible results (get wins fi)
      (string/format "focus-col-%d" fi))))

(test "layout: no overlap between visible windows"
  (def wins (make-windows 3))
  (def params (make-params single))
  (def results (scroll/layout (make-usable single) wins params base-config (first wins)))
  (assert-no-border-overlap results (base-config :border-width) "no-overlap"))

(test "layout: scroll offset valid after focusing each column"
  (def wins (make-windows 4))
  (for fi 0 4
    (each w wins (put w :column nil))
    (def params (make-params gawfolk))
    (def results (scroll/layout (make-usable gawfolk) wins params base-config (get wins fi)))
    (assert-scroll-valid params (params :total-content-w)
      (max 1 (- (gawfolk :w) (* 2 (base-config :outer-padding))))
      (string/format "scroll-valid-col-%d" fi))))

# ===================================================================
# Multi-monitor integration tests
# ===================================================================

(test "multi: two equal outputs side-by-side — output 2 windows positioned correctly"
  (def wins (make-windows 2))
  (def params (make-params right-out))
  (def results (scroll/layout (make-usable right-out) wins params base-config (first wins)))
  (assert= (count-visible results) 2 "2 visible on output 2")
  (assert-visible-overlap-output results right-out "right-out-2")
  (assert-focused-visible results (first wins) "right-out focus")
  (assert-focused-within-output results (first wins) right-out "right-out contained"))

(test "multi: output 2 at x=1920, 3 cols, focus each — all within bounds"
  (def wins (make-windows 3))
  (for fi 0 3
    (each w wins (put w :column nil))
    (def params (make-params right-out))
    (def results (scroll/layout (make-usable right-out) wins params base-config (get wins fi)))
    (def msg (string/format "right-3col-focus-%d" fi))
    (assert-visible-overlap-output results right-out msg)
    (assert-focused-visible results (get wins fi) msg)
    (assert-focused-within-output results (get wins fi) right-out msg)))

(test "multi: big left + small right — windows fit respective outputs"
  (def wins-l (make-windows 3))
  (def wins-r (make-windows 3))

  # Layout on big left
  (def params-l (make-params big-left))
  (def results-l (scroll/layout (make-usable big-left) wins-l params-l base-config (first wins-l)))
  (assert-visible-overlap-output results-l big-left "big-left")
  (assert-focused-visible results-l (first wins-l) "big-left focus")

  # Layout on small right
  (each w wins-r (put w :column nil))
  (def params-r (make-params small-right))
  (def results-r (scroll/layout (make-usable small-right) wins-r params-r base-config (first wins-r)))
  (assert-visible-overlap-output results-r small-right "small-right")
  (assert-focused-visible results-r (first wins-r) "small-right focus"))

(test "multi: vertically stacked outputs — bottom output windows within bounds"
  (def wins (make-windows 2))
  (def params (make-params stacked-bottom))
  (def results (scroll/layout (make-usable stacked-bottom) wins params base-config (first wins)))
  (assert-visible-overlap-output results stacked-bottom "stacked-bottom")
  (each r (visible-results results)
    (assert-true (>= (r :y) 1080)
      (string/format "stacked-bottom: y=%d < 1080" (r :y)))))

(test "multi: output 2, nil focus — windows still visible and positioned correctly"
  (def wins (make-windows 2))
  (def params (make-params right-out))
  (def results (scroll/layout (make-usable right-out) wins params base-config nil))
  (assert-true (> (count-visible results) 0) "visible without focus")
  (assert-visible-overlap-output results right-out "right-nil-focus"))

(test "multi: output 2 with status bar — windows below bar and within bounds"
  (def wins (make-windows 2))
  (def params (make-params right-out))
  (def results (scroll/layout (make-usable right-out 44) wins params base-config (first wins)))
  (assert-visible-overlap-output results right-out "right-bar")
  (each r (visible-results results)
    (assert-true (>= (r :y) (+ (right-out :y) 44))
      (string/format "right-bar: y=%d < bar-bottom=%d" (r :y) (+ (right-out :y) 44)))))

(test "multi: scroll offset from larger monitor clamped on smaller"
  (def wins (make-windows 3))
  (each w wins (put w :column nil))
  # First layout on big monitor — scroll to rightmost column
  (def params-big (make-params big-left))
  (scroll/layout (make-usable big-left) wins params-big base-config (get wins 2))
  (def big-scroll (params-big :scroll-offset))
  (assert-true (> big-scroll 0) "scrolled on big monitor")

  # Now layout same windows on small monitor with the big scroll offset
  (each w wins (put w :column nil))
  (def params-small (make-params small-right {:scroll-offset big-scroll}))
  (def results (scroll/layout (make-usable small-right) wins params-small base-config (first wins)))
  (def outer (base-config :outer-padding))
  (def small-total-w (max 1 (- (small-right :w) (* 2 outer))))
  (assert-scroll-valid params-small (params-small :total-content-w) small-total-w
    "clamped-scroll"))

(test "multi: output 2, 5 cols, sweep focus — all properties hold"
  (def wins (make-windows 5))
  (for fi 0 5
    (each w wins (put w :column nil))
    (def params (make-params right-out))
    (def results (scroll/layout (make-usable right-out) wins params base-config (get wins fi)))
    (def msg (string/format "right-5col-focus-%d" fi))
    (assert-visible-overlap-output results right-out msg)
    (assert-focused-visible results (get wins fi) msg)
    (assert-focused-within-output results (get wins fi) right-out msg)
    (assert-no-border-overlap results (base-config :border-width) msg)
    (def outer (base-config :outer-padding))
    (def tw (max 1 (- (right-out :w) (* 2 outer))))
    (assert-scroll-valid params (params :total-content-w) tw msg)))

# ===================================================================
# Multi-monitor isolation tests
# ===================================================================

(test "multi: two outputs, independent scroll state"
  (def wins-l (make-windows 3))
  (def wins-r (make-windows 3))
  (def params-l (make-params left-out))
  (def params-r (make-params right-out))

  # Layout left, scroll to col 2
  (scroll/layout (make-usable left-out) wins-l params-l base-config (get wins-l 2))
  (def scroll-l (params-l :scroll-offset))

  # Layout right, scroll to col 0
  (each w wins-r (put w :column nil))
  (scroll/layout (make-usable right-out) wins-r params-r base-config (first wins-r))
  (def scroll-r (params-r :scroll-offset))

  # Left scrolled, right not scrolled — independent
  (assert-true (> scroll-l 0) "left output scrolled")
  (assert= scroll-r 0 "right output not scrolled")
  # Left scroll didn't affect right params
  (assert= (params-r :scroll-offset) 0 "right params untouched"))

(test "multi: column assignments don't leak between outputs"
  (def wins-l (make-windows 3))
  (def wins-r (make-windows 2))
  (def params-l (make-params left-out))
  (def params-r (make-params right-out))

  (scroll/layout (make-usable left-out) wins-l params-l base-config (first wins-l))
  (def cols-l (map |($ :column) wins-l))

  (scroll/layout (make-usable right-out) wins-r params-r base-config (first wins-r))
  (def cols-r (map |($ :column) wins-r))

  # Left has 3 columns (0, 1, 2), right has 2 (0, 1)
  (assert= (length (distinct cols-l)) 3 "left has 3 distinct columns")
  (assert= (length (distinct cols-r)) 2 "right has 2 distinct columns")
  # Left's columns unchanged after right's layout
  (assert (deep= cols-l (map |($ :column) wins-l)) "left columns stable"))

(test "multi: layout on output 2, re-layout preserves column order"
  (def wins (make-windows 4))
  (def params (make-params right-out))

  # First layout
  (scroll/layout (make-usable right-out) wins params base-config (first wins))
  (def cols-1 (map |($ :column) wins))

  # Second layout (no column reset, simulates next frame)
  (def results (scroll/layout (make-usable right-out) wins params base-config (first wins)))
  (def cols-2 (map |($ :column) wins))
  (assert (deep= cols-1 cols-2) "column order preserved across frames"))

(test "multi: output at large offset — windows not at origin"
  (def far-right {:x 7680 :y 0 :w 1920 :h 1080})
  (def wins (make-windows 2))
  (def params (make-params far-right))
  (def results (scroll/layout (make-usable far-right) wins params base-config (first wins)))
  (each r (visible-results results)
    (assert-true (>= (r :x) 7680)
      (string/format "far-right: x=%d < 7680" (r :x))))
  (assert-focused-within-output results (first wins) far-right "far-right"))

(test "multi: output at negative offset"
  (def neg-out {:x -1920 :y 0 :w 1920 :h 1080})
  (def wins (make-windows 2))
  (def params (make-params neg-out))
  (def results (scroll/layout (make-usable neg-out) wins params base-config (first wins)))
  (assert-focused-within-output results (first wins) neg-out "neg-out")
  (assert-visible-overlap-output results neg-out "neg-out"))

(test "multi: two outputs, simulate pipeline order (both layouts, then check)"
  (def wins-l (make-windows 3))
  (def wins-r (make-windows 3))
  (def params-l (make-params left-out))
  (def params-r (make-params right-out))

  # Simulate pipeline: layout runs for each output in sequence
  (def results-l (scroll/layout (make-usable left-out) wins-l params-l base-config (get wins-l 1)))
  (def results-r (scroll/layout (make-usable right-out) wins-r params-r base-config (get wins-r 1)))

  # Both should have correct positions for their respective outputs
  (assert-focused-within-output results-l (get wins-l 1) left-out "pipeline-left")
  (assert-focused-within-output results-r (get wins-r 1) right-out "pipeline-right")

  # No window from output 1 should have positions in output 2's range
  (each r (visible-results results-l)
    (assert-true (< (r :x) (+ (left-out :x) (left-out :w)))
      "left-out window not in right-out territory"))
  # Focused windows from output 2 should be in output 2's range
  (each r (visible-results results-r)
    (when (= (r :window) (get wins-r 1))
      (assert-true (>= (r :x) (right-out :x))
        "right-out focused window in right-out territory"))))

(test "multi: different column widths on different outputs"
  (def wins-l (make-windows 3))
  (def wins-r (make-windows 3))
  (def params-l (make-params left-out {:column-width 0.33}))
  (def params-r (make-params right-out {:column-width 0.67}))

  (def results-l (scroll/layout (make-usable left-out) wins-l params-l base-config (first wins-l)))
  (def results-r (scroll/layout (make-usable right-out) wins-r params-r base-config (first wins-r)))

  # Both should have valid positions
  (assert-visible-overlap-output results-l left-out "left-narrow")
  (assert-visible-overlap-output results-r right-out "right-wide")
  (assert-focused-within-output results-l (first wins-l) left-out "left-narrow focus")
  (assert-focused-within-output results-r (first wins-r) right-out "right-wide focus"))

# ===================================================================
# Property sweep: parameterized across outputs and column counts
# ===================================================================

(def test-outputs
  [single gawfolk left-out right-out big-left small-right stacked-top stacked-bottom])

(def output-names
  ["single" "gawfolk" "left" "right" "big-left" "small-right" "top" "bottom"])

(test "property sweep: all outputs × 1-6 cols × each focus position"
  (for oi 0 (length test-outputs)
    (def output (get test-outputs oi))
    (def oname (get output-names oi))
    (for ncols 1 7
      (def wins (make-windows ncols))
      (for fi 0 ncols
        (each w wins (put w :column nil))
        (def params (make-params output))
        (def results (scroll/layout (make-usable output) wins params base-config (get wins fi)))
        (def msg (string/format "%s/%dc/f%d" oname ncols fi))
        (assert-focused-visible results (get wins fi) msg)
        (assert-focused-within-output results (get wins fi) output msg)
        (assert-visible-overlap-output results output msg)
        (assert-no-border-overlap results (base-config :border-width) msg)
        (def outer (base-config :outer-padding))
        (def tw (max 1 (- (output :w) (* 2 outer))))
        (assert-scroll-valid params (params :total-content-w) tw msg)))))

# ===================================================================
# Row filtering tests (use real scroll module)
# ===================================================================

(defn make-row-win [&keys {:column col :row row :col-width cw}]
  @{:column col :row row :col-width cw})

(test "rows: nil row treated as row 0"
  (def wins @[
    (make-row-win :column 0)
    (make-row-win :column 1 :row 0)
    (make-row-win :column 2 :row 1)])
  (def ctx (scroll/context wins nil nil 0))
  (assert= (length (ctx :windows)) 2 "row 0 has 2 windows")
  (assert= (ctx :num-cols) 2 "row 0 has 2 columns"))

(test "rows: active row 1 filters correctly"
  (def wins @[
    (make-row-win :column 0 :row 0)
    (make-row-win :column 0 :row 1)
    (make-row-win :column 1 :row 1)])
  (def ctx (scroll/context wins nil nil 1))
  (assert= (length (ctx :windows)) 2 "row 1 has 2 windows")
  (assert= (ctx :num-cols) 2 "row 1 has 2 columns"))

(test "rows: empty row returns nil context"
  (def wins @[(make-row-win :column 0 :row 0)])
  (def ctx (scroll/context wins nil nil 5))
  (assert (nil? ctx) "empty row should return nil"))

(test "rows: focused column tracking"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 1 :row 0))
  (def w2 (make-row-win :column 0 :row 1))
  (def wins @[w0 w1 w2])
  (def ctx (scroll/context wins w1 nil 0))
  (assert= (ctx :focused-col) 1 "focused column is 1"))

(test "rows: auto-assign new windows to active row"
  (def w0 (make-row-win :column 0 :row 0))
  (def w-new @{})
  (def wins @[w0 w-new])
  (def usable {:x 0 :y 0 :w 1920 :h 1080})
  (def params @{:column-width 0.5 :scroll-offset 0 :active-row 2})
  (scroll/layout usable wins params base-config nil)
  (assert= (w-new :row) 2 "new window auto-assigned to active row"))

(test "rows: non-active row windows hidden in layout"
  (def w0 @{:row 0})
  (def w1 @{:row 1})
  (def wins @[w0 w1])
  (def usable {:x 0 :y 0 :w 1920 :h 1080})
  (def params @{:column-width 0.5 :scroll-offset 0 :active-row 0})
  (def results (scroll/layout usable wins params base-config nil))
  (def hidden (filter |($ :hidden) results))
  (def visible (filter |(not ($ :hidden)) results))
  (assert= (length hidden) 1 "1 hidden window")
  (assert= ((first hidden) :window) w1 "row 1 window is hidden")
  (assert= (length visible) 1 "1 visible window")
  (assert= ((first visible) :window) w0 "row 0 window is visible"))

# ===================================================================
# Row boundary navigation tests
# ===================================================================

(test "row-boundary: down at bottom of single-window column detects boundary"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w0 nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :down all))
  (assert-true info "should detect boundary")
  (assert= (info :target-row) 1 "target is row 1")
  (assert= (length (info :windows)) 1 "1 window in target row"))

(test "row-boundary: up at top of column detects boundary"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w1 nil 1))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :up all))
  (assert-true info "should detect boundary")
  (assert= (info :target-row) 0 "target is row 0"))

(test "row-boundary: down at bottom of multi-window column detects boundary"
  (def w0a (make-row-win :column 0 :row 0))
  (def w0b @{:column 0 :row 0 :col-weight 1.0})
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0a w0b w1])
  (def ctx (scroll/context all w0b nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :down all))
  (assert-true info "should detect boundary at bottom of stacked column"))

(test "row-boundary: down in middle of stacked column returns nil"
  (def w0a (make-row-win :column 0 :row 0))
  (def w0b @{:column 0 :row 0 :col-weight 1.0})
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0a w0b w1])
  (def ctx (scroll/context all w0a nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :down all))
  (assert (nil? info) "not at boundary — middle of column"))

(test "row-boundary: up at topmost row returns nil"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w0 nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :up all))
  (assert (nil? info) "no row above row 0"))

(test "row-boundary: down at bottommost row returns nil"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w1 nil 1))
  (put ctx :all-tiled all)
  (def info (scroll/row-boundary-info ctx :down all))
  (assert (nil? info) "no row below row 1"))

(test "row-boundary: left/right never triggers boundary"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w0 nil 0))
  (put ctx :all-tiled all)
  (assert (nil? (scroll/row-boundary-info ctx :left all)) "left never crosses rows")
  (assert (nil? (scroll/row-boundary-info ctx :right all)) "right never crosses rows"))

(test "swap-boundary: down at bottommost row creates new row"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w1 nil 1))
  (put ctx :all-tiled all)
  (def info (scroll/swap-boundary-info ctx :down all))
  (assert-true info "should create new row")
  (assert= (info :target-row) 2 "new row is 2")
  (assert (info :new) "marked as new")
  (assert= (length (info :windows)) 0 "no windows in new row"))

(test "swap-boundary: up at topmost row creates new row"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w0 nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/swap-boundary-info ctx :up all))
  (assert-true info "should create new row")
  (assert= (info :target-row) -1 "new row is -1")
  (assert (info :new) "marked as new"))

(test "swap-boundary: down with existing row below returns it (not new)"
  (def w0 (make-row-win :column 0 :row 0))
  (def w1 (make-row-win :column 0 :row 1))
  (def all @[w0 w1])
  (def ctx (scroll/context all w0 nil 0))
  (put ctx :all-tiled all)
  (def info (scroll/swap-boundary-info ctx :down all))
  (assert-true info "should find existing row")
  (assert= (info :target-row) 1 "target is row 1")
  (assert (nil? (info :new)) "not marked as new"))

(test "layout: auto-switches to populated row when active row is empty"
  (def w0 @{:row 0})
  (def w1 @{:row 2})
  (def wins @[w0 w1])
  (def usable {:x 0 :y 0 :w 1920 :h 1080})
  (def params @{:column-width 0.5 :scroll-offset 0 :active-row 1})
  (scroll/layout usable wins params base-config nil)
  (assert= (params :active-row) 0 "snapped to nearest populated row"))

(test "switch-to-row: saves and restores scroll offsets"
  (def params @{:scroll-offset 150 :active-row 0})
  (scroll/switch-to-row params 0 1)
  (assert= (params :active-row) 1 "active row switched")
  (assert= (get-in params [:row-states 0 :scroll-offset]) 150 "old offset saved")
  (assert= (params :scroll-offset) 0 "new row starts at 0"))

(test "switch-to-row: restores previously saved offset"
  (def params @{:scroll-offset 0 :active-row 0
                :row-states @{1 @{:scroll-offset 300}}})
  (scroll/switch-to-row params 0 1)
  (assert= (params :scroll-offset) 300 "restored saved offset"))

# ===================================================================
# Clip interaction tests (scroll + clip-to-output simulation)
# ===================================================================

(defn compute-clip
  "Simulate window/clip-to-output for scroll-placed windows."
  [wx wy ww wh output]
  (def ox (output :x))
  (def oy (output :y))
  (def ow (output :w))
  (def oh (output :h))
  (if (or (< wx ox) (< wy oy)
          (> (+ wx ww) (+ ox ow))
          (> (+ wy wh) (+ oy oh)))
    (do
      (def clip-x (max 0 (- ox wx)))
      (def clip-y (max 0 (- oy wy)))
      (def clip-w (max 1 (- (min (+ wx ww) (+ ox ow)) (max wx ox))))
      (def clip-h (max 1 (- (min (+ wy wh) (+ oy oh)) (max wy oy))))
      [(math/round clip-x) (math/round clip-y)
       (math/round clip-w) (math/round clip-h)])
    :clear))

(test "clip: on-screen window on output 2 — clear"
  (def result (compute-clip 2000 100 200 200 right-out))
  (assert= result :clear "on-screen window on output 2"))

(test "clip: peeking window on output 2 — clipped at left edge"
  (def result (compute-clip 1900 100 200 200 right-out))
  (assert (not= result :clear) "should clip")
  (def [cx cy cw ch] result)
  (assert= cx 20 "clip-x = output-left - window-left")
  (assert= cw 180 "clip-w = visible portion"))

(test "clip: peeking window on output 2 — clipped at right edge"
  (def result (compute-clip 3750 100 200 200 right-out))
  (assert (not= result :clear) "should clip")
  (def [cx cy cw ch] result)
  (assert= cx 0 "clip-x = 0 (left edge visible)")
  (assert= cw 90 "clip-w = output-right - window-left"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
