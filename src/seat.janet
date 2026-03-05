(import ./state)
(import ./window)
(import ./output)

(import xkbcommon)

(defn focus-output
  "Set the seat's focused output (pure data mutation)."
  [seat o]
  (unless (= o (seat :focused-output))
    (put seat :focused-output o)
    (put seat :focus-output-changed true)))

(defn focus
  "Focus a window, respecting layer shell focus state (pure data mutation)."
  [seat win render-order config]
  (defn focus-window [w]
    (unless (= (seat :focused) w)
      (when (seat :focused)
        (put seat :focus-prev (seat :focused)))
      (put seat :focused w)
      (put seat :focus-changed true)
      (if-let [i (find-index |(= $ w) render-order)]
        (array/remove render-order i))
      (array/push render-order w)
      (when (and (config :warp-pointer)
                 (= (seat :focus-source) :keyboard)
                 (w :w) (w :h))
        (put seat :warp-target w))))

  (defn clear-focus []
    (when (seat :focused)
      (put seat :focused nil)
      (put seat :focus-changed true)))

  (defn focus-non-layer []
    (when win
      (when-let [o (window/tag-output win (state/wm :outputs))]
        (focus-output seat o)))
    (when-let [o (seat :focused-output)]
      (defn visible? [w] (and w ((o :tags) (w :tag))))
      (def visible (output/visible o render-order))
      (cond
        (def fullscreen (last (filter |($ :fullscreen) visible)))
        (focus-window fullscreen)

        (visible? win) (focus-window win)
        (visible? (seat :focused)) (do)
        (def top-visible (last visible)) (focus-window top-visible)
        (clear-focus))))

  (case (seat :layer-focus)
    :exclusive (put seat :focused nil)
    :non-exclusive (if win
                     (do (put seat :layer-focus :none) (focus-non-layer))
                     (put seat :focused nil))
    :none (focus-non-layer)))

(defn pointer-move
  "Start a pointer-driven move operation on a window (pure data setup)."
  [seat win render-order config]
  (unless (seat :op)
    (focus seat win render-order config)
    (window/set-float win true)
    (put seat :op @{:type :move :window win
                    :start-x (win :x) :start-y (win :y)
                    :dx 0 :dy 0})
    (put seat :op-started true)))

(defn pointer-resize
  "Start a pointer-driven resize operation on a window (pure data setup)."
  [seat win edges render-order config]
  (unless (seat :op)
    (focus seat win render-order config)
    (window/set-float win true)
    (put seat :op @{:type :resize :window win :edges edges
                    :start-x (win :x) :start-y (win :y)
                    :start-w (win :w) :start-h (win :h)
                    :dx 0 :dy 0})
    (put seat :op-started true)))

(defn xkb-binding/create
  "Register a keyboard binding for a keysym+mods combo."
  [seat keysym mods action]
  (def binding @{:obj (:get-xkb-binding (state/registry "river_xkb_bindings_v1")
                                        (seat :obj) (xkbcommon/keysym keysym) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :xkb-bindings) binding))

(defn pointer-binding/create
  "Register a pointer binding for a button+mods combo."
  [seat button mods action]
  (def button-code {:left 0x110 :right 0x111 :middle 0x112})
  (def binding @{:obj (:get-pointer-binding (seat :obj) (button-code button) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :pointer-bindings) binding))

(defn manage-start
  "Flag removed seats for destruction."
  [seat]
  (if (seat :removed)
    (do (put seat :pending-destroy true) nil)
    seat))

(defn manage
  "Process seat state: register bindings, focus, pointer ops."
  [seat outputs windows render-order config]
  (when (seat :new)
    (each binding (config :xkb-bindings)
      (xkb-binding/create seat ;binding))
    (each binding (config :pointer-bindings)
      (pointer-binding/create seat ;binding)))

  (when-let [w (seat :focused)]
    (when (w :closed) (put seat :focused nil)))
  (when-let [w (seat :focus-prev)]
    (when (w :closed) (put seat :focus-prev nil)))
  (when-let [op (seat :op)]
    (when ((op :window) :closed) (put seat :op nil)))

  (if (or (not (seat :focused-output))
          ((seat :focused-output) :removed))
    (focus-output seat (first outputs)))

  (put seat :focus-source :pointer)
  (focus seat nil render-order config)
  (each w windows
    (when (w :new) (focus seat w render-order config)))
  (if-let [w (seat :window-interaction)]
    (focus seat w render-order config))

  (put seat :focus-source :keyboard)
  (when-let [[binding action] (seat :pending-action)]
    (action seat binding))

  (put seat :focus-source :pointer)
  (focus seat nil render-order config)

  (when-let [op (seat :op)]
    (when (= :resize (op :type))
      (window/propose-dimensions (op :window)
                                 (max 1 (+ (op :start-w) (op :dx)))
                                 (max 1 (+ (op :start-h) (op :dy)))
                                 config)))
  (when (and (seat :op-release) (seat :op))
    (put seat :op-ended true)
    (window/update-tag ((seat :op) :window) outputs)
    (focus-output seat (window/tag-output ((seat :op) :window) outputs))
    (put seat :op nil)))

(defn manage-finish
  "Clear per-frame transient state."
  [seat]
  (put seat :new nil)
  (put seat :window-interaction nil)
  (put seat :pending-action nil)
  (put seat :op-release nil)
  (put seat :focus-source nil)
  (put seat :focus-changed nil)
  (put seat :focus-output-changed nil)
  (put seat :op-started nil)
  (put seat :op-ended nil)
  (put seat :warp-target nil))

(defn render
  "Compute pointer move position during drag operations (pure data)."
  [seat]
  (when-let [op (seat :op)]
    (when (= :move (op :type))
      (window/set-position (op :window)
                           (+ (op :start-x) (op :dx))
                           (+ (op :start-y) (op :dy))))))

(defn create
  "Create a seat from a Wayland seat object."
  [obj]
  (def seat @{:obj obj
              :layer-shell (:get-seat (state/registry "river_layer_shell_v1") obj)
              :layer-focus :none
              :xkb-bindings @[]
              :pointer-bindings @[]
              :new true})
  (defn handle-event [event]
    (match event
      [:removed] (put seat :removed true)
      [:pointer-enter w] (put seat :pointer-target (:get-user-data w))
      [:pointer-leave] (put seat :pointer-target nil)
      [:pointer-position x y] (do (put seat :pointer-x x) (put seat :pointer-y y))
      [:window-interaction w] (put seat :window-interaction (:get-user-data w))
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
  (:set-xcursor-theme obj (state/config :xcursor-theme) (state/config :xcursor-size))
  seat)
