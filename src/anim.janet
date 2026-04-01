# Animation system. Interpolates between target and current positions.
# Layout sets targets; animation advances current toward targets each frame.

# --- Easing functions ---
# All take t in [0,1], return eased value in [0,1].

(defn ease-out-cubic [t]
  (def s (- 1 t))
  (- 1 (* s s s)))

(defn ease-out-quad [t]
  (def s (- 1 t))
  (- 1 (* s s)))

(defn linear [t] t)

(def easing-fns
  {:ease-out-cubic ease-out-cubic
   :ease-out-quad ease-out-quad
   :linear linear})

# --- Core math ---

(defn lerp [a b t]
  (+ a (* (- b a) t)))

(defn close-enough?
  "Is the value close enough to target to snap?"
  [current target &opt epsilon]
  (< (math/abs (- current target)) (or epsilon 0.5)))

# --- Per-property animation state ---
# Each animated property is a table:
#   {:start <num> :target <num> :current <num> :elapsed 0 :duration <ms>}
# nil means "not animating, at rest"

(defn make-spring
  "Create an animation state for a property."
  [from to duration]
  (if (close-enough? from to)
    nil
    @{:start from :target to :current from :elapsed 0 :duration duration}))

(defn retarget
  "Update an existing animation's target, keeping current position as new start.
   rest-pos is used as current when there's no existing spring.
   Returns new spring or nil if already at target."
  [spring new-target duration &opt rest-pos]
  (def current (if spring (spring :current) (or rest-pos new-target)))
  (make-spring current new-target duration))

(defn advance
  "Advance a spring by dt milliseconds. Returns updated spring or nil if done."
  [spring dt ease-fn]
  (when spring
    (def elapsed (+ (spring :elapsed) dt))
    (def dur (spring :duration))
    (if (>= elapsed dur)
      nil  # done — caller should snap to target
      (do
        (put spring :elapsed elapsed)
        (def t (ease-fn (/ elapsed dur)))
        (put spring :current (lerp (spring :start) (spring :target) t))
        spring))))

# --- Window animation state ---
# Stored on each window as :anim table:
#   @{:y <spring> :w <spring> :h <spring> :open <spring> :close <spring>}
# Note: x position is camera-driven, not per-window animated.

(defn init-window-anim
  "Initialize animation state on a window if not present."
  [w]
  (unless (w :anim)
    (put w :anim @{})))

(defn set-targets
  "Set animation targets for a window's y/w/h from layout results.
   prev-* are the previous values (start of animation).
   x position is not animated per-window — it's driven by camera."
  [w y width height duration prev-y prev-w prev-h]
  (init-window-anim w)
  (def a (w :anim))

  (defn update-prop [key new-val rest-pos]
    (def existing (a key))
    (def effective-rest (or rest-pos (when existing (existing :current))))
    (def current-target
      (if existing (existing :target) effective-rest))
    (when (and new-val
               (or (nil? current-target) (not (close-enough? current-target new-val))))
      (put a key (retarget existing new-val duration effective-rest))))

  (update-prop :y y prev-y)
  (update-prop :w width prev-w)
  (update-prop :h height prev-h))

(defn start-open
  "Start an open animation for a new window."
  [w duration]
  (init-window-anim w)
  (put-in w [:anim :open] (make-spring 0 1 duration)))

(defn start-close
  "Start a close animation. Window stays visible until animation completes."
  [w duration]
  (init-window-anim w)
  (put-in w [:anim :close] (make-spring 0 1 duration))
  (put w :closing true))

(defn animating?
  "Is any animation active on this window?"
  [w]
  (when-let [a (w :anim)]
    (or (a :y) (a :w) (a :h) (a :open) (a :close))))

# --- Tick ---

(defn tick-window
  "Advance all animations on a window by dt ms. Returns true if still animating."
  [w dt ease-fn]
  (when-let [a (w :anim)]
    (var active false)

    (each key [:y :w :h]
      (when-let [spring (a key)]
        (if (advance spring dt ease-fn)
          (set active true)
          (put a key nil))))

    # Open animation
    (when-let [spring (a :open)]
      (if (advance spring dt ease-fn)
        (set active true)
        (put a :open nil)))

    # Close animation
    (when-let [spring (a :close)]
      (if (advance spring dt ease-fn)
        (set active true)
        (do (put a :close nil)
            (put w :closing false))))

    active))

# --- Camera animation ---
# Stored on tag as :camera-anim spring.

(defn set-camera-target
  "Set camera animation target for a tag.
   prev-cam is the camera value before layout updated it."
  [tag new-cam duration &opt prev-cam]
  (def rest-pos (or prev-cam new-cam))
  (def current-target
    (if-let [spring (tag :camera-anim)]
      (spring :target)
      rest-pos))
  (when (not (close-enough? current-target new-cam))
    (def spring (retarget (tag :camera-anim) new-cam duration rest-pos))
    (put tag :camera-anim spring)
    (when spring
      (put tag :camera-visual (spring :current)))))

(defn tick-camera
  "Advance camera animation. Returns true if still animating."
  [tag dt ease-fn]
  (when-let [spring (tag :camera-anim)]
    (if (advance spring dt ease-fn)
      (do (put tag :camera-visual (spring :current))
          true)
      (do (put tag :camera-anim nil)
          (put tag :camera-visual (tag :camera))
          false))))

# --- Pipeline integration helpers ---

(defn any-animating?
  "Check if any window or camera is animating."
  [ctx]
  (var active false)
  (each w (ctx :windows)
    (when (animating? w) (set active true)))
  (eachp [_ tag] (ctx :tags)
    (when (tag :camera-anim) (set active true)))
  active)

(defn spring-value
  "Get animated value for a property, falling back to the window's value."
  [w key fallback]
  (if-let [s (get-in w [:anim key])]
    (s :current)
    (w fallback)))

(defn resolve-y
  "Get the visual y position for a window (animated or target)."
  [w]
  (spring-value w :y :y))

(defn resolve-dimensions
  "Get the visual dimensions for a window (animated or target)."
  [w]
  [(spring-value w :w :w)
   (spring-value w :h :h)])
