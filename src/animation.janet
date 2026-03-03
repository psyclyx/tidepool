# Animation system: easing, window animations, scroll animations.

(import ./state)

(defn ease-out-cubic [t] (- 1 (math/pow (- 1 t) 3)))

(defn start [window type props]
  (when (state/config :animate)
    (put window :anim (merge @{:type type
                                :start (os/clock)
                                :duration (state/config :animation-duration)}
                              props))))

(defn tick [window]
  (when-let [anim (window :anim)]
    (def t (min 1.0 (/ (- (os/clock) (anim :start)) (anim :duration))))
    (def e (ease-out-cubic t))
    (if (>= t 1.0)
      (do (put window :anim nil)
          (if (= (anim :type) :close)
            (put window :anim-destroy true)
            (when (anim :clip-from)
              (:set-clip-box (window :obj) 0 0 0 0)))
          false)
      (do
        (when (and (anim :from-x) (anim :to-x))
          (def x (math/round (+ (anim :from-x) (* e (- (anim :to-x) (anim :from-x))))))
          (def y (math/round (+ (anim :from-y) (* e (- (anim :to-y) (anim :from-y))))))
          (put window :x x)
          (put window :y y)
          (:set-position (window :node) x y))
        (when (anim :clip-from)
          (def [cx cy cw ch] (anim :clip-from))
          (def [tx ty tw th] (anim :clip-to))
          (:set-clip-box (window :obj)
            (math/round (+ cx (* e (- tx cx))))
            (math/round (+ cy (* e (- ty cy))))
            (math/round (+ cw (* e (- tw cw))))
            (math/round (+ ch (* e (- th ch))))))
        (put state/wm :anim-active true)
        true))))

# Scroll animation state (per output, stored in layout-params)
(defn scroll-toward [params key target]
  (if (not (state/config :animate))
    (put params key target)
    (let [current (params key)
          anim-key (keyword (string key "-anim"))]
      (if (= current target)
        (put params anim-key nil)
        (let [existing (params anim-key)
              now (os/clock)
              duration (state/config :animation-duration)]
          (if existing
            (do (put existing :to target)
                (when (>= (- now (existing :start)) duration)
                  (put params key target)
                  (put params anim-key nil)))
            (put params anim-key @{:from current :to target :start now :duration duration})))))))

(defn scroll-update [params key]
  (def anim-key (keyword (string key "-anim")))
  (when-let [anim (params anim-key)]
    (def t (min 1.0 (/ (- (os/clock) (anim :start)) (anim :duration))))
    (def e (ease-out-cubic t))
    (def val (+ (anim :from) (* e (- (anim :to) (anim :from)))))
    (put params key (math/round val))
    (if (>= t 1.0)
      (do (put params key (anim :to))
          (put params anim-key nil))
      (put state/wm :anim-active true))))
