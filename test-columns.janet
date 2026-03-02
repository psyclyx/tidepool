# Tests for columns layout scroll, clipping, and placement logic.
#
# These extract the pure math from layout/columns and window/clip-to-output
# so we can verify correctness without wayland/protocol dependencies.

(defn sum [xs] (reduce + 0 xs))

# --- Scroll target computation (extracted from layout/columns) ---

(defn compute-scroll-target
  "Compute the target scroll offset given layout parameters.
  Returns the clamped target scroll value."
  [&named total-w total-content-w strut-l strut-r
          focused-x focused-col-w focused-col-idx num-cols current-scroll]
  (def max-scroll (max 0 (- total-content-w total-w)))
  (def eff-strut-l (if (> focused-col-idx 0) strut-l 0))
  (def eff-strut-r (if (< focused-col-idx (- num-cols 1)) strut-r 0))
  (var target current-scroll)
  (when (< focused-x (+ target eff-strut-l))
    (set target (- focused-x eff-strut-l)))
  (when (> (+ focused-x focused-col-w) (- (+ target total-w) eff-strut-r))
    (set target (+ (- (+ focused-x focused-col-w) total-w) eff-strut-r)))
  (min max-scroll (max 0 target)))

# --- Column geometry helpers ---

(defn col-width [col total-w default-ratio]
  (math/round (* total-w (or ((first col) :col-width) default-ratio))))

(defn col-x-positions [cols total-w default-ratio]
  (def positions @[])
  (var x 0)
  (each col cols
    (array/push positions x)
    (set x (+ x (col-width col total-w default-ratio))))
  positions)

(defn total-content-width [cols col-xs total-w default-ratio]
  (+ (last col-xs) (col-width (last cols) total-w default-ratio)))

# --- Place-window visibility check (extracted from columns/place-window) ---

(defn place-window-result
  "Determine window placement. Returns {:hidden true} or {:x :y :pw :ph}
  where pw/ph are the proposed content dimensions (before bw subtraction)."
  [x y w h clip-left clip-right clip-top clip-bottom inner]
  (def win-left x)
  (def win-right (+ x w (* 2 inner)))
  (def win-top y)
  (def win-bottom (+ y h (* 2 inner)))
  (if (or (<= win-right clip-left) (>= win-left clip-right)
          (<= win-bottom clip-top) (>= win-top clip-bottom))
    {:hidden true}
    {:x (+ x inner) :y (+ y inner) :pw w :ph h}))

# --- Clip-to-output computation (extracted from window/clip-to-output) ---

(defn compute-clip
  "Compute clip box for a window on an output. Returns nil (no clip needed),
  :clear (clip should be disabled), or [clip-x clip-y clip-w clip-h]."
  [window-x window-y window-w window-h
   output-x output-y output-w output-h bw &opt outer-pad]
  (default outer-pad 0)
  (def inset (+ bw outer-pad))
  (def ox (+ output-x inset))
  (def oy (+ output-y inset))
  (def ow (- output-w (* 2 inset)))
  (def oh (- output-h (* 2 inset)))
  (if (or (< window-x ox) (< window-y oy)
          (> (+ window-x window-w) (+ ox ow))
          (> (+ window-y window-h) (+ oy oh)))
    (do
      (def clip-x (max 0 (- ox window-x)))
      (def clip-y (max 0 (- oy window-y)))
      (def clip-w (max 1 (- (min (+ window-x window-w) (+ ox ow))
                              (max window-x ox))))
      (def clip-h (max 1 (- (min (+ window-y window-h) (+ oy oh))
                              (max window-y oy))))
      [(math/round clip-x) (math/round clip-y)
       (math/round clip-w) (math/round clip-h)])
    :clear))

# --- Window geometry helpers for tests ---

(defn window-positions
  "Given scroll, cols, col-xs, compute each window's content position.
  Returns array of {:col :x :y :w :h :hidden} for each window."
  [&named scroll cols col-xs total-w total-h default-ratio
          outer inner bw usable-x usable-y
          clip-left clip-right clip-top clip-bottom]
  (def results @[])
  (for ci 0 (length cols)
    (def col (get cols ci))
    (def cw (col-width col total-w default-ratio))
    (def x-off (- (get col-xs ci) scroll))
    (def num-rows (length col))
    # Classic mode: proportional height
    (def total-weight (sum (map |(or ($ :col-weight) 1.0) col)))
    (var y-sum 0)
    (def heights @[])
    (for ri 0 num-rows
      (def weight (or ((get col ri) :col-weight) 1.0))
      (def h (math/round (* total-h (/ weight total-weight))))
      (def actual-h (if (= ri (- num-rows 1)) (- total-h y-sum) h))
      (array/push heights actual-h)
      (set y-sum (+ y-sum actual-h)))
    (var y-acc 0)
    (for ri 0 num-rows
      (def h (get heights ri))
      (def x (+ usable-x outer x-off))
      (def y (+ usable-y outer y-acc))
      (def pw (- cw (* 2 inner)))
      (def ph (- h (* 2 inner)))
      (def result (place-window-result x y pw ph
                    clip-left clip-right clip-top clip-bottom inner))
      (array/push results
        (if (result :hidden)
          @{:col ci :row ri :hidden true}
          @{:col ci :row ri
            :content-x (result :x) :content-y (result :y)
            :content-w (- (result :pw) (* 2 bw))  # after bw subtraction
            :content-h (- (result :ph) (* 2 bw))
            :border-left (- (result :x) bw)
            :border-right (+ (result :x) (- (result :pw) (* 2 bw)) bw)
            :border-top (- (result :y) bw)
            :border-bottom (+ (result :y) (- (result :ph) (* 2 bw)) bw)}))
      (set y-acc (+ y-acc h))))
  results)

# ============================================================
# Test helpers
# ============================================================

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

(defmacro assert-near [a b tolerance &opt msg]
  ~(let [va ,a vb ,b]
     (unless (<= (math/abs (- va vb)) ,tolerance)
       (error (string (or ,msg "") " expected ~" vb " got " va
                       " (tolerance " ,tolerance ")")))))

# ============================================================
# Standard test fixtures
# ============================================================

# Gawfolk monitor: 3840x2560 at (0,0)
(def gawfolk {:x 0 :y 0 :w 3840 :h 2560})
(def bw 4)
(def outer 4)
(def inner 8)
(def total-w (- (gawfolk :w) (* 2 outer)))  # 3832
(def total-h (- (gawfolk :h) (* 2 outer)))  # 2552
(def clip-left (+ (gawfolk :x) outer))       # 4
(def clip-right (+ clip-left total-w))       # 3836
(def clip-top (+ (gawfolk :y) outer))        # 4
(def clip-bottom (+ clip-top total-h))       # 2556

(defn make-win [&opt col-override]
  @{:col-width col-override})

(defn make-cols [n &opt ratio]
  (def cols @[])
  (for i 0 n
    (array/push cols @[(make-win ratio)]))
  cols)

# ============================================================
# Scroll target tests
# ============================================================

(test "scroll: 2 cols 50% — no scroll needed"
  (def cols (make-cols 2))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (assert= tcw total-w "total-content-w should equal total-w")
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 32 :strut-r 32
    :focused-x 0 :focused-col-w (col-width (first cols) total-w 0.5)
    :focused-col-idx 0 :num-cols 2
    :current-scroll 0))
  (assert= scroll 0 "no scroll when content fits"))

(test "scroll: 3 cols 50%, focus col 0 — flush left (no left strut)"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 32 :strut-r 32
    :focused-x 0 :focused-col-w cw
    :focused-col-idx 0 :num-cols 3
    :current-scroll 0))
  # First column: no left strut, flush left → scroll=0
  (assert= scroll 0 "first column should be flush left"))

(test "scroll: 3 cols 50%, focus col 2 — flush right (no right strut)"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))
  (def max-scroll (- tcw total-w))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 32 :strut-r 32
    :focused-x (get col-xs 2) :focused-col-w cw
    :focused-col-idx 2 :num-cols 3
    :current-scroll 0))
  # Last column: no right strut, flush right → scroll=max-scroll
  (assert= scroll max-scroll "last column should be flush right"))

(test "scroll: 3 cols 50%, focus col 1 — both struts apply"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 32 :strut-r 32
    :focused-x (get col-xs 1) :focused-col-w cw
    :focused-col-idx 1 :num-cols 3
    :current-scroll 0))
  # Middle column: both struts apply
  # focused-x + col-w = 1916 + 1916 = 3832
  # 3832 > target + 3832 - 32 = target + 3800 → target = 32
  (assert= scroll 32 "scroll centers col 1 with strut margin"))

(test "scroll: no struts — clamps to [0, max-scroll]"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 0 :strut-r 0
    :focused-x 0 :focused-col-w cw
    :focused-col-idx 0 :num-cols 3
    :current-scroll 0))
  (assert= scroll 0 "no struts, focus col 0 → scroll=0"))

(test "scroll: content fits — no scroll"
  (def cols (make-cols 2))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 200 :strut-r 200
    :focused-x 0 :focused-col-w cw
    :focused-col-idx 0 :num-cols 2
    :current-scroll 0))
  (assert= scroll 0 "no scroll when content fits even with large struts"))

(test "scroll: small overflow, focus col 0 — flush left"
  # total-content-w barely exceeds total-w
  (def cols @[@[(make-win 0.6)] @[(make-win 0.6)]])
  (def col-xs (col-x-positions cols total-w 0.6))
  (def tcw (total-content-width cols col-xs total-w 0.6))
  (def cw (col-width (first cols) total-w 0.6))
  (def scroll (compute-scroll-target
    :total-w total-w :total-content-w tcw
    :strut-l 400 :strut-r 400
    :focused-x 0 :focused-col-w cw
    :focused-col-idx 0 :num-cols 2
    :current-scroll 0))
  # First column: no left strut → flush left → scroll=0
  (assert= scroll 0 "first column flush left regardless of strut size"))

# ============================================================
# Window placement tests
# ============================================================

(test "placement: on-screen window gets positioned"
  (def result (place-window-result 100 100 400 300
                clip-left clip-right clip-top clip-bottom inner))
  (assert (not (result :hidden)) "should not be hidden")
  (assert= (result :x) 108 "content x = x + inner")
  (assert= (result :y) 108 "content y = y + inner"))

(test "placement: fully left of clip — hidden"
  (def result (place-window-result -2000 100 400 300
                clip-left clip-right clip-top clip-bottom inner))
  (assert (result :hidden) "fully left should be hidden"))

(test "placement: fully right of clip — hidden"
  (def result (place-window-result 4000 100 400 300
                clip-left clip-right clip-top clip-bottom inner))
  (assert (result :hidden) "fully right should be hidden"))

(test "placement: exactly at clip-right boundary — hidden"
  # win-left = clip-right → fully off-screen
  (def result (place-window-result clip-right 100 400 300
                clip-left clip-right clip-top clip-bottom inner))
  (assert (result :hidden) "at clip-right boundary should be hidden"))

(test "placement: 1px inside clip-right — visible"
  (def result (place-window-result (- clip-right 1) 100 400 300
                clip-left clip-right clip-top clip-bottom inner))
  (assert (not (result :hidden)) "1px inside should be visible"))

# ============================================================
# Clip-to-output tests
# ============================================================

(test "clip: fully on-screen — clear"
  (def result (compute-clip 100 100 200 200
                (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert= result :clear "on-screen window should clear clip"))

(test "clip: partially off left — clips with outer padding"
  (def result (compute-clip -100 100 400 200
                (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert (not= result :clear) "should clip")
  (def [cx cy cw ch] result)
  # inset = bw + outer = 8. ox = 0 + 8 = 8. clip-x = 8 - (-100) = 108
  (assert= cx 108 "clip-x")
  # clip-w = min(-100+400, 8+3824) - max(-100, 8) = min(300, 3832) - 8 = 292
  (assert= cw 292 "clip-w")
  (assert= cy 0 "clip-y should be 0")
  # Verify visible content starts at output edge + inset
  (def visible-left (+ -100 cx))
  (assert= visible-left 8 "visible content left = output-x + bw + outer"))

(test "clip: partially off right — clips with outer padding"
  (def result (compute-clip 3700 100 400 200
                (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert (not= result :clear) "should clip")
  (def [cx cy cw ch] result)
  (assert= cx 0 "clip-x should be 0")
  # inset = 8. clip-w = min(3700+400, 8+3824) - max(3700, 8) = min(4100, 3832) - 3700 = 132
  (assert= cw 132 "clip-w")
  # Border right = visible content right + bw = (3700 + 132) + 4 = 3836
  # Output edge = 3840. Gap = 4 = outer padding preserved
  (def visible-right (+ 3700 0 cw))
  (assert= (+ visible-right bw outer) (+ (gawfolk :x) (gawfolk :w))
    "border right + outer = output edge"))

(test "clip: fully off-screen — clip-w clamped to 1"
  (def result (compute-clip -500 100 100 100
                (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert (not= result :clear) "should clip")
  (def [cx cy cw ch] result)
  (assert= cw 1 "fully off-screen clip-w clamped to 1"))

(test "clip: window at inset from output edge — fully on-screen"
  # Content at bw+outer from output edge
  (def inset (+ bw outer))
  (def result (compute-clip (+ (gawfolk :x) inset) (+ (gawfolk :y) inset) 100 100
                (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert= result :clear "window at inset from edge should be fully on-screen"))

# ============================================================
# Integration: full window positions for columns layout
# ============================================================

(test "integration: 2 cols 50% — no overlap, correct gaps"
  (def cols (make-cols 2))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 0 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (assert= (length wins) 2 "2 windows")
  (def w0 (get wins 0))
  (def w1 (get wins 1))
  (assert (not (w0 :hidden)) "col 0 visible")
  (assert (not (w1 :hidden)) "col 1 visible")
  # Gap between borders
  (def gap (- (w1 :border-left) (w0 :border-right)))
  (assert= gap (* 2 inner) "gap between borders = 2*inner = 16"))

(test "integration: 2 cols 50% — no border overlap with output edge"
  (def cols (make-cols 2))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 0 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (def w0 (get wins 0))
  (def w1 (get wins 1))
  (assert (>= (w0 :border-left) (gawfolk :x)) "left border within output")
  (assert (<= (w1 :border-right) (+ (gawfolk :x) (gawfolk :w))) "right border within output"))

(test "integration: 3 cols 50%, scroll=32 — col 2 peeks"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 32 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (def w2 (get wins 2))
  (assert (not (w2 :hidden)) "col 2 should be visible (peeking)"))

(test "integration: 3 cols 50%, scroll=0 — col 2 hidden (no peek)"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 0 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (def w2 (get wins 2))
  (assert (w2 :hidden) "col 2 hidden at scroll=0"))

(test "integration: 3 cols 50%, scroll=32 — peek clip preserves outer padding"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 32 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (def w2 (get wins 2))
  (assert (not (w2 :hidden)) "col 2 peeking")
  # Compute clip for the peeking window
  (def clip (compute-clip
    (w2 :content-x) (w2 :content-y) (w2 :content-w) (w2 :content-h)
    (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert (not= clip :clear) "peek window should be clipped")
  (def [cx cy cw ch] clip)
  # Border right should be at output edge minus outer padding
  (def visible-right (+ (w2 :content-x) cx cw))
  (assert= (+ visible-right bw outer) (+ (gawfolk :x) (gawfolk :w))
    "peek border right + outer = output edge"))

(test "integration: 3 cols 50%, scroll=1884 — col 0 peeks left with padding"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def wins (window-positions
    :scroll 1884 :cols cols :col-xs col-xs
    :total-w total-w :total-h total-h :default-ratio 0.5
    :outer outer :inner inner :bw bw
    :usable-x (gawfolk :x) :usable-y (gawfolk :y)
    :clip-left clip-left :clip-right clip-right
    :clip-top clip-top :clip-bottom clip-bottom))
  (def w0 (get wins 0))
  (assert (not (w0 :hidden)) "col 0 should be visible (peeking left)")
  # Compute clip
  (def clip (compute-clip
    (w0 :content-x) (w0 :content-y) (w0 :content-w) (w0 :content-h)
    (gawfolk :x) (gawfolk :y) (gawfolk :w) (gawfolk :h) bw outer))
  (assert (not= clip :clear) "peek window should be clipped")
  (def [cx cy cw ch] clip)
  # Border left should be at output left edge plus outer padding
  (def visible-left (+ (w0 :content-x) cx))
  (assert= (- visible-left bw) (+ (gawfolk :x) outer)
    "peek border left = output edge + outer"))

(test "integration: no windows overlap"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (for scroll-val 0 200 10
    (def wins (window-positions
      :scroll scroll-val :cols cols :col-xs col-xs
      :total-w total-w :total-h total-h :default-ratio 0.5
      :outer outer :inner inner :bw bw
      :usable-x (gawfolk :x) :usable-y (gawfolk :y)
      :clip-left clip-left :clip-right clip-right
      :clip-top clip-top :clip-bottom clip-bottom))
    (def visible (filter |(not ($ :hidden)) wins))
    (for i 0 (- (length visible) 1)
      (def a (get visible i))
      (def b (get visible (+ i 1)))
      (assert (>= (b :border-left) (a :border-right))
        (string/format "scroll=%d: col %d border-right (%d) overlaps col %d border-left (%d)"
          scroll-val (a :col) (a :border-right) (b :col) (b :border-left))))))

# ============================================================
# Scroll + placement end-to-end
# ============================================================

(test "e2e: focus each column with struts — all produce valid peeks"
  (def cols (make-cols 3))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def cw (col-width (first cols) total-w 0.5))

  (for focus-ci 0 3
    (def scroll (compute-scroll-target
      :total-w total-w :total-content-w tcw
      :strut-l 32 :strut-r 32
      :focused-x (get col-xs focus-ci) :focused-col-w cw
      :focused-col-idx focus-ci :num-cols 3
      :current-scroll 0))
    (def wins (window-positions
      :scroll scroll :cols cols :col-xs col-xs
      :total-w total-w :total-h total-h :default-ratio 0.5
      :outer outer :inner inner :bw bw
      :usable-x (gawfolk :x) :usable-y (gawfolk :y)
      :clip-left clip-left :clip-right clip-right
      :clip-top clip-top :clip-bottom clip-bottom))
    # Focused column should always be visible
    (def focused-win (get wins focus-ci))
    (assert (not (focused-win :hidden))
      (string/format "focus col %d: focused column should be visible" focus-ci))
    # At least one non-focused column should be visible (peek or full)
    (def others (filter |(and (not ($ :hidden)) (not= ($ :col) focus-ci)) wins))
    (assert (> (length others) 0)
      (string/format "focus col %d: should have visible non-focused columns" focus-ci))))

(test "e2e: scroll target is within valid bounds"
  (def cols (make-cols 4))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def max-scroll (- tcw total-w))

  (for focus-ci 0 4
    (def cw (col-width (get cols focus-ci) total-w 0.5))
    (def scroll (compute-scroll-target
      :total-w total-w :total-content-w tcw
      :strut-l 32 :strut-r 32
      :focused-x (get col-xs focus-ci) :focused-col-w cw
      :focused-col-idx focus-ci :num-cols 4
      :current-scroll 0))
    (assert (>= scroll 0)
      (string/format "focus col %d: scroll >= 0" focus-ci))
    (assert (<= scroll max-scroll)
      (string/format "focus col %d: scroll <= max-scroll" focus-ci))))

(test "e2e: focused column always within preferred zone"
  (def cols (make-cols 4))
  (def col-xs (col-x-positions cols total-w 0.5))
  (def tcw (total-content-width cols col-xs total-w 0.5))
  (def strut-l 32)
  (def strut-r 32)
  (def num-cols 4)

  (for focus-ci 0 num-cols
    (def cw (col-width (get cols focus-ci) total-w 0.5))
    (def focused-x (get col-xs focus-ci))
    (def scroll (compute-scroll-target
      :total-w total-w :total-content-w tcw
      :strut-l strut-l :strut-r strut-r
      :focused-x focused-x :focused-col-w cw
      :focused-col-idx focus-ci :num-cols num-cols
      :current-scroll 0))
    # Effective struts: disabled for edge columns
    (def eff-strut-l (if (> focus-ci 0) strut-l 0))
    (def eff-strut-r (if (< focus-ci (- num-cols 1)) strut-r 0))
    (def zone-left (+ scroll eff-strut-l))
    (def zone-right (- (+ scroll total-w) eff-strut-r))
    # Focused column should always be within zone
    (assert (>= focused-x zone-left)
      (string/format "focus col %d: left edge %d >= zone-left %d"
        focus-ci focused-x zone-left))
    (assert (<= (+ focused-x cw) (+ zone-right 1))
      (string/format "focus col %d: right edge %d <= zone-right %d"
        focus-ci (+ focused-x cw) zone-right))))

# ============================================================
# Report
# ============================================================

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
