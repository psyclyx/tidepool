(defn ease-out-cubic
  "Cubic ease-out easing function."
  [t]
  (- 1 (math/pow (- 1 t) 3)))

(defn start
  "Start an animation on a window (:open, :close, or :move)."
  [window type props now config]
  (when (config :animate)
    (def duration (config :animation-duration))
    (when (and duration (> duration 0))
      (put window :anim (merge @{:type type
                                  :start now
                                  :duration duration}
                                props)))))

(defn tick
  ``Advance a window's animation by one frame. Pure: stores computed values
  on the window table (:x/:y for moves, :anim-clip for clips). Returns true if active.``
  [window now]
  (when-let [anim (window :anim)]
    (def dur (anim :duration))
    (def t (if (> dur 0) (min 1.0 (/ (- now (anim :start)) dur)) 1.0))
    (def e (ease-out-cubic t))
    (if (>= t 1.0)
      (do (put window :anim nil)
          (if (= (anim :type) :close)
            (put window :anim-destroy true)
            (put window :anim-clip :clear))
          false)
      (do
        (when (and (anim :from-x) (anim :to-x))
          (def x (math/round (+ (anim :from-x) (* e (- (anim :to-x) (anim :from-x))))))
          (def y (math/round (+ (anim :from-y) (* e (- (anim :to-y) (anim :from-y))))))
          (put window :x x)
          (put window :y y))
        (when (anim :clip-from)
          (def [cx cy cw ch] (anim :clip-from))
          (def [tx ty tw th] (anim :clip-to))
          (put window :anim-clip
            [(math/round (+ cx (* e (- tx cx))))
             (math/round (+ cy (* e (- ty cy))))
             (math/round (+ cw (* e (- tw cw))))
             (math/round (+ ch (* e (- th ch))))]))
        true))))

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
  "Update an in-progress scroll animation by one frame. Returns true if active."
  [params key now]
  (def anim-key (keyword (string key "-anim")))
  (when-let [anim (params anim-key)]
    (def dur (anim :duration))
    (def t (if (> dur 0) (min 1.0 (/ (- now (anim :start)) dur)) 1.0))
    (def e (ease-out-cubic t))
    (def val (+ (anim :from) (* e (- (anim :to) (anim :from)))))
    (put params key (math/round val))
    (if (>= t 1.0)
      (do (put params key (anim :to))
          (put params anim-key nil))
      true)))
