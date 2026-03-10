(import ./animation)

(defn set-position
  "Set the window's position (pure data mutation)."
  [window x y]
  (put window :x x)
  (put window :y y))

(defn propose-dimensions
  "Compute and store proposed dimensions, accounting for borders."
  [window w h config]
  (def bw (config :border-width))
  (put window :proposed-w (max 1 (- w (* 2 bw))))
  (put window :proposed-h (max 1 (- h (* 2 bw)))))

(defn fixed-size?
  "True if the window has equal min and max size hints."
  [window]
  (let [min-w (window :min-w) max-w (window :max-w)
        min-h (window :min-h) max-h (window :max-h)]
    (and min-w (> min-w 0) max-w (> max-w 0)
         min-h (> min-h 0) max-h (> max-h 0)
         (= min-w max-w) (= min-h max-h))))

(defn set-float
  "Set floating state."
  [window float]
  (put window :float float)
  (put window :float-changed true))

(defn set-fullscreen
  "Enter or exit fullscreen (pure data mutation)."
  [window fullscreen-output]
  (if fullscreen-output
    (do
      (put window :fullscreen true)
      (put window :fullscreen-output fullscreen-output))
    (do
      (put window :fullscreen false)
      (put window :fullscreen-output nil)))
  (put window :fullscreen-changed true))

(defn tag-output
  "Find the output displaying this window's tag."
  [window outputs]
  (find |(($ :tags) (window :tag)) outputs))

(defn max-overlap-output
  "Find the output with the largest area overlap."
  [window outputs]
  (when (and window (window :x) (window :w) (window :y) (window :h))
    (var max-overlap 0)
    (var max-output nil)
    (each o outputs
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

(defn match-rule
  "Apply config rules matching the window's app-id/title."
  [window rules]
  (each rule rules
    (when (and (or (nil? (rule :app-id))
                   (= (rule :app-id) (window :app-id)))
               (or (nil? (rule :title))
                   (= (rule :title) (window :title))))
      (when (rule :float)
        (set-float window true))
      (when (rule :tag)
        (put window :tag (rule :tag))))))

(defn manage-start
  "Handle window close: set flags for destruction or start close animation."
  [window now config]
  (cond
    (window :anim-destroy)
    (do (put window :pending-destroy true) nil)

    (window :closed)
    (if (and (config :animate) (not (window :closing)) (window :w) (window :h))
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
            :clip-to @[cx cy 0 0]}
          now config)
        window)
      (do (put window :pending-destroy true) nil))

    window))

(defn manage
  "Process new window setup and fullscreen requests (pure)."
  [window config seats]
  (when (window :new)
    (put window :needs-ssd true)
    (if-let [parent (window :wl-parent)]
      (do
        (set-float window true)
        (put window :tag (parent :tag))
        (put window :proposed-w 0)
        (put window :proposed-h 0))
      (do
        (set-float window false)
        (when (fixed-size? window)
          (set-float window true))
        # Set preliminary tag from focused output's active pool tag
        (when-let [seat (first seats)
                   o (seat :focused-output)]
          (when-let [root (o :pool)]
            (def active (or (root :active) 0))
            (when-let [tag (get (root :children) active)]
              (put window :tag (tag :id)))))
        (match-rule window (config :rules)))))

  (match (window :fullscreen-requested)
    [:enter] (if-let [seat (first seats)
                      o (seat :focused-output)]
               (set-fullscreen window o))
    [:enter o] (set-fullscreen window o)
    [:exit] (set-fullscreen window nil)))

(defn manage-finish
  "Clear per-frame transient state."
  [window]
  (put window :new nil)
  (put window :pointer-move-requested nil)
  (put window :pointer-resize-requested nil)
  (put window :fullscreen-requested nil)
  (put window :float-changed nil)
  (put window :fullscreen-changed nil)
  (put window :needs-ssd nil)
  (put window :proposed-w nil)
  (put window :proposed-h nil)
  (put window :anim-clip nil)
  (put window :clip-rect nil))

(defn create
  "Create a window from a Wayland toplevel object."
  [obj]
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
      [:parent parent] (put window :wl-parent (if parent (:get-user-data parent)))
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

(defn set-borders
  "Compute and store border spec for the given status."
  [window status config]
  (def rgb (case status
             :normal (config :border-normal)
             :focused (config :border-focused)
             :tabbed (config :border-tabbed)
             :sibling (or (config :border-sibling) (config :border-normal))
             :urgent (config :border-urgent)))
  (put window :border-status status)
  (put window :border-rgb rgb)
  (put window :border-width (config :border-width)))

(defn render
  "Center unplaced windows (e.g. dialogs) on their parent output."
  [window outputs]
  (when (and (not (window :x)) (window :w))
    (if-let [o (max-overlap-output (window :wl-parent) outputs)]
      (set-position window
                    (+ (o :x) (div (- (o :w) (window :w)) 2))
                    (+ (o :y) (div (- (o :h) (window :h)) 2)))
      (set-position window 0 0))))

(defn clip-to-output
  "Compute clip rect and store on window table."
  [window outputs config]
  (when-let [o (tag-output window outputs)]
    (when (and (window :x) (window :w)
               (or (not (window :layout-hidden)) (window :anim)))
      (def bw (config :border-width))
      (def outer (config :outer-padding))
      (def cx (window :x))
      (def cy (window :y))
      (def cw (window :w))
      (def ch (window :h))
      (def inset (if (window :scroll-placed) 0 (+ bw outer)))
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
          (put window :clip-rect
            [(math/round clip-x) (math/round clip-y)
             (math/round clip-w) (math/round clip-h)]))
        (when (not (and (window :anim) ((window :anim) :clip-from)))
          (put window :clip-rect :clear))))))
