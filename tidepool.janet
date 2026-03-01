(import protocols)
(import wayland)
(import spork/netrepl)
(import xkbcommon)

# --- Protocol Setup ---

(def interfaces
  (wayland/scan
    :wayland-xml protocols/wayland-xml
    :system-protocols-dir protocols/wayland-protocols
    :system-protocols ["stable/viewporter/viewporter.xml"
                       "staging/single-pixel-buffer/single-pixel-buffer-v1.xml"]
    :custom-protocols (map |(string protocols/river-protocols $)
                           ["/river-window-management-v1.xml"
                            "/river-layer-shell-v1.xml"
                            "/river-xkb-bindings-v1.xml"])))

(def required-interfaces
  @{"wl_compositor" 4
    "wp_viewporter" 1
    "wp_single_pixel_buffer_manager_v1" 1
    "river_window_manager_v1" 3
    "river_layer_shell_v1" 1
    "river_xkb_bindings_v1" 1})

# --- Configuration ---

(def config
  @{:border-width 4
    :outer-padding 4
    :inner-padding 8
    :main-ratio 0.55
    :default-layout :master-stack
    :layouts [:master-stack :monocle :grid :centered-master :dwindle :columns]
    :dwindle-ratio 0.5
    :column-width 0.5
    :main-count 1
    :indicator-notify true
    :indicator-file true
    :background 0x000000
    :border-focused 0xffffff
    :border-normal 0x646464
    :border-urgent 0xff0000
    :xkb-bindings @[]
    :pointer-bindings @[]
    :rules @[]
    :warp-pointer false
    :xcursor-theme "Adwaita"
    :xcursor-size 24})

# Per-tag layout storage: tag -> {:layout :kw :params @{...}}
(def tag-layouts @{})

# --- State ---

(def wm
  @{:config config
    :outputs @[]
    :seats @[]
    :windows @[]
    :render-order @[]})

(def registry @{})

# --- Color Utilities ---

(defn rgb-to-u32-rgba [rgb]
  [(* (band 0xff (brushift rgb 16)) (/ 0xffff_ffff 0xff))
   (* (band 0xff (brushift rgb 8)) (/ 0xffff_ffff 0xff))
   (* (band 0xff rgb) (/ 0xffff_ffff 0xff))
   0xffff_ffff])

# --- Background Surface ---

(defn bg/create []
  (def surface (:create-surface (registry "wl_compositor")))
  (def viewport (:get-viewport (registry "wp_viewporter") surface))
  (def shell-surface (:get-shell-surface (registry "river_window_manager_v1") surface))
  @{:surface surface
    :viewport viewport
    :shell-surface shell-surface
    :node (:get-node shell-surface)})

(defn bg/manage [bg output]
  (:sync-next-commit (bg :shell-surface))
  (:place-bottom (bg :node))
  (:set-position (bg :node) (output :x) (output :y))
  (def buffer (:create-u32-rgba-buffer
                (registry "wp_single_pixel_buffer_manager_v1")
                ;(rgb-to-u32-rgba ((wm :config) :background))))
  (:attach (bg :surface) buffer 0 0)
  (:damage-buffer (bg :surface) 0 0 0x7fff_ffff 0x7fff_ffff)
  (:set-destination (bg :viewport) (output :w) (output :h))
  (:commit (bg :surface))
  (:destroy buffer))

(defn bg/destroy [bg]
  (:destroy (bg :viewport))
  (:destroy (bg :shell-surface))
  (:destroy (bg :surface))
  (:destroy (bg :node)))

# --- Output Management ---

(defn output/visible [output windows]
  (let [tags (output :tags)]
    (filter |(tags ($ :tag)) windows)))

(defn output/usable-area [output]
  (if-let [[x y w h] (output :non-exclusive-area)]
    {:x x :y y :w w :h h}
    {:x (output :x) :y (output :y) :w (output :w) :h (output :h)}))

(defn output/manage-start [output]
  (if (output :removed)
    (do
      (:destroy (output :obj))
      (bg/destroy (output :bg)))
    output))

(defn output/manage [output]
  (bg/manage (output :bg) output)
  (when (output :new)
    (let [unused (find (fn [tag] (not (find |(($ :tags) tag) (wm :outputs)))) (range 1 10))]
      (put (output :tags) unused true))))

(defn output/manage-finish [output]
  (put output :new nil))

(defn output/create [obj]
  (def output @{:obj obj
                :bg (bg/create)
                :layer-shell (:get-output (registry "river_layer_shell_v1") obj)
                :new true
                :tags @{}
                :layout ((wm :config) :default-layout)
                :layout-params @{:main-ratio ((wm :config) :main-ratio)
                                 :main-count ((wm :config) :main-count)
                                 :scroll-offset 0
                                 :column-width ((wm :config) :column-width)
                                 :dwindle-ratio ((wm :config) :dwindle-ratio)}})
  (defn handle-event [event]
    (match event
      [:removed] (put output :removed true)
      [:position x y] (do (put output :x x) (put output :y y))
      [:dimensions w h] (do (put output :w w) (put output :h h))))
  (defn handle-layer-shell-event [event]
    (match event
      [:non-exclusive-area x y w h] (put output :non-exclusive-area [x y w h])))
  (:set-user-data obj output)
  (:set-handler obj handle-event)
  (:set-handler (output :layer-shell) handle-layer-shell-event)
  output)

# --- Window Management ---

(defn window/set-position [window x y]
  (let [bw ((wm :config) :border-width)]
    (put window :x (+ x bw))
    (put window :y (+ y bw))
    (:set-position (window :node) (+ x bw) (+ y bw))))

(defn window/propose-dimensions [window w h]
  (def bw ((wm :config) :border-width))
  (:propose-dimensions (window :obj)
                       (max 1 (- w (* 2 bw)))
                       (max 1 (- h (* 2 bw)))))

(defn window/set-float [window float]
  (if float
    (:set-tiled (window :obj) {})
    (:set-tiled (window :obj) {:left true :bottom true :top true :right true}))
  (put window :float float))

(defn window/set-fullscreen [window fullscreen-output]
  (if-let [output fullscreen-output]
    (do
      (put window :fullscreen true)
      (:inform-fullscreen (window :obj))
      (:fullscreen (window :obj) (output :obj)))
    (do
      (put window :fullscreen false)
      (:inform-not-fullscreen (window :obj))
      (:exit-fullscreen (window :obj)))))

(defn window/tag-output [window]
  (find |(($ :tags) (window :tag)) (wm :outputs)))

(defn window/max-overlap-output [window]
  (var max-overlap 0)
  (var max-output nil)
  (each output (wm :outputs)
    (def ow (- (min (+ (window :x) (window :w)) (+ (output :x) (output :w)))
               (max (window :x) (output :x))))
    (def oh (- (min (+ (window :y) (window :h)) (+ (output :y) (output :h)))
               (max (window :y) (output :y))))
    (when (and (> ow 0) (> oh 0))
      (def overlap (* ow oh))
      (when (> overlap max-overlap)
        (set max-overlap overlap)
        (set max-output output))))
  max-output)

(defn window/update-tag [window]
  (when-let [output (window/max-overlap-output window)]
    (unless (= output (window/tag-output window))
      (put window :tag (or (min-of (keys (output :tags))) 1)))))

(defn window/match-rule [window]
  (each rule ((wm :config) :rules)
    (when (and (or (nil? (rule :app-id))
                   (= (rule :app-id) (window :app-id)))
               (or (nil? (rule :title))
                   (= (rule :title) (window :title))))
      (when (rule :float)
        (window/set-float window true))
      (when (rule :tag)
        (put window :tag (rule :tag))))))

# --- Seat / Input ---

(defn seat/focus-output [seat output]
  (unless (= output (seat :focused-output))
    (put seat :focused-output output)
    (when output (:set-default (output :layer-shell)))))

(defn seat/focus [seat window]
  (defn focus-window [window]
    (unless (= (seat :focused) window)
      (:focus-window (seat :obj) (window :obj))
      (put seat :focused window)
      (if-let [i (find-index |(= $ window) (wm :render-order))]
        (array/remove (wm :render-order) i))
      (array/push (wm :render-order) window)
      (:place-top (window :node))
      (when (and ((wm :config) :warp-pointer)
                 (= (seat :focus-source) :keyboard)
                 (window :w) (window :h))
        (:pointer-warp (seat :obj)
                       (+ (window :x) (div (window :w) 2))
                       (+ (window :y) (div (window :h) 2))))))

  (defn clear-focus []
    (when (seat :focused)
      (:clear-focus (seat :obj))
      (put seat :focused nil)))

  (defn focus-non-layer []
    (when window
      (when-let [output (window/tag-output window)]
        (seat/focus-output seat output)))
    (when-let [output (seat :focused-output)]
      (defn visible? [w] (and w ((output :tags) (w :tag))))
      (def visible (output/visible output (wm :render-order)))
      (cond
        (def fullscreen (last (filter |($ :fullscreen) visible)))
        (focus-window fullscreen)

        (visible? window) (focus-window window)
        (visible? (seat :focused)) (do)
        (def top-visible (last visible)) (focus-window top-visible)
        (clear-focus))))

  (case (seat :layer-focus)
    :exclusive (put seat :focused nil)
    :non-exclusive (if window
                     (do (put seat :layer-focus :none) (focus-non-layer))
                     (put seat :focused nil))
    :none (focus-non-layer)))

(defn seat/pointer-move [seat window]
  (unless (seat :op)
    (seat/focus seat window)
    (window/set-float window true)
    (:op-start-pointer (seat :obj))
    (put seat :op @{:type :move :window window
                    :start-x (window :x) :start-y (window :y)
                    :dx 0 :dy 0})))

(defn seat/pointer-resize [seat window edges]
  (unless (seat :op)
    (seat/focus seat window)
    (window/set-float window true)
    (:op-start-pointer (seat :obj))
    (put seat :op @{:type :resize :window window :edges edges
                    :start-x (window :x) :start-y (window :y)
                    :start-w (window :w) :start-h (window :h)
                    :dx 0 :dy 0})))

# --- Window Management ---

(defn window/manage-start [window]
  (if (window :closed)
    (do
      (:destroy (window :obj))
      (:destroy (window :node)))
    window))

(defn window/manage [window]
  (when (window :new)
    (:use-ssd (window :obj))
    (if-let [parent (window :parent)]
      (do
        (window/set-float window true)
        (put window :tag (parent :tag))
        (:propose-dimensions (window :obj) 0 0))
      (do
        (window/set-float window false)
        (when-let [seat (first (wm :seats))
                   output (seat :focused-output)]
          (put window :tag (or (min-of (keys (output :tags))) 1)))
        (window/match-rule window))))

  (match (window :fullscreen-requested)
    [:enter] (if-let [seat (first (wm :seats))
                      output (seat :focused-output)]
               (window/set-fullscreen window output))
    [:enter output] (window/set-fullscreen window output)
    [:exit] (window/set-fullscreen window nil))

  (when-let [move (window :pointer-move-requested)]
    (seat/pointer-move (move :seat) window))
  (when-let [resize (window :pointer-resize-requested)]
    (seat/pointer-resize (resize :seat) window (resize :edges))))

(defn window/manage-finish [window]
  (put window :new nil)
  (put window :pointer-move-requested nil)
  (put window :pointer-resize-requested nil)
  (put window :fullscreen-requested nil))

(defn window/create [obj]
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

# --- Border Rendering ---

(defn- set-borders [window status]
  (def cfg (wm :config))
  (def rgb (case status
             :normal (cfg :border-normal)
             :focused (cfg :border-focused)
             :urgent (cfg :border-urgent)))
  (:set-borders (window :obj)
                {:left true :bottom true :top true :right true}
                (cfg :border-width)
                ;(rgb-to-u32-rgba rgb)))

(defn window/render [window]
  (when (and (not (window :x)) (window :w))
    (if-let [output (window/max-overlap-output (window :parent))]
      (window/set-position window
                           (+ (output :x) (div (- (output :w) (window :w)) 2))
                           (+ (output :y) (div (- (output :h) (window :h)) 2)))
      (window/set-position window 0 0)))
  (if (find |(= ($ :focused) window) (wm :seats))
    (set-borders window :focused)
    (set-borders window :normal)))

# --- XKB and Pointer Bindings ---

(defn xkb-binding/create [seat keysym mods action]
  (def binding @{:obj (:get-xkb-binding (registry "river_xkb_bindings_v1")
                                        (seat :obj) (xkbcommon/keysym keysym) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :xkb-bindings) binding))

(defn pointer-binding/create [seat button mods action]
  (def button-code {:left 0x110 :right 0x111 :middle 0x112})
  (def binding @{:obj (:get-pointer-binding (seat :obj) (button-code button) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :pointer-bindings) binding))

# --- Seat Lifecycle ---

(defn seat/manage-start [seat]
  (if (seat :removed)
    (:destroy (seat :obj))
    seat))

(defn seat/manage [seat]
  (when (seat :new)
    (each binding (config :xkb-bindings)
      (xkb-binding/create seat ;binding))
    (each binding (config :pointer-bindings)
      (pointer-binding/create seat ;binding)))

  (when-let [window (seat :focused)]
    (when (window :closed) (put seat :focused nil)))
  (when-let [op (seat :op)]
    (when ((op :window) :closed) (put seat :op nil)))

  (if (or (not (seat :focused-output))
          ((seat :focused-output) :removed))
    (seat/focus-output seat (first (wm :outputs))))

  (put seat :focus-source :pointer)
  (seat/focus seat nil)
  (each window (wm :windows)
    (when (window :new) (seat/focus seat window)))
  (if-let [window (seat :window-interaction)]
    (seat/focus seat window))

  (put seat :focus-source :keyboard)
  (when-let [[binding action] (seat :pending-action)]
    (action seat binding))

  (put seat :focus-source :pointer)
  (seat/focus seat nil)

  (when-let [op (seat :op)]
    (when (= :resize (op :type))
      (window/propose-dimensions (op :window)
                                 (max 1 (+ (op :start-w) (op :dx)))
                                 (max 1 (+ (op :start-h) (op :dy))))))
  (when (and (seat :op-release) (seat :op))
    (:op-end (seat :obj))
    (window/update-tag ((seat :op) :window))
    (seat/focus-output seat (window/tag-output ((seat :op) :window)))
    (put seat :op nil)))

(defn seat/manage-finish [seat]
  (put seat :new nil)
  (put seat :window-interaction nil)
  (put seat :pending-action nil)
  (put seat :op-release nil)
  (put seat :focus-source nil))

(defn seat/render [seat]
  (when-let [op (seat :op)]
    (when (= :move (op :type))
      (window/set-position (op :window)
                           (+ (op :start-x) (op :dx))
                           (+ (op :start-y) (op :dy))))))

(defn seat/create [obj]
  (def seat @{:obj obj
              :layer-shell (:get-seat (registry "river_layer_shell_v1") obj)
              :layer-focus :none
              :xkb-bindings @[]
              :pointer-bindings @[]
              :new true})
  (defn handle-event [event]
    (match event
      [:removed] (put seat :removed true)
      [:pointer-enter window] (put seat :pointer-target (:get-user-data window))
      [:pointer-leave] (put seat :pointer-target nil)
      [:pointer-position x y] (do (put seat :pointer-x x) (put seat :pointer-y y))
      [:window-interaction window] (put seat :window-interaction (:get-user-data window))
      [:shell-surface-interaction _] (do)
      [:op-delta dx dy] (do (put (seat :op) :dx dx) (put (seat :op) :dy dy))
      [:op-release] (put seat :op-release true)))
  (defn handle-layer-shell-event [event]
    (match event
      [:focus-exclusive] (put seat :layer-focus :exclusive)
      [:focus-non-exclusive] (put seat :layer-focus :non-exclusive)
      [:focus-none] (put seat :layer-focus :none)))
  (:set-handler obj handle-event)
  (:set-handler (seat :layer-shell) handle-layer-shell-event)
  (:set-user-data obj seat)
  (:set-xcursor-theme obj ((wm :config) :xcursor-theme) ((wm :config) :xcursor-size))
  seat)

# --- Layout ---

(defn layout/master-stack [output windows]
  (def params (output :layout-params))
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def main-count (min (params :main-count) n))
  (def side-count (- n main-count))

  (if (<= side-count 0)
    # All windows are masters — stack vertically
    (let [cell-h (div total-h n)
          rem (% total-h n)]
      (for i 0 n
        (def y-off (+ (* cell-h i) (min i rem)))
        (def h (+ cell-h (if (< i rem) 1 0)))
        (window/set-position (get windows i)
                             (+ (usable :x) outer inner)
                             (+ (usable :y) outer y-off inner))
        (window/propose-dimensions (get windows i)
                                   (- total-w (* 2 inner))
                                   (- h (* 2 inner)))))
    (do
      (def main-w (math/round (* total-w (params :main-ratio))))
      (def side-w (- total-w main-w))

      # Master windows
      (let [master-h (div total-h main-count)
            master-rem (% total-h main-count)]
        (for i 0 main-count
          (def y-off (+ (* master-h i) (min i master-rem)))
          (def h (+ master-h (if (< i master-rem) 1 0)))
          (window/set-position (get windows i)
                               (+ (usable :x) outer inner)
                               (+ (usable :y) outer y-off inner))
          (window/propose-dimensions (get windows i)
                                     (- main-w (* 2 inner))
                                     (- h (* 2 inner)))))

      # Stack windows
      (let [side-h (div total-h side-count)
            side-rem (% total-h side-count)]
        (for i 0 side-count
          (def y-off (+ (* side-h i) (min i side-rem)))
          (def h (+ side-h (if (< i side-rem) 1 0)))
          (window/set-position (get windows (+ main-count i))
                               (+ (usable :x) outer main-w inner)
                               (+ (usable :y) outer y-off inner))
          (window/propose-dimensions (get windows (+ main-count i))
                                     (- side-w (* 2 inner))
                                     (- h (* 2 inner))))))))

(defn layout/monocle [output windows]
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (each window windows
    (window/set-position window
                         (+ (usable :x) outer inner)
                         (+ (usable :y) outer inner))
    (window/propose-dimensions window
                               (- total-w (* 2 inner))
                               (- total-h (* 2 inner)))))

(defn layout/grid [output windows]
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def cols (math/ceil (math/sqrt n)))
  (def rows (math/ceil (/ n cols)))
  (def cell-w (div total-w cols))
  (def cell-h (div total-h rows))
  (for i 0 n
    (def row (div i cols))
    (def col (% i cols))
    # Last row: distribute remaining windows across full width
    (def row-count (if (= row (- rows 1)) (- n (* row cols)) cols))
    (def this-cell-w (if (= row (- rows 1)) (div total-w row-count) cell-w))
    (def this-col (if (= row (- rows 1)) (- i (* row cols)) col))
    (window/set-position (get windows i)
                         (+ (usable :x) outer (* this-col this-cell-w) inner)
                         (+ (usable :y) outer (* row cell-h) inner))
    (window/propose-dimensions (get windows i)
                               (- this-cell-w (* 2 inner))
                               (- cell-h (* 2 inner)))))

(defn layout/centered-master [output windows]
  (def params (output :layout-params))
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (cond
    (= n 1)
    (do
      (window/set-position (first windows)
                           (+ (usable :x) outer inner)
                           (+ (usable :y) outer inner))
      (window/propose-dimensions (first windows)
                                 (- total-w (* 2 inner))
                                 (- total-h (* 2 inner))))
    (= n 2)
    # Degenerate to master-stack
    (layout/master-stack output windows)

    # 3+ windows: left stack | center master | right stack
    (let [side-count (- n 1)
          left-count (math/ceil (/ side-count 2))
          right-count (- side-count left-count)
          center-w (math/round (* total-w (params :main-ratio)))
          side-total (- total-w center-w)
          left-w (div side-total 2)
          right-w (- side-total left-w)]

      # Center master
      (window/set-position (first windows)
                           (+ (usable :x) outer left-w inner)
                           (+ (usable :y) outer inner))
      (window/propose-dimensions (first windows)
                                 (- center-w (* 2 inner))
                                 (- total-h (* 2 inner)))

      # Left stack
      (let [lh (div total-h left-count)
            lrem (% total-h left-count)]
        (for i 0 left-count
          (def y-off (+ (* lh i) (min i lrem)))
          (def h (+ lh (if (< i lrem) 1 0)))
          (window/set-position (get windows (+ 1 i))
                               (+ (usable :x) outer inner)
                               (+ (usable :y) outer y-off inner))
          (window/propose-dimensions (get windows (+ 1 i))
                                     (- left-w (* 2 inner))
                                     (- h (* 2 inner)))))

      # Right stack
      (when (> right-count 0)
        (let [rh (div total-h right-count)
              rrem (% total-h right-count)]
          (for i 0 right-count
            (def y-off (+ (* rh i) (min i rrem)))
            (def h (+ rh (if (< i rrem) 1 0)))
            (window/set-position (get windows (+ 1 left-count i))
                                 (+ (usable :x) outer left-w center-w inner)
                                 (+ (usable :y) outer y-off inner))
            (window/propose-dimensions (get windows (+ 1 left-count i))
                                       (- right-w (* 2 inner))
                                       (- h (* 2 inner)))))))))

(defn layout/dwindle [output windows]
  (def params (output :layout-params))
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def ratio (params :dwindle-ratio))
  (var x (+ (usable :x) outer))
  (var y (+ (usable :y) outer))
  (var w total-w)
  (var h total-h)
  (for i 0 n
    (if (= i (- n 1))
      (do
        (window/set-position (get windows i) (+ x inner) (+ y inner))
        (window/propose-dimensions (get windows i) (- w (* 2 inner)) (- h (* 2 inner))))
      (do
        (if (= 0 (% i 2))
          # Vertical split
          (let [split-w (math/round (* w ratio))]
            (window/set-position (get windows i) (+ x inner) (+ y inner))
            (window/propose-dimensions (get windows i) (- split-w (* 2 inner)) (- h (* 2 inner)))
            (set x (+ x split-w))
            (set w (- w split-w)))
          # Horizontal split
          (let [split-h (math/round (* h ratio))]
            (window/set-position (get windows i) (+ x inner) (+ y inner))
            (window/propose-dimensions (get windows i) (- w (* 2 inner)) (- split-h (* 2 inner)))
            (set y (+ y split-h))
            (set h (- h split-h))))))))

(defn layout/columns [output windows]
  (def params (output :layout-params))
  (def cfg (wm :config))
  (def usable (output/usable-area output))
  (def outer (cfg :outer-padding))
  (def inner (cfg :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def n (length windows))
  (def col-w (math/round (* total-w (params :column-width))))

  # Auto-scroll: find focused window index
  (def focused-idx
    (or (find-index |(find (fn [s] (= (s :focused) $)) (wm :seats)) windows) 0))
  (def focused-x (* focused-idx col-w))
  (def viewport-w total-w)

  # Adjust scroll-offset so focused column is in view
  (var scroll (params :scroll-offset))
  (when (< focused-x scroll)
    (set scroll focused-x))
  (when (> (+ focused-x col-w) (+ scroll viewport-w))
    (set scroll (- (+ focused-x col-w) viewport-w)))
  (put params :scroll-offset scroll)

  (for i 0 n
    (def x-off (- (* i col-w) scroll))
    (def win (get windows i))
    (if (or (<= (+ x-off col-w) 0) (>= x-off total-w))
      (put win :layout-hidden true)
      (do
        (window/set-position win
                             (+ (usable :x) outer x-off inner)
                             (+ (usable :y) outer inner))
        (window/propose-dimensions win
                                   (- col-w (* 2 inner))
                                   (- total-h (* 2 inner)))))))

(def layout-fns
  @{:master-stack layout/master-stack
    :monocle layout/monocle
    :grid layout/grid
    :centered-master layout/centered-master
    :dwindle layout/dwindle
    :columns layout/columns})

(defn layout/apply [output]
  (def windows (filter |(not (or ($ :float) ($ :fullscreen)))
                       (output/visible output (wm :windows))))
  (when (empty? windows) (break))
  (def layout-fn (get layout-fns (output :layout) layout/master-stack))
  (layout-fn output windows))

# --- Show/Hide ---

(defn wm/show-hide []
  (def all-tags @{})
  (each output (wm :outputs)
    (merge-into all-tags (output :tags))
    (each window (wm :windows)
      (when (and (window :fullscreen) ((output :tags) (window :tag)))
        (:fullscreen (window :obj) (output :obj)))))
  (each window (wm :windows)
    (if (and (all-tags (window :tag)) (not (window :layout-hidden)))
      (:show (window :obj))
      (:hide (window :obj)))))

# --- Indicators ---

(defn indicator/tags-changed []
  (when ((wm :config) :indicator-file)
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (def focused-output (when-let [seat (first (wm :seats))]
                            (seat :focused-output)))
      (def occupied @{})
      (each window (wm :windows)
        (unless (window :closed)
          (put occupied (window :tag) true)))
      (def occupied-tags (sorted (keys occupied)))
      (def occupied-str (string/join (map string occupied-tags) ","))

      # Global file (backward compat)
      (def focused-tags
        (if focused-output
          (sorted (keys (focused-output :tags)))
          @[]))
      (def focused-str (string/join (map string focused-tags) ","))
      (spit (string rd "/tidepool-tags")
            (string "focused:" focused-str " occupied:" occupied-str))

      # Per-output files
      (each output (wm :outputs)
        (def output-tags (sorted (keys (output :tags))))
        (def output-str (string/join (map string output-tags) ","))
        (def active (= output focused-output))
        (spit (string rd "/tidepool-tags-" (output :x) "," (output :y))
              (string "focused:" output-str
                      " occupied:" occupied-str
                      " active:" (if active "true" "false")))
        (spit (string rd "/tidepool-layout-" (output :x) "," (output :y))
              (string (output :layout))))

      # Global layout file (focused output's layout)
      (when focused-output
        (spit (string rd "/tidepool-layout")
              (string (focused-output :layout)))))))

# --- Manage / Render Phases ---

(defn wm/manage []
  (update wm :render-order |(filter (fn [w] (not (w :closed))) $))

  (update wm :outputs |(keep output/manage-start $))
  (update wm :windows |(keep window/manage-start $))
  (update wm :seats |(keep seat/manage-start $))

  (each output (wm :outputs) (output/manage output))
  (each window (wm :windows) (window/manage window))
  (each seat (wm :seats) (seat/manage seat))

  (each window (wm :windows) (put window :layout-hidden nil))
  (each output (wm :outputs) (layout/apply output))
  (wm/show-hide)

  (each output (wm :outputs) (output/manage-finish output))
  (each window (wm :windows) (window/manage-finish window))
  (each seat (wm :seats) (seat/manage-finish seat))

  (indicator/tags-changed)
  (:manage-finish (registry "river_window_manager_v1")))

(defn wm/render []
  (each window (wm :windows) (window/render window))
  (each seat (wm :seats) (seat/render seat))
  (:render-finish (registry "river_window_manager_v1")))

# --- Actions ---

(defn- clamp [x lo hi] (min hi (max lo x)))
(defn- wrap [x n] (% (+ (% x n) n) n))

# Layout-aware spatial navigation. Each layout defines a function
# (fn [n main-count i dir]) -> target index, where n is window count,
# main-count is the layout's main pane count, i is the focused index,
# and dir is :left/:right/:up/:down.

(defn- navigate/master-stack [n main-count i dir]
  (def in-main (< i main-count))
  (if in-main
    (case dir
      :right (when (> n main-count) main-count)
      :left nil
      :down (when (< (+ i 1) main-count) (+ i 1))
      :up (when (> i 0) (- i 1)))
    (let [si (- i main-count)
          sc (- n main-count)]
      (case dir
        :left 0
        :right nil
        :down (when (< (+ si 1) sc) (+ main-count si 1))
        :up (when (> si 0) (+ main-count si -1))))))

(defn- navigate/monocle [n _ i dir]
  (case dir
    :right (when (< (+ i 1) n) (+ i 1))
    :down (when (< (+ i 1) n) (+ i 1))
    :left (when (> i 0) (- i 1))
    :up (when (> i 0) (- i 1))))

(defn- navigate/grid [n _ i dir]
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

(defn- navigate/centered-master [n _ i dir]
  (cond
    (<= n 2) (navigate/master-stack n 1 i dir)
    (do
      (def side-count (- n 1))
      (def left-count (math/ceil (/ side-count 2)))
      (def right-count (- side-count left-count))
      (cond
        # Master (index 0): center column
        (= i 0)
        (case dir
          :left (when (> left-count 0) 1)
          :right (when (> right-count 0) (+ 1 left-count))
          :up nil :down nil)
        # Left stack (indices 1..left-count)
        (<= i left-count)
        (let [li (- i 1)]
          (case dir
            :right 0
            :left nil
            :down (when (< (+ li 1) left-count) (+ i 1))
            :up (when (> li 0) (- i 1))))
        # Right stack (indices left-count+1..)
        (let [ri (- i 1 left-count)]
          (case dir
            :left 0
            :right nil
            :down (when (< (+ ri 1) right-count) (+ i 1))
            :up (when (> ri 0) (- i 1))))))))

(defn- navigate/dwindle [n _ i dir]
  # Dwindle alternates vertical/horizontal splits. At each level,
  # even splits go left|right, odd splits go top|bottom.
  # Navigate by checking parent/child split orientation.
  (cond
    (< i (- n 1))
    (let [split-horizontal (= 0 (% i 2))]
      (case dir
        # Into the split: go to child
        :right (when (and split-horizontal (< (+ i 1) n)) (+ i 1))
        :down (when (and (not split-horizontal) (< (+ i 1) n)) (+ i 1))
        # Against the split or parallel: go to parent
        :left (when (and split-horizontal (> i 0)) (- i 1))
        :up (when (and (not split-horizontal) (> i 0)) (- i 1))
        # Parallel movement within sibling
        (when (> i 0) (- i 1))))
    # Last window: can only go back
    (when (> i 0) (- i 1))))

(defn- navigate/columns [n _ i dir]
  (case dir
    :left (when (> i 0) (- i 1))
    :right (when (< (+ i 1) n) (+ i 1))
    :up nil :down nil))

(def navigate-fns
  @{:master-stack navigate/master-stack
    :monocle navigate/monocle
    :grid navigate/grid
    :centered-master navigate/centered-master
    :dwindle navigate/dwindle
    :columns navigate/columns})

(defn- find-adjacent-output [current dir]
  (var best nil)
  (var best-dist math/inf)
  (each output (wm :outputs)
    (when (not= output current)
      (def dist
        (case dir
          :right (when (>= (output :x) (+ (current :x) (current :w)))
                   (- (output :x) (+ (current :x) (current :w))))
          :left (when (<= (+ (output :x) (output :w)) (current :x))
                  (- (current :x) (+ (output :x) (output :w))))
          :down (when (>= (output :y) (+ (current :y) (current :h)))
                  (- (output :y) (+ (current :y) (current :h))))
          :up (when (<= (+ (output :y) (output :h)) (current :y))
                (- (current :y) (+ (output :y) (output :h))))))
      (when (and dist (< dist best-dist))
        (set best output)
        (set best-dist dist))))
  best)

(defn action/target [seat dir]
  (when-let [window (seat :focused)
             output (window/tag-output window)
             visible (output/visible output (wm :windows))
             i (assert (index-of window visible))]
    (case dir
      :next (get visible (+ i 1) (first visible))
      :prev (get visible (- i 1) (last visible))
      (let [n (length visible)
            layout (output :layout)
            main-count (get-in output [:layout-params :main-count] 1)
            nav-fn (get navigate-fns layout navigate/master-stack)
            target-i (nav-fn n main-count i dir)]
        (when target-i (get visible target-i))))))

(defn action/spawn [command]
  (fn [seat binding]
    (ev/spawn (os/proc-wait (os/spawn command :p)))))

(defn action/close []
  (fn [seat binding]
    (when-let [window (seat :focused)]
      (:close (window :obj)))))

(defn action/zoom []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               output (window/tag-output focused)
               visible (output/visible output (wm :windows))
               target (if (= focused (first visible)) (get visible 1) focused)
               i (assert (index-of target (wm :windows)))]
      (array/remove (wm :windows) i)
      (array/insert (wm :windows) 0 target)
      (seat/focus seat (first (wm :windows))))))

(defn action/focus [dir]
  (fn [seat binding]
    (if-let [target (action/target seat dir)]
      (seat/focus seat target)
      # No target in current output — try adjacent monitor
      (when-let [current (or (when-let [w (seat :focused)] (window/tag-output w))
                             (seat :focused-output))
                 adjacent (find-adjacent-output current dir)]
        (seat/focus-output seat adjacent)
        (seat/focus seat nil)))))

(defn action/swap [dir]
  (fn [seat binding]
    (when-let [window (seat :focused)
               target (action/target seat dir)
               wi (assert (index-of window (wm :windows)))
               ti (assert (index-of target (wm :windows)))]
      (put (wm :windows) wi target)
      (put (wm :windows) ti window))))

(defn action/focus-output []
  (fn [seat binding]
    (when-let [focused (seat :focused-output)
               i (assert (index-of focused (wm :outputs)))
               target (or (get (wm :outputs) (+ i 1)) (first (wm :outputs)))]
      (seat/focus-output seat target)
      (seat/focus seat nil))))

(defn action/send-to-output []
  (fn [seat binding]
    (when-let [window (seat :focused)
               current (seat :focused-output)
               i (assert (index-of current (wm :outputs)))
               target (or (get (wm :outputs) (+ i 1)) (first (wm :outputs)))]
      (put window :tag (or (min-of (keys (target :tags))) 1)))))

(defn action/float []
  (fn [seat binding]
    (when-let [window (seat :focused)]
      (window/set-float window (not (window :float))))))

(defn action/fullscreen []
  (fn [seat binding]
    (when-let [window (seat :focused)]
      (if (window :fullscreen)
        (window/set-fullscreen window nil)
        (window/set-fullscreen window (window/tag-output window))))))

(defn action/set-tag [tag]
  (fn [seat binding]
    (when-let [window (seat :focused)]
      (put window :tag tag))))

(defn- fallback-tags [outputs]
  (for tag 1 10
    (unless (find |(($ :tags) tag) outputs)
      (when-let [output (find |(empty? ($ :tags)) outputs)]
        (put (output :tags) tag true)))))

(defn action/focus-tag [tag]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (tag-layout/save output)
      (each o (wm :outputs) (put (o :tags) tag nil))
      (put output :tags @{tag true})
      (fallback-tags (wm :outputs))
      (tag-layout/restore output)
      (indicator/layout-changed output))))

(defn action/toggle-tag [tag]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (tag-layout/save output)
      (if ((output :tags) tag)
        (put (output :tags) tag nil)
        (do
          (each o (wm :outputs) (put (o :tags) tag nil))
          (put (output :tags) tag true)))
      (fallback-tags (wm :outputs))
      (tag-layout/restore output)
      (indicator/layout-changed output))))

(defn action/focus-all-tags []
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (each o (wm :outputs) (put o :tags @{}))
      (put output :tags (table ;(mapcat |[$ true] (range 1 10)))))))

(defn- output/primary-tag [output]
  (min-of (keys (output :tags))))

(defn tag-layout/save [output]
  (when-let [tag (output/primary-tag output)]
    (put tag-layouts tag
         @{:layout (output :layout)
           :params (table/clone (output :layout-params))})))

(defn tag-layout/restore [output]
  (when-let [tag (output/primary-tag output)
             saved (tag-layouts tag)]
    (put output :layout (saved :layout))
    (merge-into (output :layout-params) (saved :params))))

(defn indicator/layout-changed [output]
  (def name (string (output :layout)))
  (when ((wm :config) :indicator-file)
    (when-let [rd (os/getenv "XDG_RUNTIME_DIR")]
      (spit (string rd "/tidepool-layout") name)
      (spit (string rd "/tidepool-layout-" (output :x) "," (output :y)) name)))
  (when ((wm :config) :indicator-notify)
    (ev/spawn (os/proc-wait
      (os/spawn ["notify-send" "-t" "1000"
                 "-h" "string:x-canonical-private-synchronous:tidepool-layout"
                 "Layout" name] :p)))))

(defn action/adjust-ratio [delta]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (def params (output :layout-params))
      (put params :main-ratio (max 0.1 (min 0.9 (+ (params :main-ratio) delta))))
      (tag-layout/save output))))

(defn action/adjust-main-count [delta]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (def params (output :layout-params))
      (put params :main-count (max 1 (+ (params :main-count) delta)))
      (tag-layout/save output))))

(defn action/cycle-layout [dir]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (def layouts ((wm :config) :layouts))
      (def current (output :layout))
      (def i (or (index-of current layouts) 0))
      (def next-i (case dir
                    :next (% (+ i 1) (length layouts))
                    :prev (% (+ (- i 1) (length layouts)) (length layouts))))
      (put output :layout (get layouts next-i))
      (tag-layout/save output)
      (indicator/layout-changed output))))

(defn action/set-layout [layout]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (put output :layout layout)
      (tag-layout/save output)
      (indicator/layout-changed output))))

(defn action/adjust-column-width [delta]
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (def params (output :layout-params))
      (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
      (tag-layout/save output))))

(defn action/pointer-move []
  (fn [seat binding]
    (when-let [window (seat :pointer-target)]
      (seat/pointer-move seat window))))

(defn action/pointer-resize []
  (fn [seat binding]
    (when-let [window (seat :pointer-target)]
      (seat/pointer-resize seat window {:bottom true :right true}))))

(defn action/passthrough []
  (fn [seat binding]
    (put binding :passthrough (not (binding :passthrough)))
    (def request (if (binding :passthrough) :disable :enable))
    (each other (seat :xkb-bindings)
      (unless (= other binding) (request (other :obj))))
    (each other (seat :pointer-bindings)
      (unless (= other binding) (request (other :obj))))))

(defn action/toggle-scratchpad []
  (fn [seat binding]
    (when-let [output (seat :focused-output)]
      (if ((output :tags) 0)
        (put (output :tags) 0 nil)
        (put (output :tags) 0 true)))))

(defn action/send-to-scratchpad []
  (fn [seat binding]
    (when-let [window (seat :focused)]
      (put window :tag 0)
      (window/set-float window true))))

(defn action/restart []
  (fn [seat binding]
    (os/exit 42)))

(defn action/exit []
  (fn [seat binding]
    (:stop (registry "river_window_manager_v1"))))

# --- Event Dispatch ---

(defn wm/handle-event [event]
  (match event
    [:unavailable] (do (print "tidepool: another window manager is already running")
                       (os/exit 1))
    [:finished] (os/exit 0)
    [:manage-start] (wm/manage)
    [:render-start] (wm/render)
    [:output obj] (array/push (wm :outputs) (output/create obj))
    [:seat obj] (array/push (wm :seats) (seat/create obj))
    [:window obj] (array/insert (wm :windows) 0 (window/create obj))))

(defn registry/handle-event [event]
  (match event
    [:global name interface version]
    (when-let [required-version (get required-interfaces interface)]
      (when (< version required-version)
        (errorf "compositor %s version too old (need %d, got %d)"
                interface required-version version))
      (put registry interface (:bind (registry :obj) name interface required-version)))))

# --- REPL Server ---

(def repl-env (curenv))

(defn repl-server-create []
  (def path (string/format "%s/tidepool-%s"
                           (assert (os/getenv "XDG_RUNTIME_DIR"))
                           (assert (os/getenv "WAYLAND_DISPLAY"))))
  (protect (os/rm path))
  (netrepl/server :unix path repl-env))

# --- Design: Workspace Abstraction ("Pools") ---
#
# Current model: outputs have a set of visible tags (integers 0-N).
# Each window has a single tag. Tags are global — any output can show
# any tag, and toggling a tag on one output removes it from others.
#
# Limitation: no way to group related tags, name them, or create
# ephemeral workspaces. Power users want named contexts (e.g., "code",
# "comms", "media") that persist across output changes and can contain
# multiple tags. The current flat tag model can't express this.
#
# Proposed: "Pools" — a composable workspace layer on top of tags.
#
#   (def pool @{:name "code"
#               :tags #{1 2 3}       # tags belonging to this pool
#               :sticky false        # if true, pool stays on its output
#               :output nil})        # preferred output (or nil for floating)
#
# A pool groups tags into a named unit. Switching to a pool activates
# all its tags on the target output. Pools can be:
#   - Static: defined in config (e.g., "code" = tags 1-3)
#   - Dynamic: created on the fly, tags allocated from a free pool
#   - Sticky: bound to a specific output (e.g., "chat" always on right monitor)
#
# Composable views: an output can show multiple pools simultaneously.
# This is already supported by the tag model — just union the tag sets.
# Pools add naming and grouping, not new visibility semantics.
#
# Transition path:
#   1. Pools are opt-in. Without pool config, behavior is unchanged.
#   2. action/focus-pool, action/send-to-pool, action/create-pool
#   3. Bar indicator shows pool names instead of/alongside tag numbers
#   4. Dynamic pools: action/create-pool allocates unused tags
#
# Open questions:
#   - Should tags be hidden from the user entirely when pools are active?
#   - How to handle tag conflicts (two pools wanting the same tag)?
#   - Per-output pool stacks (MRU pool switching per monitor)?
#
# This is a future direction. The current tag system is the right
# foundation — pools are sugar on top, not a replacement.

# --- Entry Point ---

(defn main [& args]
  (def display (wayland/connect interfaces))
  (os/setenv "WAYLAND_DEBUG" nil)

  (def config-dir (or (os/getenv "XDG_CONFIG_HOME")
                      (string (os/getenv "HOME") "/.config")))
  (def init-path (get 1 args (string config-dir "/tidepool/init.janet")))
  (when-let [init (file/open init-path :r)]
    (dofile init :env repl-env)
    (file/close init))

  (put registry :obj (:get-registry display))
  (:set-handler (registry :obj) registry/handle-event)
  (:roundtrip display)
  (eachk i required-interfaces
    (unless (get registry i)
      (errorf "compositor does not support %s" i)))

  (:set-handler (registry "river_window_manager_v1") wm/handle-event)
  (:roundtrip display)

  (def repl-server (repl-server-create))
  (defer (:close repl-server)
    (forever (:dispatch display))))
