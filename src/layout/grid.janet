(defn layout
  "Arrange windows in a grid of rows and columns."
  [usable windows params config focused &opt now focus-prev]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def cols (math/ceil (math/sqrt n)))
  (def rows (math/ceil (/ n cols)))
  (def cell-w (div total-w cols))
  (def cell-h (div total-h rows))
  (def results @[])
  (for i 0 n
    (def row (div i cols))
    (def col (% i cols))
    (def row-count (if (= row (- rows 1)) (- n (* row cols)) cols))
    (def this-cell-w (if (= row (- rows 1)) (div total-w row-count) cell-w))
    (def this-col (if (= row (- rows 1)) (- i (* row cols)) col))
    (def win (get windows i))
    (put win :layout-meta @{:row row :row-total rows :column col :column-total cols})
    (array/push results
      {:window win
       :x (+ (usable :x) outer (* this-col this-cell-w) inner)
       :y (+ (usable :y) outer (* row cell-h) inner)
       :w (- this-cell-w (* 2 inner))
       :h (- cell-h (* 2 inner))}))
  results)

(defn navigate
  "Navigate the grid directionally."
  [n main-count i dir ctx]
  (def cols (math/ceil (math/sqrt n)))
  (def row (div i cols))
  (def col (% i cols))
  (def rows (math/ceil (/ n cols)))
  (def last-row-cols (- n (* (- rows 1) cols)))
  (case dir
    :left (when (> col 0) (- i 1))
    :right (let [row-len (if (= row (- rows 1)) last-row-cols cols)]
             (when (< (+ col 1) row-len) (+ i 1)))
    :up (when (> row 0) (- i cols))
    :down (let [target (+ i cols)]
            (when (< target n) target))))
