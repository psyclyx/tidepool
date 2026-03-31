# Pure layout algorithms. No side effects — takes data, returns data.

(defn master-stack
  "Arrange windows in master (left) + stack (right)."
  [usable windows params config]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def main-count (min (params :main-count) n))
  (def side-count (- n main-count))
  (def results @[])

  (defn- column [col-x col-w count start-idx]
    (def cell-h (div total-h count))
    (def rem (% total-h count))
    (for i 0 count
      (def y-off (+ (* cell-h i) (min i rem)))
      (def h (+ cell-h (if (< i rem) 1 0)))
      (array/push results
        {:window (windows (+ start-idx i))
         :x (+ (usable :x) col-x inner)
         :y (+ (usable :y) outer y-off inner)
         :w (- col-w (* 2 inner))
         :h (- h (* 2 inner))})))

  (if (<= side-count 0)
    (column outer total-w n 0)
    (let [main-w (math/round (* total-w (params :main-ratio)))
          side-w (- total-w main-w)]
      (column outer main-w main-count 0)
      (column (+ outer main-w) side-w side-count main-count)))
  results)
