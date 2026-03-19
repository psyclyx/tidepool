(defn- tab-remaining
  "Place remaining windows as tabs in the given cell."
  [results windows from-idx n x y w h inner focused]
  (def tab-n (- n from-idx))
  (def content-w (- w (* 2 inner)))
  (def content-h (- h (* 2 inner)))
  (def viable (and (> content-w 0) (> content-h 0)))
  (def tab-focused
    (when (and focused viable)
      (var found nil)
      (for ti from-idx n
        (when (= (get windows ti) focused) (set found (get windows ti))))
      found))
  (for ti 0 tab-n
    (def tw (get windows (+ from-idx ti)))
    (put tw :layout-meta @{:depth (+ from-idx ti) :depth-total n
                            :split (if (= 0 (% (+ from-idx ti) 2)) :horizontal :vertical)
                            :tab-index ti :tab-total tab-n})
    (if viable
      (do
        (def is-visible (if tab-focused (= tw tab-focused) (= ti 0)))
        (array/push results
          {:window tw
           :x (+ x inner) :y (+ y inner)
           :w content-w :h content-h
           :hidden (not is-visible)}))
      (array/push results {:window tw :hidden true}))))

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
  (def min-cell (* 2 inner))
  (for i 0 n
    (def win (get windows i))
    (put win :layout-meta @{:depth i :depth-total n :split (if (= 0 (% i 2)) :horizontal :vertical)})
    (cond
      # Cell too small — tab all remaining windows in previous cell
      (or (<= w min-cell) (<= h min-cell))
      (do (tab-remaining results windows i n x y w h inner focused)
          (break))

      # Last window — give all remaining space
      (= i (- n 1))
      (array/push results
        {:window win
         :x (+ x inner) :y (+ y inner)
         :w (- w (* 2 inner)) :h (- h (* 2 inner))})

      # Split would leave remainder too small — tab remaining in current cell
      (let [ratio (or (get ratios i) default-ratio)
            split-dim (if (= 0 (% i 2))
                        (math/round (* w ratio))
                        (math/round (* h ratio)))
            remaining (if (= 0 (% i 2)) (- w split-dim) (- h split-dim))]
        (< remaining min-cell))
      (do (tab-remaining results windows i n x y w h inner focused)
          (break))

      # Normal split
      (let [ratio (or (get ratios i) default-ratio)]
        (if (= 0 (% i 2))
          (let [split-w (math/round (* w ratio))]
            (array/push results
              {:window win
               :x (+ x inner) :y (+ y inner)
               :w (- split-w (* 2 inner)) :h (- h (* 2 inner))})
            (set x (+ x split-w))
            (set w (- w split-w)))
          (let [split-h (math/round (* h ratio))]
            (array/push results
              {:window win
               :x (+ x inner) :y (+ y inner)
               :w (- w (* 2 inner)) :h (- split-h (* 2 inner))})
            (set y (+ y split-h))
            (set h (- h split-h)))))))
  results)
