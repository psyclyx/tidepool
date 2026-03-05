(defn layout "Arrange windows in a main area (left) and stack area (right)." [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def main-count (min (params :main-count) n))
  (def side-count (- n main-count))
  (def results @[])

  (if (<= side-count 0)
    (let [cell-h (div total-h n)
          rem (% total-h n)]
      (for i 0 n
        (def y-off (+ (* cell-h i) (min i rem)))
        (def h (+ cell-h (if (< i rem) 1 0)))
        (array/push results
          {:window (get windows i)
           :x (+ (usable :x) outer inner)
           :y (+ (usable :y) outer y-off inner)
           :w (- total-w (* 2 inner))
           :h (- h (* 2 inner))})))
    (do
      (def main-w (math/round (* total-w (params :main-ratio))))
      (def side-w (- total-w main-w))
      (let [master-h (div total-h main-count)
            master-rem (% total-h main-count)]
        (for i 0 main-count
          (def y-off (+ (* master-h i) (min i master-rem)))
          (def h (+ master-h (if (< i master-rem) 1 0)))
          (array/push results
            {:window (get windows i)
             :x (+ (usable :x) outer inner)
             :y (+ (usable :y) outer y-off inner)
             :w (- main-w (* 2 inner))
             :h (- h (* 2 inner))})))
      (let [side-h (div total-h side-count)
            side-rem (% total-h side-count)]
        (for i 0 side-count
          (def y-off (+ (* side-h i) (min i side-rem)))
          (def h (+ side-h (if (< i side-rem) 1 0)))
          (array/push results
            {:window (get windows (+ main-count i))
             :x (+ (usable :x) outer main-w inner)
             :y (+ (usable :y) outer y-off inner)
             :w (- side-w (* 2 inner))
             :h (- h (* 2 inner))})))))
  results)

(defn navigate "Navigate between main and stack areas." [n main-count i dir ctx]
  (def in-main (< i main-count))
  (if in-main
    (case dir
      :right (when (> n main-count) main-count)
      :left nil
      :down (when (< (+ i 1) main-count) (+ i 1))
      :up (when (> i 0) (- i 1)))
    (let [si (- i main-count)
          sc (- n main-count)]
      (case dir
        :left 0
        :right nil
        :down (when (< (+ si 1) sc) (+ main-count si 1))
        :up (when (> si 0) (+ main-count si -1))))))
