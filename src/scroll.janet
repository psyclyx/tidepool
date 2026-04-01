# Scroll layout geometry. Pure functions — takes data, returns data.
# Computes virtual strip positions, camera panning, screen coordinates, and clip rects.

(import ./tree)

# --- Derived config ---

(defn base-width
  "The pixel width of a 100% node. Leaves room for peek + border + gap on each side."
  [output-w peek-width border-width inner-gap outer-gap]
  (def overhead (* 2 (+ outer-gap peek-width border-width inner-gap)))
  (max 1 (- output-w overhead)))

(defn peek-total
  "How many pixels of an adjacent node are visible when peeking."
  [peek-width border-width]
  (+ peek-width border-width))

# --- Virtual strip layout ---

(defn node-pixel-width
  "Convert a node's percentage width to pixels."
  [pct base-w]
  (math/round (* pct base-w)))

(defn virtual-positions
  "Compute virtual x positions for an array of top-level columns.
   Returns array of {:vx :vw} for each column."
  [columns base-w outer-gap inner-gap]
  (def result @[])
  (var x outer-gap)
  (each col columns
    (def w (node-pixel-width (col :width) base-w))
    (array/push result {:vx x :vw w})
    (set x (+ x w inner-gap)))
  result)

(defn virtual-total
  "Total width of the virtual strip."
  [positions outer-gap]
  (if (empty? positions)
    (* 2 outer-gap)
    (let [last-pos (last positions)]
      (+ (last-pos :vx) (last-pos :vw) outer-gap))))

# --- Camera ---

(defn camera-update
  "Compute new camera position using minimum-scroll algorithm.
   focus-idx is the index of the focused top-level column.
   Returns new camera x."
  [cam-x output-w positions focus-idx peek-tot outer-gap inner-gap]
  (when (or (empty? positions) (nil? focus-idx))
    (break 0))
  (def n (length positions))
  (def fi (min focus-idx (dec n)))
  (def fp (positions fi))
  (def focus-left (fp :vx))
  (def focus-right (+ (fp :vx) (fp :vw)))

  # Required visible range
  (def req-left
    (if (> fi 0)
      (- focus-left inner-gap peek-tot)
      focus-left))
  (def req-right
    (if (< fi (dec n))
      (+ focus-right inner-gap peek-tot)
      focus-right))

  (def needed-left (- req-left outer-gap))
  (def needed-right (+ req-right outer-gap))
  (def needed-span (- needed-right needed-left))

  (def vtotal (virtual-total positions outer-gap))
  (def max-cam (max 0 (- vtotal output-w)))

  (var new-cam cam-x)

  (if (> needed-span output-w)
    # Focused column too wide — center it
    (set new-cam (- (+ focus-left (/ (fp :vw) 2)) (/ output-w 2)))
    (do
      # Scroll right if needed region extends past viewport right edge
      (when (< (+ new-cam output-w) needed-right)
        (set new-cam (- needed-right output-w)))
      # Scroll left if needed region starts before viewport left edge
      (when (> new-cam needed-left)
        (set new-cam needed-left))))

  (max 0 (min new-cam max-cam)))

# --- Screen coordinates ---

(defn screen-x
  "Convert virtual x to screen x given camera and output origin."
  [vx cam-x output-x]
  (+ output-x (- vx cam-x)))

# --- Clipping ---

(defn clip-rect
  "Compute clip rectangle for a window in window-local coordinates.
   Returns {:clip-x :clip-y :clip-w :clip-h} or nil if no clipping needed."
  [win-screen-x win-w win-screen-y win-h output-x output-y output-w output-h]
  (def clip-left (max 0 (- output-x win-screen-x)))
  (def clip-top (max 0 (- output-y win-screen-y)))
  (def clip-right (min win-w (- (+ output-x output-w) win-screen-x)))
  (def clip-bottom (min win-h (- (+ output-y output-h) win-screen-y)))
  (if (and (= clip-left 0) (= clip-top 0)
           (= clip-right win-w) (= clip-bottom win-h))
    nil
    {:clip-x clip-left :clip-y clip-top
     :clip-w (max 0 (- clip-right clip-left))
     :clip-h (max 0 (- clip-bottom clip-top))}))

(defn visible?
  "Is any part of a window visible on the output?"
  [win-screen-x win-w output-x output-w]
  (and (< win-screen-x (+ output-x output-w))
       (> (+ win-screen-x win-w) output-x)))

# --- Recursive node layout ---

(defn layout-node
  "Compute pixel placements for a node within an allocated rectangle.
   Returns array of {:window :x :y :w :h} for each visible leaf.
   inner-gap is applied between children of split containers."
  [node rect inner-gap border-width]
  (case (node :type)
    :leaf
    @[{:window (node :window)
       :x (rect :x) :y (rect :y)
       :w (rect :w) :h (rect :h)}]

    :container
    (case (node :mode)
      :tabbed
      (layout-node ((node :children) (node :active)) rect inner-gap border-width)

      :split
      (let [children (node :children)
            n (length children)]
        (case (node :orientation)
          :vertical
          (let [total-gap (* inner-gap (dec n))
                usable-h (- (rect :h) total-gap)
                cell-h (math/floor (/ usable-h n))
                remainder (- usable-h (* cell-h n))
                results @[]]
            (var y (rect :y))
            (for i 0 n
              (def h (+ cell-h (if (< i remainder) 1 0)))
              (array/concat results
                (layout-node (children i)
                  {:x (rect :x) :y y :w (rect :w) :h h}
                  inner-gap border-width))
              (set y (+ y h inner-gap)))
            results)

          :horizontal
          (let [total-gap (* inner-gap (dec n))
                usable-w (- (rect :w) total-gap)
                cell-w (math/floor (/ usable-w n))
                remainder (- usable-w (* cell-w n))
                results @[]]
            (var x (rect :x))
            (for i 0 n
              (def w (+ cell-w (if (< i remainder) 1 0)))
              (array/concat results
                (layout-node (children i)
                  {:x x :y (rect :y) :w w :h (rect :h)}
                  inner-gap border-width))
              (set x (+ x w inner-gap)))
            results))))))

# --- Full scroll layout ---

(defn scroll-layout
  "Compute the complete layout for one output/tag.
   Returns {:placements [...] :camera cam-x}
   Each placement: {:window :x :y :w :h :clip (or nil)}

   Parameters:
     columns    - array of top-level nodes
     focus-leaf - the focused leaf node (or nil)
     cam-x      - current camera position
     output     - {:x :y :w :h} output geometry
     usable     - {:x :y :w :h} usable area (minus exclusive zones)
     config     - {:peek-width :border-width :inner-gap :outer-gap}"
  [columns focus-leaf cam-x output usable config]
  (def pw (config :peek-width))
  (def bw (config :border-width))
  (def ig (config :inner-gap))
  (def og (config :outer-gap))
  (def base-w (base-width (usable :w) pw bw ig og))
  (def pt (peek-total pw bw))

  # Virtual positions for each column
  (def vpositions (virtual-positions columns base-w og ig))

  # Find focused column index
  (def focus-col-idx
    (when focus-leaf
      (tree/find-column-index columns focus-leaf)))

  # Update camera
  (def new-cam (camera-update cam-x (usable :w) vpositions focus-col-idx pt og ig))

  # Compute placements
  (def placements @[])
  (for i 0 (length columns)
    (def col (columns i))
    (def vp (vpositions i))
    (def col-screen-x (screen-x (vp :vx) new-cam (usable :x)))
    (def col-h (- (usable :h) (* 2 og)))
    (def col-screen-y (+ (usable :y) og))

    # Skip columns entirely off-screen
    (when (visible? col-screen-x (vp :vw) (output :x) (output :w))
      (def rect {:x col-screen-x :y col-screen-y
                 :w (vp :vw) :h col-h})
      (def node-placements (layout-node col rect ig bw))
      (each p node-placements
        (def clip (clip-rect (p :x) (p :w) (p :y) (p :h)
                             (output :x) (output :y) (output :w) (output :h)))
        (array/push placements
          (merge p {:clip clip})))))

  {:placements placements :camera new-cam})
