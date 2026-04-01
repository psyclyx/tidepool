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
#   @{:x <spring> :y <spring> :w <spring> :h <spring> :open <spring> :close <spring>}

(defn init-window-anim
  "Initialize animation state on a window if not present."
  [w]
  (unless (w :anim)
    (put w :anim @{})))

(defn set-targets
  "Set animation targets for a window from layout results.
   Compares against current targets to detect changes."
  [w x y width height duration]
  (init-window-anim w)
  (def a (w :anim))

  # For each property, retarget if target changed
  (defn update-prop [key new-val rest-pos]
    (def existing (a key))
    (def current-target
      (if existing (existing :target) rest-pos))
    (when (or (nil? current-target) (not (close-enough? current-target new-val)))
      (put a key (retarget existing new-val duration rest-pos))))

  (update-prop :x x (w :x))
  (update-prop :y y (w :y))
  (update-prop :w width (w :w))
  (update-prop :h height (w :h)))

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
    (or (a :x) (a :y) (a :w) (a :h) (a :open) (a :close))))

# --- Tick ---

(defn tick-window
  "Advance all animations on a window by dt ms. Returns true if still animating."
  [w dt ease-fn]
  (when-let [a (w :anim)]
    (var active false)

    (each key [:x :y :w :h]
      (when-let [spring (a key)]
        (if-let [updated (advance spring dt ease-fn)]
          (set active true)
          # Done — snap to target
          (do (put a key nil)
              (case key
                :x (put w :anim-x nil)
                :y (put w :anim-y nil)
                :w (put w :anim-w nil)
                :h (put w :anim-h nil))))))

    # Compute current animated values from active springs
    (when (a :x) (put w :anim-x ((a :x) :current)))
    (when (a :y) (put w :anim-y ((a :y) :current)))
    (when (a :w) (put w :anim-w ((a :w) :current)))
    (when (a :h) (put w :anim-h ((a :h) :current)))

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
  "Set camera animation target for a tag."
  [tag new-cam duration]
  (def current-target
    (if-let [spring (tag :camera-anim)]
      (spring :target)
      (tag :camera)))
  (when (not (close-enough? current-target new-cam))
    (put tag :camera-anim
      (retarget (tag :camera-anim) new-cam duration (tag :camera)))))

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

(defn resolve-position
  "Get the visual position for a window (animated or target)."
  [w]
  [(or (w :anim-x) (w :x))
   (or (w :anim-y) (w :y))])

(defn resolve-dimensions
  "Get the visual dimensions for a window (animated or target)."
  [w]
  [(or (w :anim-w) (w :w))
   (or (w :anim-h) (w :h))])
