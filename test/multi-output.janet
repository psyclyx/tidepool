# Property-based integration tests for multi-output pipeline.
#
# Tests the full pure-data pipeline across multiple outputs:
#   scroll/layout -> apply-geometry -> compute-visibility -> clip-to-output
#
# Catches bugs that per-module tests miss: ghost windows, border leaks,
# cross-output position bleed, clip miscalculations, layout-hidden flag
# interactions.

(import ../src/layout/scroll :as scroll)
(import ../src/layout/init :as layout)
(import ../src/output)
(import ../src/window)

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

(def build-tag-map output/build-tag-map)
(def apply-geometry layout/apply-geometry)
(def compute-visibility window/compute-visibility)
(def clear-layout-state window/clear-layout-state)

# ===================================================================
# Test infrastructure
# ===================================================================

(def base-config @{:outer-padding 4 :inner-padding 8 :border-width 4
                   :column-row-height 0 :animate false})

(defn make-output [x y w h tag &opt bar-h]
  @{:x x :y y :w w :h h
    :tags @{tag true}
    :layout :scroll
    :bar-h (or bar-h 0)
    :layout-params @{:column-width 0.5 :scroll-offset 0 :active-row 0}})

(defn make-window [tag]
  @{:tag tag :row 0})

(defn output-usable [o]
  {:x (o :x) :y (+ (o :y) (or (o :bar-h) 0))
   :w (o :w) :h (- (o :h) (or (o :bar-h) 0))})

(defn output-visible [o windows]
  (filter |(and ((o :tags) ($ :tag))
                (not ($ :float)) (not ($ :fullscreen))
                (not ($ :closing)))
          windows))

# ===================================================================
# Pipeline simulation
# ===================================================================

(defn simulate-manage
  "Simulate the manage cycle's pure data operations."
  [outputs all-windows config focused-win &opt col-width]
  (clear-layout-state all-windows)
  (each o outputs
    (def visible (output-visible o all-windows))
    (when (not (empty? visible))
      (def usable (output-usable o))
      (def params (o :layout-params))
      (when col-width (put params :column-width col-width))
      (put params :output-bounds [(o :x) (o :y) (o :w) (o :h)])
      (def focus-here (when (find |(= $ focused-win) visible) focused-win))
      (def results (scroll/layout usable visible params config focus-here))
      (apply-geometry results config)))
  # Simulate compositor confirming proposed dimensions
  (each w all-windows
    (when (and (w :proposed-w) (w :proposed-h))
      (put w :w (w :proposed-w))
      (put w :h (w :proposed-h))))
  (compute-visibility outputs all-windows))

(defn simulate-render
  "Simulate the render cycle's clip-to-output pass."
  [outputs all-windows config]
  (def tag-map (build-tag-map outputs))
  (each w all-windows
    (window/clip-to-output w tag-map config)))

(defn simulate-full
  "Run both manage and render cycles."
  [outputs all-windows config focused-win &opt col-width]
  (simulate-manage outputs all-windows config focused-win col-width)
  (simulate-render outputs all-windows config))

# ===================================================================
# Property assertions
# ===================================================================

(defn find-output-for-window
  "Find the output that owns this window's tag."
  [window outputs]
  (find |(($ :tags) (window :tag)) outputs))

(defn assert-focused-visible [windows focused msg]
  "Focused window must be visible."
  (when focused
    (assert-true (focused :visible)
      (string msg ": focused window not visible"))))

(defn assert-focused-position-in-output [focused outputs bw msg]
  "Focused window's full visual footprint (content + borders) within its output."
  (when (and focused (focused :x) (focused :w) (focused :visible)
             (not (focused :layout-hidden)))
    (when-let [o (find-output-for-window focused outputs)]
      (def visual-right (+ (focused :x) (focused :w) (* 2 bw)))
      (def visual-bottom (+ (focused :y) (focused :h) (* 2 bw)))
      (assert-true (>= (focused :x) (o :x))
        (string/format "%s: focused visual-left=%d < output-left=%d"
          msg (focused :x) (o :x)))
      (assert-true (<= visual-right (+ (o :x) (o :w)))
        (string/format "%s: focused visual-right=%d > output-right=%d"
          msg visual-right (+ (o :x) (o :w))))
      (assert-true (>= (focused :y) (o :y))
        (string/format "%s: focused visual-top=%d < output-top=%d"
          msg (focused :y) (o :y)))
      (assert-true (<= visual-bottom (+ (o :y) (o :h)))
        (string/format "%s: focused visual-bottom=%d > output-bottom=%d"
          msg visual-bottom (+ (o :y) (o :h)))))))

(defn assert-unclipped-within-output [window outputs bw msg]
  "If a visible window has :clear clip, its full visual footprint must be
  within its output. Otherwise borders leak to adjacent monitors."
  (when (and (window :visible) (not (window :float)) (not (window :layout-hidden))
             (window :x) (window :w)
             (= (window :clip-rect) :clear))
    (when-let [o (find-output-for-window window outputs)]
      (def visual-right (+ (window :x) (window :w) (* 2 bw)))
      (def visual-bottom (+ (window :y) (window :h) (* 2 bw)))
      (assert-true (>= (window :x) (o :x))
        (string/format "%s: unclipped visual-left=%d < output-left=%d"
          msg (window :x) (o :x)))
      (assert-true (<= visual-right (+ (o :x) (o :w)))
        (string/format "%s: unclipped visual-right=%d > output-right=%d"
          msg visual-right (+ (o :x) (o :w))))
      (assert-true (>= (window :y) (o :y))
        (string/format "%s: unclipped visual-top=%d < output-top=%d"
          msg (window :y) (o :y)))
      (assert-true (<= visual-bottom (+ (o :y) (o :h)))
        (string/format "%s: unclipped visual-bottom=%d > output-bottom=%d"
          msg visual-bottom (+ (o :y) (o :h)))))))

(defn assert-clip-constrains-to-output [window outputs msg]
  "If clip-rect is set, the visible area must be within the output bounds."
  (when-let [clip (window :clip-rect)]
    (when (and (not= clip :clear) (window :x) (window :w))
      (when-let [o (find-output-for-window window outputs)]
        (def [cx cy cw ch] clip)
        (def vis-left (+ (window :x) cx))
        (def vis-top (+ (window :y) cy))
        (def vis-right (+ vis-left cw))
        (def vis-bottom (+ vis-top ch))
        (assert-true (>= vis-left (o :x))
          (string/format "%s: clip-visible left=%d < output-left=%d"
            msg vis-left (o :x)))
        (assert-true (<= vis-right (+ (o :x) (o :w)))
          (string/format "%s: clip-visible right=%d > output-right=%d"
            msg vis-right (+ (o :x) (o :w))))
        (assert-true (>= vis-top (o :y))
          (string/format "%s: clip-visible top=%d < output-top=%d"
            msg vis-top (o :y)))
        (assert-true (<= vis-bottom (+ (o :y) (o :h)))
          (string/format "%s: clip-visible bottom=%d > output-bottom=%d"
            msg vis-bottom (+ (o :y) (o :h))))))))

(defn assert-clip-covers-visual-overlap [window outputs bw msg]
  "If a window has a clip, the clip must cover the entire portion of the
  visual footprint (content + borders) that overlaps the output. The clip
  must not truncate visible content that is within bounds."
  (when (and (window :visible) (not (window :float)) (not (window :layout-hidden))
             (window :x) (window :w) (window :scroll-placed))
    (when-let [clip (window :clip-rect)]
      (when (not= clip :clear)
        (when-let [o (find-output-for-window window outputs)]
          (def [cx cy cw ch] clip)
          (def vis-right (+ (window :x) cx cw))
          (def vis-bottom (+ (window :y) cy ch))
          (def visual-right (+ (window :x) (window :w) (* 2 bw)))
          (def visual-bottom (+ (window :y) (window :h) (* 2 bw)))
          (def expected-right (min visual-right (+ (o :x) (o :w))))
          (def expected-bottom (min visual-bottom (+ (o :y) (o :h))))
          # The clip's visible right must reach the expected boundary
          (assert-true (>= vis-right expected-right)
            (string/format
              "%s: clip vis-right=%d < expected=%d (visual-right=%d output-right=%d)"
              msg vis-right expected-right visual-right (+ (o :x) (o :w))))
          (assert-true (>= vis-bottom expected-bottom)
            (string/format
              "%s: clip vis-bottom=%d < expected=%d (visual-bottom=%d output-bottom=%d)"
              msg vis-bottom expected-bottom visual-bottom (+ (o :y) (o :h)))))))))

(defn assert-no-cross-output-ghost [window outputs bw msg]
  "A visible window's visible area must not be entirely within a DIFFERENT
  output's bounds. (Guards against ghost windows on wrong monitor.)"
  (when (and (window :visible) (window :x) (window :w))
    (def owner (find-output-for-window window outputs))
    (def clip (window :clip-rect))
    (var vis-left (window :x))
    (var vis-top (window :y))
    (var vis-right (+ (window :x) (window :w) (* 2 bw)))
    (var vis-bottom (+ (window :y) (window :h) (* 2 bw)))
    (when (and clip (not= clip :clear))
      (def [cx cy cw ch] clip)
      (set vis-left (+ (window :x) cx))
      (set vis-top (+ (window :y) cy))
      (set vis-right (+ vis-left cw))
      (set vis-bottom (+ vis-top ch)))
    (each o outputs
      (when (not= o owner)
        (def entirely-within
          (and (>= vis-left (o :x))
               (<= vis-right (+ (o :x) (o :w)))
               (>= vis-top (o :y))
               (<= vis-bottom (+ (o :y) (o :h)))))
        (assert-false entirely-within
          (string/format "%s: window ghost entirely within wrong output at (%d,%d)"
            msg (o :x) (o :y)))))))

(defn assert-visibility-correct [window outputs msg]
  "Windows on active tags should be visible (unless layout-hidden).
  Windows on inactive tags should not be visible."
  (def all-tags @{})
  (each o outputs (merge-into all-tags (o :tags)))
  (if (all-tags (window :tag))
    (when (not (window :layout-hidden))
      (assert-true (window :visible)
        (string msg ": window on active tag should be visible")))
    (assert-false (window :visible)
      (string msg ": window on inactive tag should not be visible"))))

(defn assert-all-properties [outputs windows focused bw msg]
  "Run all property assertions on a post-pipeline state."
  (assert-focused-visible windows focused msg)
  (assert-focused-position-in-output focused outputs bw msg)
  (each w windows
    (assert-unclipped-within-output w outputs bw msg)
    (assert-clip-constrains-to-output w outputs msg)
    (assert-clip-covers-visual-overlap w outputs bw msg)
    (assert-no-cross-output-ghost w outputs bw msg)
    (assert-visibility-correct w outputs msg)))

# ===================================================================
# Output definitions
# ===================================================================

(def dual-equal
  "Two 1920x1080 outputs side by side."
  [(make-output 0 0 1920 1080 1)
   (make-output 1920 0 1920 1080 2)])

(def dual-equal-bar
  "Two 1920x1080 outputs side by side, each with a 44px status bar."
  [(make-output 0 0 1920 1080 1 44)
   (make-output 1920 0 1920 1080 2 44)])

(def big-small
  "3840x2560 left + 1920x1080 right."
  [(make-output 0 0 3840 2560 1)
   (make-output 3840 0 1920 1080 2)])

(def stacked
  "Two 1920x1080 outputs vertically stacked."
  [(make-output 0 0 1920 1080 1)
   (make-output 0 1080 1920 1080 2)])

(def triple
  "Three 1920x1080 outputs in a row."
  [(make-output 0 0 1920 1080 1)
   (make-output 1920 0 1920 1080 2)
   (make-output 3840 0 1920 1080 3)])

(def offset-y
  "Two outputs, second offset vertically."
  [(make-output 0 0 1920 1080 1)
   (make-output 1920 500 1920 1080 2)])

# ===================================================================
# Multi-output integration tests
# ===================================================================

(test "integration: dual equal, 2 windows per output"
  (def outputs (map table/clone dual-equal))
  (def w1 (make-window 1))
  (def w2 (make-window 1))
  (def w3 (make-window 2))
  (def w4 (make-window 2))
  (def all @[w1 w2 w3 w4])
  (simulate-full outputs all base-config w1)
  (assert-all-properties outputs all w1 (base-config :border-width)
    "dual-2per"))

(test "integration: dual equal with bar, 3 windows per output"
  (def outputs (map table/clone dual-equal-bar))
  (def all @[(make-window 1) (make-window 1) (make-window 1)
             (make-window 2) (make-window 2) (make-window 2)])
  (simulate-full outputs all base-config (first all))
  (assert-all-properties outputs all (first all) (base-config :border-width)
    "dual-bar-3per"))

(test "integration: big-small, focus on small output"
  (def outputs (map table/clone big-small))
  (def all @[(make-window 1) (make-window 1)
             (make-window 2) (make-window 2) (make-window 2)])
  (def focused (get all 2))
  (simulate-full outputs all base-config focused)
  (assert-all-properties outputs all focused (base-config :border-width)
    "big-small-focus-right"))

(test "integration: stacked outputs, focus bottom"
  (def outputs (map table/clone stacked))
  (def all @[(make-window 1) (make-window 1)
             (make-window 2) (make-window 2)])
  (def focused (get all 2))
  (simulate-full outputs all base-config focused)
  (assert-all-properties outputs all focused (base-config :border-width)
    "stacked-focus-bottom")
  # Bottom output windows must have y >= 1080
  (each w (filter |(and (= ($ :tag) 2) ($ :visible)) all)
    (assert-true (>= (w :y) 1080)
      (string/format "stacked: bottom-output window y=%d < 1080" (w :y)))))

(test "integration: triple outputs, focus middle"
  (def outputs (map table/clone triple))
  (def all @[(make-window 1) (make-window 1)
             (make-window 2) (make-window 2)
             (make-window 3) (make-window 3)])
  (def focused (get all 2))
  (simulate-full outputs all base-config focused)
  (assert-all-properties outputs all focused (base-config :border-width)
    "triple-focus-mid"))

(test "integration: y-offset outputs"
  (def outputs (map table/clone offset-y))
  (def all @[(make-window 1) (make-window 1)
             (make-window 2) (make-window 2)])
  (simulate-full outputs all base-config (first all))
  (assert-all-properties outputs all (first all) (base-config :border-width)
    "offset-y"))

# ===================================================================
# Cross-output isolation
# ===================================================================

(test "isolation: layout on output 1 doesn't affect output 2 windows"
  (def outputs (map table/clone dual-equal))
  (def w1 (make-window 1))
  (def w2 (make-window 2))
  (def all @[w1 w2])
  (simulate-full outputs all base-config w1)
  # w2 should be on output 2 (x >= 1920)
  (assert-true (>= (w2 :x) 1920)
    (string/format "isolation: w2 x=%d < 1920" (w2 :x)))
  # w1 should be on output 1 (x < 1920)
  (assert-true (< (w1 :x) 1920)
    (string/format "isolation: w1 x=%d >= 1920" (w1 :x))))

(test "isolation: changing scroll on output 1 doesn't affect output 2"
  (def outputs (map table/clone dual-equal))
  (def wins-1 @[(make-window 1) (make-window 1) (make-window 1)
                (make-window 1) (make-window 1)])
  (def wins-2 @[(make-window 2) (make-window 2)])
  (def all (array/concat @[] wins-1 wins-2))
  # Focus last window on output 1 to force scrolling
  (simulate-full outputs all base-config (last wins-1))
  (def scroll-1 (get-in outputs [0 :layout-params :scroll-offset]))
  (def scroll-2 (get-in outputs [1 :layout-params :scroll-offset]))
  (assert-true (> scroll-1 0) "output 1 scrolled")
  (assert= scroll-2 0 "output 2 not scrolled"))

(test "isolation: column assignments independent per output"
  (def outputs (map table/clone dual-equal))
  (def wins-1 @[(make-window 1) (make-window 1) (make-window 1)])
  (def wins-2 @[(make-window 2) (make-window 2)])
  (def all (array/concat @[] wins-1 wins-2))
  (simulate-full outputs all base-config (first wins-1))
  (def cols-1 (map |($ :column) wins-1))
  (def cols-2 (map |($ :column) wins-2))
  (assert= (length (distinct cols-1)) 3 "output 1 has 3 columns")
  (assert= (length (distinct cols-2)) 2 "output 2 has 2 columns"))

# ===================================================================
# Visibility and layout-hidden interaction
# ===================================================================

(test "visibility: windows on inactive tags are not visible"
  (def outputs (map table/clone dual-equal))
  (def w-active (make-window 1))
  (def w-inactive (make-window 5))
  (def all @[w-active w-inactive])
  (simulate-full outputs all base-config w-active)
  (assert-true (w-active :visible) "active tag window visible")
  (assert-false (w-inactive :visible) "inactive tag window not visible"))

(test "visibility: layout-hidden window on active tag is not visible"
  (def outputs (map table/clone dual-equal))
  # 5 columns on output 1 — some will be scrolled offscreen
  (def wins @[(make-window 1) (make-window 1) (make-window 1)
              (make-window 1) (make-window 1)])
  (def all (array/concat @[] wins @[(make-window 2)]))
  (simulate-manage outputs all base-config (first wins))
  (def hidden (filter |(and (= ($ :tag) 1) ($ :layout-hidden)) wins))
  (each w hidden
    (assert-false (w :visible) "layout-hidden window should not be visible")))

# ===================================================================
# Property sweep: outputs x columns x focus x column-width x bar
# ===================================================================

(def sweep-output-setups
  [# [name, outputs-fn]
   ["dual-equal" |(map table/clone dual-equal)]
   ["dual-bar" |(map table/clone dual-equal-bar)]
   ["big-small" |(map table/clone big-small)]
   ["stacked" |(map table/clone stacked)]
   ["triple" |(map table/clone triple)]
   ["offset-y" |(map table/clone offset-y)]])

(def sweep-col-widths [0.25 0.333 0.5 0.667 0.8 1.0])

(test "property sweep: outputs x 1-5 cols x focus x column-widths"
  (each [setup-name make-outputs] sweep-output-setups
    (each cw sweep-col-widths
      (for ncols 1 6
        (def outputs (make-outputs))
        # Create windows for each output's tag
        (def all @[])
        (each o outputs
          (def tag (min-of (keys (o :tags))))
          (for i 0 ncols
            (array/push all (make-window tag))))
        # Test each focus position on each output
        (each o outputs
          (def tag (min-of (keys (o :tags))))
          (def tag-wins (filter |(= ($ :tag) tag) all))
          (for fi 0 (min ncols (length tag-wins))
            # Reset column assignments
            (each w all (put w :column nil))
            # Fresh params
            (each o2 outputs
              (put o2 :layout-params
                @{:column-width cw :scroll-offset 0 :active-row 0}))
            (def focused (get tag-wins fi))
            (simulate-full outputs all base-config focused cw)
            (def msg (string/format "%s/cw%.2f/%dc/t%d/f%d"
                       setup-name cw ncols tag fi))
            (assert-all-properties outputs all focused
              (base-config :border-width) msg)))))))

# ===================================================================
# Clip-to-output specific tests
# ===================================================================

(test "clip: peeking window on output 2 — clip constrains to output"
  (def outputs (map table/clone dual-equal))
  (def wins @[(make-window 2) (make-window 2) (make-window 2)])
  (def all (array/concat @[] @[(make-window 1)] wins))
  # Focus rightmost column to scroll, making col 0 peek
  (simulate-full outputs all base-config (last wins))
  (each w wins
    (assert-clip-constrains-to-output w outputs "peek-right")))

(test "clip: all visible windows have clip set (not nil)"
  (def outputs (map table/clone dual-equal))
  (def all @[(make-window 1) (make-window 1) (make-window 1)
             (make-window 2) (make-window 2) (make-window 2)])
  (simulate-full outputs all base-config (first all))
  (each w (filter |(and ($ :visible) ($ :x) ($ :w)) all)
    (assert-true (not (nil? (w :clip-rect)))
      (string/format "clip: visible window at x=%d missing clip-rect" (w :x)))))

(test "clip: focused window on output 2 is unclipped and within bounds"
  (def outputs (map table/clone dual-equal))
  (def focused (make-window 2))
  (def all @[(make-window 1) focused])
  (simulate-full outputs all base-config focused)
  (assert= (focused :clip-rect) :clear "focused on output 2 should be :clear")
  (assert-unclipped-within-output focused outputs (base-config :border-width)
    "focused-output2"))

# ===================================================================
# Second frame simulation (column persistence)
# ===================================================================

(test "multi-frame: column order preserved across frames"
  (def outputs (map table/clone dual-equal))
  (def all @[(make-window 1) (make-window 1) (make-window 1)
             (make-window 2) (make-window 2)])
  (simulate-full outputs all base-config (first all))
  (def cols-1 (map |($ :column) (filter |(= ($ :tag) 1) all)))
  # Second frame (don't reset columns)
  (simulate-full outputs all base-config (first all))
  (def cols-2 (map |($ :column) (filter |(= ($ :tag) 1) all)))
  (assert (deep= cols-1 cols-2) "columns stable across frames"))

(test "multi-frame: focus change on output 2 doesn't affect output 1"
  (def outputs (map table/clone dual-equal))
  (def w1a (make-window 1))
  (def w1b (make-window 1))
  (def w2a (make-window 2))
  (def w2b (make-window 2))
  (def all @[w1a w1b w2a w2b])
  # Frame 1: focus on output 1
  (simulate-full outputs all base-config w1a)
  (def w1a-x1 (w1a :x))
  (def w1a-y1 (w1a :y))
  # Frame 2: focus switches to output 2
  (simulate-full outputs all base-config w2a)
  (assert= (w1a :x) w1a-x1 "output 1 window x unchanged")
  (assert= (w1a :y) w1a-y1 "output 1 window y unchanged"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
