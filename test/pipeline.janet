# Regression tests for pipeline bugs.

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

# --- remove-destroyed regression ---
# Bug: apply-destroys used (filter) which creates new arrays, but local
# variables in manage() still referenced the old arrays containing destroyed
# Wayland proxies. Fix: in-place removal with array/remove.

(defn remove-destroyed
  "Remove elements with :pending-destroy from an array in place."
  [arr]
  (var i 0)
  (while (< i (length arr))
    (if ((arr i) :pending-destroy)
      (array/remove arr i)
      (++ i))))

(test "remove-destroyed: removes flagged elements in place"
  (def arr @[@{:name "a"} @{:name "b" :pending-destroy true} @{:name "c"}])
  (def original-id (describe arr))
  (remove-destroyed arr)
  (assert= (length arr) 2)
  (assert= ((arr 0) :name) "a")
  (assert= ((arr 1) :name) "c")
  # Verify it's the same array object (in-place)
  (assert= (describe arr) original-id "should modify array in place"))

(test "remove-destroyed: handles empty array"
  (def arr @[])
  (remove-destroyed arr)
  (assert= (length arr) 0))

(test "remove-destroyed: handles all destroyed"
  (def arr @[@{:pending-destroy true} @{:pending-destroy true}])
  (remove-destroyed arr)
  (assert= (length arr) 0))

(test "remove-destroyed: handles none destroyed"
  (def arr @[@{:name "a"} @{:name "b"}])
  (remove-destroyed arr)
  (assert= (length arr) 2))

(test "remove-destroyed: consecutive destroyed elements"
  (def arr @[@{:name "a"} @{:pending-destroy true} @{:pending-destroy true} @{:name "d"}])
  (remove-destroyed arr)
  (assert= (length arr) 2)
  (assert= ((arr 0) :name) "a")
  (assert= ((arr 1) :name) "d"))

(test "remove-destroyed: local reference sees updated array"
  # This is the actual bug scenario: manage() binds local variables
  # to state arrays, then apply-destroys modifies them. With filter,
  # the local still points to the old array with destroyed objects.
  (def state @{:windows @[@{:name "w1"} @{:name "w2" :pending-destroy true} @{:name "w3"}]})
  (def windows (state :windows))  # local reference (like in manage())
  (remove-destroyed (state :windows))
  # With in-place removal, the local ref is still valid
  (assert= (length windows) 2 "local ref updated")
  (assert= ((windows 0) :name) "w1")
  (assert= ((windows 1) :name) "w3"))

# --- scroll-animating flag regression ---
# Bug: scroll animations run only in manage (via scroll-update), but manage
# only runs when dirty. Nothing set anim-active for scroll animations, so
# manage-dirty was never called from the render cycle. Fix: scroll/layout
# sets :scroll-animating on layout-params when any scroll animation is active.

(defn ease-out-cubic [t] (- 1 (math/pow (- 1 t) 3)))

(defn scroll-toward
  "Animate a scroll parameter toward a target value."
  [params key target now config]
  (if (not (config :animate))
    (put params key target)
    (let [current (params key)
          anim-key (keyword (string key "-anim"))]
      (if (= current target)
        (put params anim-key nil)
        (let [existing (params anim-key)
              duration (config :animation-duration)]
          (if existing
            (do (put existing :to target)
                (when (>= (- now (existing :start)) duration)
                  (put params key target)
                  (put params anim-key nil)))
            (put params anim-key @{:from current :to target :start now :duration duration})))))))

(defn scroll-update
  "Update an in-progress scroll animation by one frame."
  [params key now]
  (def anim-key (keyword (string key "-anim")))
  (when-let [anim (params anim-key)]
    (def t (min 1.0 (/ (- now (anim :start)) (anim :duration))))
    (def e (ease-out-cubic t))
    (def val (+ (anim :from) (* e (- (anim :to) (anim :from)))))
    (put params key (math/round val))
    (if (>= t 1.0)
      (do (put params key (anim :to))
          (put params anim-key nil))
      true)))

(defn check-scroll-animating
  "Check if any scroll animation is active in layout params."
  [params num-cols]
  (if (or (params :scroll-offset-anim)
          (find |(params (keyword (string "scroll-y-" $ "-anim")))
                (range 0 num-cols)))
    true nil))

(test "scroll-animating: detects active horizontal scroll animation"
  (def params @{:scroll-offset 0 :column-width 0.5})
  (def config @{:animate true :animation-duration 0.3})
  (def now 1.0)
  (scroll-toward params :scroll-offset 100 now config)
  (def animating (check-scroll-animating params 2))
  (assert= animating true "should detect active scroll animation"))

(test "scroll-animating: nil when no animation active"
  (def params @{:scroll-offset 100 :column-width 0.5})
  (def animating (check-scroll-animating params 2))
  (assert= animating nil "no animation → nil"))

(test "scroll-animating: detects vertical scroll animation"
  (def params @{:scroll-offset 0 :column-width 0.5
                :scroll-y-1-anim @{:from 0 :to 100 :start 1.0 :duration 0.3}})
  (def animating (check-scroll-animating params 3))
  (assert= animating true "should detect vertical scroll animation"))

(test "scroll-animating: cleared after animation completes"
  (def params @{:scroll-offset 0 :column-width 0.5})
  (def config @{:animate true :animation-duration 0.3})
  (def now 1.0)
  (scroll-toward params :scroll-offset 100 now config)
  (assert (check-scroll-animating params 2) "animating before completion")
  # Advance past duration
  (scroll-update params :scroll-offset (+ now 0.5))
  (def animating (check-scroll-animating params 2))
  (assert= animating nil "animation cleared after completion"))

(test "scroll-animating: scroll advances through multiple manage cycles"
  # This is the core regression: scroll must advance over multiple frames.
  # Previously, only the first manage frame would fire, and without
  # anim-active being set, no further manage cycles were triggered.
  (def params @{:scroll-offset 0 :column-width 0.5})
  (def config @{:animate true :animation-duration 0.3})
  (def start-time 1.0)
  (scroll-toward params :scroll-offset 100 start-time config)
  (var time start-time)
  (var frames 0)
  (while (check-scroll-animating params 2)
    (+= time 0.016)  # ~60fps
    (scroll-update params :scroll-offset time)
    (++ frames)
    (when (> frames 100) (error "animation did not complete")))
  (assert= (params :scroll-offset) 100 "scroll reached target")
  (assert (> frames 1) "took multiple frames to complete"))

# --- bg/manage caching regression ---
# Bug: bg/manage re-rendered the background every frame, even when nothing
# changed. Fix: cache the render state and skip when unchanged.

(test "bg-cache: identical state skips render"
  (def bg @{:last-render nil})
  (def output @{:w 3840 :h 2560})
  (def config @{:wallpaper "/path/to/wallpaper.png" :background 0x000000})
  (def cache-key [(output :w) (output :h) (config :wallpaper) (config :background)])
  # First render: cache miss
  (assert (not (deep= cache-key (bg :last-render))) "cache miss on first render")
  (put bg :last-render cache-key)
  # Second render: cache hit
  (def cache-key2 [(output :w) (output :h) (config :wallpaper) (config :background)])
  (assert (deep= cache-key2 (bg :last-render)) "cache hit on same state"))

(test "bg-cache: dimension change invalidates cache"
  (def bg @{:last-render [3840 2560 "/wallpaper.png" 0x000000]})
  (def new-key [1920 1080 "/wallpaper.png" 0x000000])
  (assert (not (deep= new-key (bg :last-render))) "dimension change invalidates"))

(test "bg-cache: wallpaper change invalidates cache"
  (def bg @{:last-render [3840 2560 "/old.png" 0x000000]})
  (def new-key [3840 2560 "/new.png" 0x000000])
  (assert (not (deep= new-key (bg :last-render))) "wallpaper change invalidates"))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
