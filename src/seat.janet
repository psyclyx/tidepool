(import ./state)
(import ./window)
(import ./output)

(import xkbcommon)

(defn focus-output "Set the seat's focused output." [seat o]
  (unless (= o (seat :focused-output))
    (put seat :focused-output o)
    (when o (:set-default (o :layer-shell)))))

(defn focus "Focus a window, respecting layer shell focus state." [seat win]
  (defn focus-window [w]
    (unless (= (seat :focused) w)
      (when (seat :focused)
        (put seat :focus-prev (seat :focused)))
      (:focus-window (seat :obj) (w :obj))
      (put seat :focused w)
      (if-let [i (find-index |(= $ w) (state/wm :render-order))]
        (array/remove (state/wm :render-order) i))
      (array/push (state/wm :render-order) w)
      (:place-top (w :node))
      (when (and (state/config :warp-pointer)
                 (= (seat :focus-source) :keyboard)
                 (w :w) (w :h))
        (:pointer-warp (seat :obj)
                       (+ (w :x) (div (w :w) 2))
                       (+ (w :y) (div (w :h) 2))))))

  (defn clear-focus []
    (when (seat :focused)
      (:clear-focus (seat :obj))
      (put seat :focused nil)))

  (defn focus-non-layer []
    (when win
      (when-let [o (window/tag-output win)]
        (focus-output seat o)))
    (when-let [o (seat :focused-output)]
      (defn visible? [w] (and w ((o :tags) (w :tag))))
      (def visible (output/visible o (state/wm :render-order)))
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

(defn pointer-move "Start a pointer-driven move operation on a window." [seat win]
  (unless (seat :op)
    (focus seat win)
    (window/set-float win true)
    (:op-start-pointer (seat :obj))
    (put seat :op @{:type :move :window win
                    :start-x (win :x) :start-y (win :y)
                    :dx 0 :dy 0})))

(defn pointer-resize "Start a pointer-driven resize operation on a window." [seat win edges]
  (unless (seat :op)
    (focus seat win)
    (window/set-float win true)
    (:op-start-pointer (seat :obj))
    (put seat :op @{:type :resize :window win :edges edges
                    :start-x (win :x) :start-y (win :y)
                    :start-w (win :w) :start-h (win :h)
                    :dx 0 :dy 0})))

(defn xkb-binding/create "Register a keyboard binding for a keysym+mods combo." [seat keysym mods action]
  (def binding @{:obj (:get-xkb-binding (state/registry "river_xkb_bindings_v1")
                                        (seat :obj) (xkbcommon/keysym keysym) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :xkb-bindings) binding))

(defn pointer-binding/create "Register a pointer binding for a button+mods combo." [seat button mods action]
  (def button-code {:left 0x110 :right 0x111 :middle 0x112})
  (def binding @{:obj (:get-pointer-binding (seat :obj) (button-code button) mods)})
  (defn handle-event [event]
    (match event
      [:pressed] (put seat :pending-action [binding action])))
  (:set-handler (binding :obj) handle-event)
  (:enable (binding :obj))
  (array/push (seat :pointer-bindings) binding))

(defn manage-start "Destroy removed seats or pass through." [seat]
  (if (seat :removed)
    (:destroy (seat :obj))
    seat))

(defn manage "Process seat state: register bindings, focus, pointer ops." [seat]
  (when (seat :new)
    (each binding (state/config :xkb-bindings)
      (xkb-binding/create seat ;binding))
    (each binding (state/config :pointer-bindings)
      (pointer-binding/create seat ;binding)))

  (when-let [w (seat :focused)]
    (when (w :closed) (put seat :focused nil)))
  (when-let [w (seat :focus-prev)]
    (when (w :closed) (put seat :focus-prev nil)))
  (when-let [op (seat :op)]
    (when ((op :window) :closed) (put seat :op nil)))

  (if (or (not (seat :focused-output))
          ((seat :focused-output) :removed))
    (focus-output seat (first (state/wm :outputs))))

  (put seat :focus-source :pointer)
  (focus seat nil)
  (each w (state/wm :windows)
    (when (w :new) (focus seat w)))
  (if-let [w (seat :window-interaction)]
    (focus seat w))

  (put seat :focus-source :keyboard)
  (when-let [[binding action] (seat :pending-action)]
    (action seat binding))

  (put seat :focus-source :pointer)
  (focus seat nil)

  (when-let [op (seat :op)]
    (when (= :resize (op :type))
      (window/propose-dimensions (op :window)
                                 (max 1 (+ (op :start-w) (op :dx)))
                                 (max 1 (+ (op :start-h) (op :dy))))))
  (when (and (seat :op-release) (seat :op))
    (:op-end (seat :obj))
    (window/update-tag ((seat :op) :window))
    (focus-output seat (window/tag-output ((seat :op) :window)))
    (put seat :op nil)))

(defn manage-finish "Clear per-frame transient state." [seat]
  (put seat :new nil)
  (put seat :window-interaction nil)
  (put seat :pending-action nil)
  (put seat :op-release nil)
  (put seat :focus-source nil))

(defn render "Apply pointer move position during drag operations." [seat]
  (when-let [op (seat :op)]
    (when (= :move (op :type))
      (window/set-position (op :window)
                           (+ (op :start-x) (op :dx))
                           (+ (op :start-y) (op :dy))))))

(defn create "Create a seat from a Wayland seat object." [obj]
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
