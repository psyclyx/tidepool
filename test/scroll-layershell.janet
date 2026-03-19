# Tests for scroll layout behavior during layer shell changes.
#
# Simulates the scenario where a layer shell surface (e.g. launcher overlay)
# causes the usable area to change, potentially hiding all windows.

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

# --- Test fixtures ---

(def output {:x 0 :y 0 :w 1920 :h 1080})
(def output-bounds [(output :x) (output :y) (output :w) (output :h)])

# Usable area with a 44px top bar
(def usable-with-bar {:x 0 :y 44 :w 1920 :h 1036})

# Full output as usable (no layer shell)
(def usable-full {:x 0 :y 0 :w 1920 :h 1080})

(def base-config @{:outer-padding 4 :inner-padding 8 :border-width 2
                   :column-row-height 0 :animate false})

(defn make-params [&opt overrides]
  (def p @{:column-width 0.5 :scroll-offset 0 :active-row 0
           :output-bounds output-bounds})
  (when overrides (merge-into p overrides))
  p)

(defn make-windows [n]
  (seq [i :range [0 n]] @{:row 0}))

(defn count-visible [results]
  (length (filter |(not ($ :hidden)) results)))

(defn count-hidden [results]
  (length (filter |($ :hidden) results)))

(defn any-visible? [results]
  (> (count-visible results) 0))

# --- Basic sanity ---

(test "sanity: single window visible with bar"
  (def wins (make-windows 1))
  (def params (make-params))
  (def results (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert= (count-visible results) 1 "single window should be visible")
  (assert= (count-hidden results) 0 "no hidden windows"))

(test "sanity: 3 windows visible with bar"
  (def wins (make-windows 3))
  (def params (make-params))
  (def results (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert-true (any-visible? results) "at least one window visible"))

(test "sanity: focused window always visible"
  (def wins (make-windows 5))
  (each w wins (put w :column nil))
  (for i 0 5
    (def params (make-params))
    (each w wins (put w :column nil))
    (def results (scroll/layout usable-with-bar wins params base-config (get wins i)))
    (def focused-result (find |(= ($ :window) (get wins i)) results))
    (assert-true focused-result (string/format "focused window %d has a result" i))
    (assert-false (focused-result :hidden) (string/format "focused window %d is visible" i))))

# --- Layer shell scenarios ---

(test "layer-shell: zero-height usable area with output-bounds — windows visible"
  (def usable-zero-h {:x 0 :y 0 :w 1920 :h 0})
  (def wins (make-windows 2))
  (def params (make-params))
  (def results (scroll/layout usable-zero-h wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "windows should be visible when clipping against output bounds"))

(test "layer-shell: zero-width usable area with output-bounds — windows visible"
  (def usable-zero-w {:x 0 :y 0 :w 0 :h 1080})
  (def wins (make-windows 2))
  (def params (make-params))
  (def results (scroll/layout usable-zero-w wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "windows should be visible when clipping against output bounds"))

(test "layer-shell: completely zero usable area with output-bounds — windows visible"
  (def usable-zero {:x 0 :y 0 :w 0 :h 0})
  (def wins (make-windows 2))
  (def params (make-params))
  (def results (scroll/layout usable-zero wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "windows should be visible with zero usable area"))

(test "layer-shell: usable area smaller than padding with output-bounds — windows visible"
  (def usable-tiny {:x 0 :y 0 :w 10 :h 10})
  (def wins (make-windows 2))
  (def params (make-params))
  (def results (scroll/layout usable-tiny wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "windows should survive tiny usable area"))

# --- Focus loss scenarios ---

(test "focus-loss: no focused window — windows still visible"
  (def wins (make-windows 3))
  (def params (make-params))
  (def results (scroll/layout usable-with-bar wins params base-config nil))
  (assert-true (any-visible? results)
    "windows visible even without focus"))

(test "focus-loss: no focus + zero usable area + output-bounds — windows visible"
  (def usable-zero {:x 0 :y 0 :w 0 :h 0})
  (def wins (make-windows 2))
  (def params (make-params))
  (def results (scroll/layout usable-zero wins params base-config nil))
  (assert-true (any-visible? results)
    "no focus + zero usable should still show windows via output bounds"))

# --- Multi-frame simulation ---

(test "multi-frame: usable area shrinks then restores — windows recover"
  (def wins (make-windows 3))
  (def params (make-params))

  # Frame 1: normal
  (each w wins (put w :column nil))
  (def r1 (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert-true (any-visible? r1) "frame 1: visible")

  # Frame 2: usable area goes to zero (layer shell reconfigure)
  (each w wins (put w :column nil))
  (def r2 (scroll/layout {:x 0 :y 0 :w 0 :h 0} wins params base-config nil))
  # With output-bounds, should still be visible
  (assert-true (any-visible? r2) "frame 2: visible despite zero usable")

  # Frame 3: usable area restores
  (each w wins (put w :column nil))
  (def r3 (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert-true (any-visible? r3) "frame 3: visible after restore"))

(test "multi-frame: focus lost during shrink — scroll offset stays valid"
  (def wins (make-windows 3))
  (def params (make-params))

  # Frame 1: normal, scrolled to column 2
  (each w wins (put w :column nil))
  (scroll/layout usable-with-bar wins params base-config (get wins 2))
  (def scroll-after-focus (params :scroll-offset))

  # Frame 2: focus lost, usable area zero
  (each w wins (put w :column nil))
  (scroll/layout {:x 0 :y 0 :w 0 :h 0} wins params base-config nil)
  (assert-true (>= (params :scroll-offset) 0) "scroll offset non-negative")

  # Frame 3: focus restored, usable area back
  (each w wins (put w :column nil))
  (def r3 (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert-true (any-visible? r3) "recovered after focus restore"))

# --- Without output-bounds (fallback) ---

(test "no-output-bounds: falls back to usable area for clipping"
  (def wins (make-windows 2))
  (def params @{:column-width 0.5 :scroll-offset 0 :active-row 0})
  # No :output-bounds in params
  (def results (scroll/layout usable-with-bar wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "should work without output-bounds using usable area"))

(test "no-output-bounds: zero usable area hides windows (expected — no output info)"
  (def wins (make-windows 2))
  (def params @{:column-width 0.5 :scroll-offset 0 :active-row 0})
  # No :output-bounds — this is the OLD behavior, windows will be hidden
  (def results (scroll/layout {:x 0 :y 0 :w 0 :h 0} wins params base-config (first wins)))
  # Without output-bounds, zero usable area WILL hide everything — this is
  # the bug case that output-bounds fixes
  (def vis (count-visible results))
  (printf "  [info] without output-bounds + zero usable: %d visible (expected 0)" vis))

# --- Offset second output ---

(test "second-output: output at x=1920, usable area offset — windows visible"
  (def output2 {:x 1920 :y 0 :w 1920 :h 1080})
  (def usable2 {:x 1920 :y 44 :w 1920 :h 1036})
  (def wins (make-windows 2))
  (def params (make-params {:output-bounds [1920 0 1920 1080]}))
  (def results (scroll/layout usable2 wins params base-config (first wins)))
  (assert-true (any-visible? results) "visible on second output")
  (def visible (filter |(not ($ :hidden)) results))
  (each r visible
    (assert-true (>= (r :x) 1920)
      (string/format "window x=%d should be >= 1920" (r :x)))))

(test "second-output: zero usable on second output with output-bounds — visible"
  (def usable-zero {:x 1920 :y 0 :w 0 :h 0})
  (def wins (make-windows 2))
  (def params (make-params {:output-bounds [1920 0 1920 1080]}))
  (def results (scroll/layout usable-zero wins params base-config (first wins)))
  (assert-true (any-visible? results)
    "output-bounds should save second output too"))

# --- Scroll animation interaction ---

(test "animation: scroll-offset-anim does not override clamp when no focus"
  (def wins (make-windows 2))
  (def params (make-params {:scroll-offset 5000
                            :scroll-offset-anim @{:from 5000 :to 5000
                                                   :start 0 :duration 0.3}}))
  (def config (merge base-config @{:animate true :animation-duration 0.3}))
  (def results (scroll/layout usable-with-bar wins params config nil 0.1))
  # After layout, the scroll offset should have been clamped or the anim
  # should produce a value that keeps windows visible
  (assert-true (any-visible? results)
    "stale animation should not hide all windows"))

# --- Border width config (user's actual config) ---

(test "config: border-width=4 inner=8 outer=4 — matches user setup"
  (def user-config @{:outer-padding 4 :inner-padding 8 :border-width 4
                     :column-row-height 0 :animate false})
  (def wins (make-windows 3))
  (def params (make-params))
  (def results (scroll/layout usable-with-bar wins params user-config (first wins)))
  (assert-true (any-visible? results) "visible with user's config")
  (def visible (filter |(not ($ :hidden)) results))
  (each r visible
    (assert-true (> (r :w) 0) (string/format "window w=%d should be > 0" (r :w)))
    (assert-true (> (r :h) 0) (string/format "window h=%d should be > 0" (r :h)))))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
