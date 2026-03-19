(import ../output)
(import ../window)
(import ./master-stack)
(import ./grid)
(import ./dwindle)
(import ./scroll)
(import ./tabbed)

(def layout-fns
  "Layout function dispatch table."
  @{:master-stack master-stack/layout
    :grid grid/layout
    :dwindle dwindle/layout
    :scroll scroll/layout
    :tabbed tabbed/layout})

(def navigate-fns
  "Navigation function dispatch table.
  Layouts without an entry here fall back to navigate-by-geometry."
  @{:master-stack master-stack/navigate
    :grid grid/navigate
    :scroll scroll/navigate
    :tabbed tabbed/navigate})

(def context-fns
  "Layout context function dispatch table.
  Signature: (ctx-fn output windows focused &opt focus-prev)
  Filters to visible tiled windows before calling the layout's context fn."
  @{:scroll (fn [o windows focused &opt focus-prev]
              (def visible (filter |(not (or ($ :float) ($ :fullscreen)))
                                   (output/visible o windows)))
              (when-let [ctx (scroll/context visible focused focus-prev
                               (or (get-in o [:layout-params :active-row]) 0))]
                (put ctx :all-tiled visible)
                (put ctx :params (o :layout-params))
                ctx))})

(defn navigate-by-geometry
  "Navigate by finding the nearest window in the given direction.
  Direction is determined by edges, not centers: a candidate is only
  'to the right' if its left edge is past the current window's right edge.
  Among valid candidates, the nearest by center distance wins."
  [results focused-idx dir]
  (def current (get results focused-idx))
  (def cx (+ (current :x) (/ (current :w) 2)))
  (def cy (+ (current :y) (/ (current :h) 2)))
  (var best nil)
  (var best-dist math/inf)
  (for i 0 (length results)
    (def other (get results i))
    (when (and (not= i focused-idx) (not (other :hidden)))
      (def valid
        (case dir
          :right (>= (other :x) (+ (current :x) (current :w)))
          :left (<= (+ (other :x) (other :w)) (current :x))
          :down (>= (other :y) (+ (current :y) (current :h)))
          :up (<= (+ (other :y) (other :h)) (current :y))))
      (when valid
        (def dx (- (+ (other :x) (/ (other :w) 2)) cx))
        (def dy (- (+ (other :y) (/ (other :h) 2)) cy))
        (def dist (+ (* dx dx) (* dy dy)))
        (when (< dist best-dist)
          (set best i)
          (set best-dist dist)))))
  best)

(defn apply-geometry
  "Store computed geometry on window tables."
  [results config]
  (each r results
    (when (r :scroll-placed) (put (r :window) :scroll-placed true))
    (if (r :hidden)
      (put (r :window) :layout-hidden true)
      (do
        (window/set-position (r :window) (r :x) (r :y))
        (window/propose-dimensions (r :window) (r :w) (r :h) config)))))

(defn- handle-tab-overflow
  "Collapse results that can't fit their windows into a tabbed group."
  [results focused config]
  (def bw (config :border-width))
  (var overflow-idx nil)
  (for i 0 (length results)
    (def r (get results i))
    (when (not (r :hidden))
      (def win (r :window))
      (def min-w (+ (or (win :min-w) 1) (* 2 bw)))
      (def min-h (+ (or (win :min-h) 1) (* 2 bw)))
      (when (or (< (r :w) min-w) (< (r :h) min-h))
        (set overflow-idx i)
        (break))))
  (when overflow-idx
    (def tab-start (max 0 (- overflow-idx 1)))
    (def anchor (get results tab-start))
    (def tab-n (- (length results) tab-start))
    (var tab-focused-idx nil)
    (for i tab-start (length results)
      (when (= ((get results i) :window) focused)
        (set tab-focused-idx (- i tab-start))
        (break)))
    (for i tab-start (length results)
      (def r (get results i))
      (def win (r :window))
      (def ti (- i tab-start))
      (put win :layout-meta
        (merge (or (win :layout-meta) @{})
               @{:tab-index ti :tab-total tab-n}))
      (def is-visible (if tab-focused-idx (= ti tab-focused-idx) (= ti 0)))
      (put results i
        @{:window win
          :x (anchor :x) :y (anchor :y)
          :w (anchor :w) :h (anchor :h)
          :hidden (not is-visible)}))))

(defn apply
  "Apply the current layout to an output's tiled windows."
  [o windows seats config now]
  (def visible (filter |(not (or ($ :float) ($ :fullscreen)))
                       (output/visible o windows)))
  (when (empty? visible) (break))
  (def layout-fn (get layout-fns (o :layout) master-stack/layout))
  (def usable (output/usable-area o))
  (def params (o :layout-params))
  (def focused
    (when-let [seat (first seats)]
      (when-let [w (seat :focused)]
        (when (find |(= $ w) visible) w))))
  (def focus-prev
    (when-let [seat (first seats)]
      (seat :focus-prev)))
  (def results (layout-fn usable visible params config focused now focus-prev))
  (unless (= (o :layout) :scroll)
    (handle-tab-overflow results focused config))
  (apply-geometry results config))
