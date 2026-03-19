(defn layout
  "Arrange all windows fullscreen, only the focused one visible."
  [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def results @[])
  (for i 0 n
    (def window (get windows i))
    (put window :layout-meta @{:tab-index i :tab-total n})
    (array/push results
      {:window window
       :x (+ (usable :x) outer inner)
       :y (+ (usable :y) outer inner)
       :w (- total-w (* 2 inner))
       :h (- total-h (* 2 inner))
       :hidden (not= window focused)}))
  results)

(defn navigate
  "Cycle through tabs linearly."
  [n main-count i dir ctx]
  (case dir
    :right (when (< (+ i 1) n) (+ i 1))
    :down (when (< (+ i 1) n) (+ i 1))
    :left (when (> i 0) (- i 1))
    :up (when (> i 0) (- i 1))))
