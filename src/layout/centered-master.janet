(import ./master-stack)

(defn layout
  "Arrange a center master with left and right stacks."
  [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (cond
    (= n 1)
    [{:window (first windows)
      :x (+ (usable :x) outer inner)
      :y (+ (usable :y) outer inner)
      :w (- total-w (* 2 inner))
      :h (- total-h (* 2 inner))}]

    (= n 2)
    (master-stack/layout usable windows params config focused)

    (let [side-count (- n 1)
          left-count (math/ceil (/ side-count 2))
          right-count (- side-count left-count)
          center-w (math/round (* total-w (params :main-ratio)))
          side-total (- total-w center-w)
          left-w (div side-total 2)
          right-w (- side-total left-w)
          results @[]]

      (array/push results
        {:window (first windows)
         :x (+ (usable :x) outer left-w inner)
         :y (+ (usable :y) outer inner)
         :w (- center-w (* 2 inner))
         :h (- total-h (* 2 inner))})

      (let [lh (div total-h left-count)
            lrem (% total-h left-count)]
        (for i 0 left-count
          (def y-off (+ (* lh i) (min i lrem)))
          (def h (+ lh (if (< i lrem) 1 0)))
          (array/push results
            {:window (get windows (+ 1 i))
             :x (+ (usable :x) outer inner)
             :y (+ (usable :y) outer y-off inner)
             :w (- left-w (* 2 inner))
             :h (- h (* 2 inner))})))

      (when (> right-count 0)
        (let [rh (div total-h right-count)
              rrem (% total-h right-count)]
          (for i 0 right-count
            (def y-off (+ (* rh i) (min i rrem)))
            (def h (+ rh (if (< i rrem) 1 0)))
            (array/push results
              {:window (get windows (+ 1 left-count i))
               :x (+ (usable :x) outer left-w center-w inner)
               :y (+ (usable :y) outer y-off inner)
               :w (- right-w (* 2 inner))
               :h (- h (* 2 inner))}))))
      results)))

(defn navigate
  "Navigate between center, left stack, and right stack."
  [n main-count i dir ctx]
  (cond
    (<= n 2) (master-stack/navigate n 1 i dir ctx)
    (do
      (def side-count (- n 1))
      (def left-count (math/ceil (/ side-count 2)))
      (def right-count (- side-count left-count))
      (cond
        (= i 0)
        (case dir
          :left (when (> left-count 0) 1)
          :right (when (> right-count 0) (+ 1 left-count))
          :up nil :down nil)

        (<= i left-count)
        (let [li (- i 1)]
          (case dir
            :right 0
            :left nil
            :down (when (< (+ li 1) left-count) (+ i 1))
            :up (when (> li 0) (- i 1))))

        (let [ri (- i 1 left-count)]
          (case dir
            :left 0
            :right nil
            :down (when (< (+ ri 1) right-count) (+ i 1))
            :up (when (> ri 0) (- i 1))))))))
