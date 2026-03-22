(import ./animation)
(import ./persist)

(var next-wid 0)

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

(defn constrained-size?
  "True if the window has max size hints set (likely a dialog)."
  [window]
  (let [max-w (window :max-w) max-h (window :max-h)]
    (and max-w (> max-w 0) max-h (> max-h 0))))

(defn clear-layout-placement
  "Clear layout placement state (column, width, weight, row)."
  [window]
  (put window :column nil)
  (put window :col-width nil)
  (put window :col-weight nil)
  (put window :row nil))

(defn set-float
  "Set floating state and clear layout placement."
  [window float]
  (put window :float float)
  (put window :float-changed true)
  (clear-layout-placement window))

(defn set-fullscreen
  "Enter or exit fullscreen (pure data mutation)."
  [window fullscreen-output]
  (if fullscreen-output
    (do
      (when (window :float)
        (put window :pre-fullscreen-pos [(window :x) (window :y)]))
      (put window :fullscreen true)
      (put window :fullscreen-output fullscreen-output))
    (do
      (put window :fullscreen false)
      (put window :fullscreen-output nil)
      (when-let [pos (window :pre-fullscreen-pos)]
        (set-position window (pos 0) (pos 1))
        (put window :pre-fullscreen-pos nil))))
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

(defn update-tag
  "Reassign the window's tag to match its most-overlapping output."
  [window outputs]
  (when-let [o (max-overlap-output window outputs)]
    (unless (= o (tag-output window outputs))
      (put window :tag (or (min-of (keys (o :tags))) 1)))))

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
        # Propose parent's dimensions so floating dialogs aren't minimally sized
        (when (and (parent :w) (parent :h))
          (put window :proposed-w (parent :w))
          (put window :proposed-h (parent :h))))
      (do
        (set-float window false)
        (when (fixed-size? window)
          (set-float window true))
        (when-let [seat (first seats)
                   o (seat :focused-output)]
          (put window :tag (or (min-of (keys (o :tags))) 1)))
        (match-rule window (config :rules))
        (persist/restore-window window))))

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
                :tag 1
                :wid (++ next-wid)})
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

(defn clear-layout-state
  "Clear per-frame transient layout state on windows."
  [windows]
  (each w windows
    (put w :layout-hidden nil)
    (put w :scroll-placed nil)
    (put w :layout-meta nil)))

(defn compute-visibility
  "Set :visible on each window based on active tags and layout-hidden state."
  [outputs windows]
  (def all-tags @{})
  (each o outputs
    (merge-into all-tags (o :tags)))
  (each w windows
    (put w :visible
      (if (or (w :closing)
              (and (all-tags (w :tag))
                   (or (not (w :layout-hidden)) (w :anim))))
        true false))))

(defn clip-to-output
  "Compute clip rect and store on window table."
  [window tag-map config]
  (when-let [o (get tag-map (window :tag))]
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
      # For scroll-placed windows, the position is the visual footprint's
      # top-left (including borders), but w/h are content-only. Expand to
      # the full visual footprint so the clip covers borders correctly.
      (def bw2 (if (window :scroll-placed) (* 2 bw) 0))
      (def vw (+ cw bw2))
      (def vh (+ ch bw2))
      (if (or (< cx ox) (< cy oy)
              (> (+ cx vw) (+ ox ow))
              (> (+ cy vh) (+ oy oh)))
        (do
          (def clip-x (max 0 (- ox cx)))
          (def clip-y (max 0 (- oy cy)))
          (def clip-w (max 1 (- (min (+ cx vw) (+ ox ow)) (max cx ox))))
          (def clip-h (max 1 (- (min (+ cy vh) (+ oy oh)) (max cy oy))))
          (put window :clip-rect
            [(math/round clip-x) (math/round clip-y)
             (math/round clip-w) (math/round clip-h)]))
        (when (not (and (window :anim) ((window :anim) :clip-from)))
          (put window :clip-rect :clear))))))
