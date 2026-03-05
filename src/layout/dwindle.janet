(defn layout
  "Arrange windows in recursive alternating splits."
  [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def default-ratio (params :dwindle-ratio))
  (def ratios (params :dwindle-ratios))
  (var x (+ (usable :x) outer))
  (var y (+ (usable :y) outer))
  (var w total-w)
  (var h total-h)
  (def results @[])
  (for i 0 n
    (if (= i (- n 1))
      (array/push results
        {:window (get windows i)
         :x (+ x inner) :y (+ y inner)
         :w (- w (* 2 inner)) :h (- h (* 2 inner))})
      (let [ratio (or (get ratios i) default-ratio)]
        (if (= 0 (% i 2))
          (let [split-w (math/round (* w ratio))]
            (array/push results
              {:window (get windows i)
               :x (+ x inner) :y (+ y inner)
               :w (- split-w (* 2 inner)) :h (- h (* 2 inner))})
            (set x (+ x split-w))
            (set w (- w split-w)))
          (let [split-h (math/round (* h ratio))]
            (array/push results
              {:window (get windows i)
               :x (+ x inner) :y (+ y inner)
               :w (- w (* 2 inner)) :h (- split-h (* 2 inner))})
            (set y (+ y split-h))
            (set h (- h split-h)))))))
  results)

(defn navigate
  "Navigate spatially through the dwindle tree.
  Each split level alternates: even=vertical, odd=horizontal.
  Window i is the first child (left/top) of split i."
  [n main-count i dir ctx]
  (case dir
    :right (when (and (= 0 (% i 2)) (< (+ i 1) n)) (+ i 1))
    :down (when (and (= 1 (% i 2)) (< (+ i 1) n)) (+ i 1))
    :left (let [j (- i (if (= 0 (% i 2)) 2 1))]
            (when (>= j 0) j))
    :up (let [j (- i (if (= 1 (% i 2)) 2 1))]
          (when (>= j 0) j))))
