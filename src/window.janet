(import ./state)
(import ./animation)
(import ./output)

(defn set-position [window x y]
  (put window :x x)
  (put window :y y)
  (:set-position (window :node) x y))

(defn propose-dimensions [window w h]
  (def bw (state/config :border-width))
  (:propose-dimensions (window :obj) (max 1 (- w (* 2 bw))) (max 1 (- h (* 2 bw)))))

(defn fixed-size? [window]
  (let [min-w (window :min-w) max-w (window :max-w)
        min-h (window :min-h) max-h (window :max-h)]
    (and min-w (> min-w 0) max-w (> max-w 0)
         min-h (> min-h 0) max-h (> max-h 0)
         (= min-w max-w) (= min-h max-h))))

(defn set-float [window float]
  (if float
    (:set-tiled (window :obj) {})
    (:set-tiled (window :obj) {:left true :bottom true :top true :right true}))
  (put window :float float)
  (put window :column nil)
  (put window :col-width nil)
  (put window :col-weight nil))

(defn set-fullscreen [window fullscreen-output]
  (if-let [o fullscreen-output]
    (do
      (put window :fullscreen true)
      (:inform-fullscreen (window :obj))
      (:fullscreen (window :obj) (o :obj)))
    (do
      (put window :fullscreen false)
      (:inform-not-fullscreen (window :obj))
      (:exit-fullscreen (window :obj)))))

(defn tag-output [window]
  (find |(($ :tags) (window :tag)) (state/wm :outputs)))

(defn max-overlap-output [window]
  (when (and window (window :x) (window :w) (window :y) (window :h))
    (var max-overlap 0)
    (var max-output nil)
    (each o (state/wm :outputs)
      (def ow (- (min (+ (window :x) (window :w)) (+ (o :x) (o :w)))
                 (max (window :x) (o :x))))
      (def oh (- (min (+ (window :y) (window :h)) (+ (o :y) (o :h)))
                 (max (window :y) (o :y))))
      (when (and (> ow 0) (> oh 0))
        (def overlap (* ow oh))
        (when (> overlap max-overlap)
          (set max-overlap overlap)
          (set max-output o))))
    max-output))

(defn update-tag [window]
  (when-let [o (max-overlap-output window)]
    (unless (= o (tag-output window))
      (put window :tag (or (min-of (keys (o :tags))) 1)))))

(defn match-rule [window]
  (each rule (state/config :rules)
    (when (and (or (nil? (rule :app-id))
                   (= (rule :app-id) (window :app-id)))
               (or (nil? (rule :title))
                   (= (rule :title) (window :title))))
      (when (rule :float)
        (set-float window true))
      (when (rule :tag)
        (put window :tag (rule :tag))))))

(defn manage-start [window]
  (cond
    (window :anim-destroy)
    (do
      (:destroy (window :obj))
      (:destroy (window :node)))

    (window :closed)
    (if (and (state/config :animate) (not (window :closing)) (window :w) (window :h))
      (do
        (put window :closing true)
        (def cw (window :w))
        (def ch (window :h))
        (def cx (math/round (/ cw 2)))
        (def cy (math/round (/ ch 2)))
        (animation/start window :close
          @{:from-x (window :x) :from-y (window :y)
            :to-x (+ (window :x) (math/round (/ (window :w) 2)))
            :to-y (+ (window :y) (math/round (/ (window :h) 2)))
            :clip-from @[0 0 cw ch]
            :clip-to @[cx cy 0 0]})
        window)
      (do
        (:destroy (window :obj))
        (:destroy (window :node))))

    window))

(defn manage [window]
  (when (window :new)
    (:use-ssd (window :obj))
    (if-let [parent (window :parent)]
      (do
        (set-float window true)
        (put window :tag (parent :tag))
        (:propose-dimensions (window :obj) 0 0))
      (do
        (set-float window false)
        (when (fixed-size? window)
          (set-float window true))
        (when-let [seat (first (state/wm :seats))
                   o (seat :focused-output)]
          (put window :tag (or (min-of (keys (o :tags))) 1)))
        (match-rule window))))

  (match (window :fullscreen-requested)
    [:enter] (if-let [seat (first (state/wm :seats))
                      o (seat :focused-output)]
               (set-fullscreen window o))
    [:enter o] (set-fullscreen window o)
    [:exit] (set-fullscreen window nil)))

(defn manage-finish [window]
  (put window :new nil)
  (put window :pointer-move-requested nil)
  (put window :pointer-resize-requested nil)
  (put window :fullscreen-requested nil))

(defn create [obj]
  (def window @{:obj obj
                :node (:get-node obj)
                :new true
                :tag 1})
  (defn handle-event [event]
    (match event
      [:closed] (put window :closed true)
      [:dimensions-hint min-w min-h max-w max-h]
        (do (put window :min-w min-w) (put window :min-h min-h)
            (put window :max-w max-w) (put window :max-h max-h))
      [:dimensions w h] (do (put window :w w) (put window :h h))
      [:app-id app-id] (put window :app-id app-id)
      [:title title] (put window :title title)
      [:parent parent] (put window :parent (if parent (:get-user-data parent)))
      [:decoration-hint hint] (put window :decoration-hint hint)
      [:pointer-move-requested seat]
        (put window :pointer-move-requested {:seat (:get-user-data seat)})
      [:pointer-resize-requested seat edges]
        (put window :pointer-resize-requested {:seat (:get-user-data seat) :edges edges})
      [:fullscreen-requested output]
        (put window :fullscreen-requested [:enter (if output (:get-user-data output))])
      [:exit-fullscreen-requested]
        (put window :fullscreen-requested [:exit])))
  (:set-handler obj handle-event)
  (:set-user-data obj window)
  window)

(defn set-borders [window status]
  (def cfg state/config)
  (def rgb (case status
             :normal (cfg :border-normal)
             :focused (cfg :border-focused)
             :urgent (cfg :border-urgent)))
  (:set-borders (window :obj)
                {:left true :bottom true :top true :right true}
                (cfg :border-width)
                ;(output/rgb-to-u32-rgba rgb)))

(defn render [window]
  (when (and (not (window :x)) (window :w))
    (if-let [o (max-overlap-output (window :parent))]
      (set-position window
                    (+ (o :x) (div (- (o :w) (window :w)) 2))
                    (+ (o :y) (div (- (o :h) (window :h)) 2)))
      (set-position window 0 0))))

(defn clip-to-output [window]
  (when-let [o (tag-output window)]
    (when (and (window :x) (window :w)
               (or (not (window :layout-hidden)) (window :anim)))
      (def bw (state/config :border-width))
      (def outer (state/config :outer-padding))
      (def cx (window :x))
      (def cy (window :y))
      (def cw (window :w))
      (def ch (window :h))
      (def inset (+ bw outer))
      (def ox (+ (o :x) inset))
      (def oy (+ (o :y) inset))
      (def ow (- (o :w) (* 2 inset)))
      (def oh (- (o :h) (* 2 inset)))
      (if (or (< cx ox) (< cy oy)
              (> (+ cx cw) (+ ox ow))
              (> (+ cy ch) (+ oy oh)))
        (do
          (def clip-x (max 0 (- ox cx)))
          (def clip-y (max 0 (- oy cy)))
          (def clip-w (max 1 (- (min (+ cx cw) (+ ox ow)) (max cx ox))))
          (def clip-h (max 1 (- (min (+ cy ch) (+ oy oh)) (max cy oy))))
          (:set-clip-box (window :obj)
            (math/round clip-x) (math/round clip-y)
            (math/round clip-w) (math/round clip-h)))
        (when (not (and (window :anim) ((window :anim) :clip-from)))
          (:set-clip-box (window :obj) 0 0 0 0))))))
