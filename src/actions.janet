(import ./window)
(import ./output)
(import ./seat)
(import ./layout)

(defn- clamp [x lo hi] (min hi (max lo x)))
(defn- wrap [x n] (% (+ (% x n) n) n))

(defn- output/primary-tag [o]
  (min-of (keys (o :tags))))

(defn tag-layout/save
  "Persist the current layout for the output's primary tag."
  [o tag-layouts]
  (when-let [tag (output/primary-tag o)]
    (put tag-layouts tag
         @{:layout (o :layout)
           :params (table/clone (o :layout-params))})))

# --- Action tagging ---

(defn act
  "Wrap a closure with action metadata for IPC dispatch."
  [name desc args make-fn]
  (def action-fn (make-fn))
  @{:fn action-fn :name name :desc desc :args args})

# --- Navigation ---

(defn- find-adjacent-output [current outputs dir]
  (var best nil)
  (var best-dist math/inf)
  (each o outputs
    (when (not= o current)
      (def dist
        (case dir
          :right (when (>= (o :x) (+ (current :x) (current :w)))
                   (- (o :x) (+ (current :x) (current :w))))
          :left (when (<= (+ (o :x) (o :w)) (current :x))
                  (- (current :x) (+ (o :x) (o :w))))
          :down (when (>= (o :y) (+ (current :y) (current :h)))
                  (- (o :y) (+ (current :y) (current :h))))
          :up (when (<= (+ (o :y) (o :h)) (current :y))
                (- (current :y) (+ (o :y) (o :h))))))
      (when (and dist (< dist best-dist))
        (set best o)
        (set best-dist dist))))
  best)

(defn target
  "Find the navigation target window for a seat in the given direction."
  [ctx dir]
  (def {:seat seat :outputs outputs :windows windows :config config} ctx)
  (when-let [w (seat :focused)
             o (window/tag-output w outputs)
             visible (output/visible o windows)
             i (assert (index-of w visible))]
    (case dir
      :next (get visible (+ i 1) (first visible))
      :prev (get visible (- i 1) (last visible))
      (let [tiled (filter |(not (or ($ :float) ($ :fullscreen))) visible)
            ti (index-of w tiled)]
        (when ti
          (def lo (o :layout))
          (def target-i
            (if-let [nav-fn (get layout/navigate-fns lo)]
              (let [ctx-fn (get layout/context-fns lo)
                    nav-ctx (when ctx-fn (ctx-fn o windows w (seat :focus-prev)))]
                (nav-fn (length tiled) (get-in o [:layout-params :main-count] 1) ti dir
                  (or nav-ctx {:output o :windows tiled :focused w})))
              (let [layout-fn (get layout/layout-fns lo (layout/layout-fns :master-stack))
                    results (layout-fn (output/usable-area o) tiled
                              (o :layout-params) config w)]
                (layout/navigate-by-geometry results ti dir))))
          (when target-i (get tiled target-i)))))))

(defn- focused-column [ctx]
  (def {:seat seat :windows windows} ctx)
  (when-let [o (seat :focused-output)
             ctx-fn (get layout/context-fns (o :layout))]
    (when-let [sctx (ctx-fn o windows (seat :focused) (seat :focus-prev))]
      (get (sctx :cols) (sctx :focused-col)))))

# --- Window actions ---

(defn spawn
  "Action: spawn a command."
  [command]
  (act "spawn" "Spawn command" [command]
    (fn [] (fn [ctx]
      (ev/spawn (os/proc-wait (os/spawn command :p)))))))

(defn close
  "Action: close the focused window."
  []
  (act "close" "Close window" []
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        (:close (w :obj)))))))

(defn zoom
  "Action: swap the focused window to master position."
  []
  (act "zoom" "Zoom to master" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows
            :render-order render-order :config config} ctx)
      (when-let [focused (seat :focused)
                 o (window/tag-output focused outputs)
                 visible (output/visible o windows)
                 t (if (= focused (first visible)) (get visible 1) focused)
                 i (assert (index-of t windows))]
        (array/remove windows i)
        (array/insert windows 0 t)
        (seat/focus seat (first windows) outputs render-order config))))))

(defn focus
  "Action: focus in a direction, crossing outputs if needed."
  [dir]
  (act "focus" "Focus" [dir]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows
            :render-order render-order :config config} ctx)
      (if-let [t (target ctx dir)]
        (seat/focus seat t outputs render-order config)
        (when-let [current (or (when-let [w (seat :focused)] (window/tag-output w outputs))
                               (seat :focused-output))]
          (if-let [adjacent (find-adjacent-output current outputs dir)]
            (do (seat/focus-output seat adjacent)
                (seat/focus seat nil outputs render-order config))
            # Nothing focused and no adjacent output — pick top visible window
            (unless (seat :focused)
              (when-let [visible (output/visible current windows)
                         top (last visible)]
                (seat/focus seat top outputs render-order config))))))))))

(defn swap
  "Action: swap the focused window in a direction."
  [dir]
  (act "swap" "Swap" [dir]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows} ctx)
      (when-let [w (seat :focused)]
        (if-let [t (target ctx dir)
                 wi (index-of w windows)
                 ti (index-of t windows)]
          (do
            (def wc (w :column))
            (def tc (t :column))
            (put w :column tc)
            (put t :column wc)
            (def wcw (w :col-width))
            (def tcw (t :col-width))
            (put w :col-width tcw)
            (put t :col-width wcw)
            (def wcwt (w :col-weight))
            (def tcwt (t :col-weight))
            (put w :col-weight tcwt)
            (put t :col-weight wcwt)
            (put windows wi t)
            (put windows ti w))
          (when-let [current (window/tag-output w outputs)
                     adjacent (find-adjacent-output current outputs dir)]
            (put w :tag (or (min-of (keys (adjacent :tags))) 1))
            (put w :column nil)
            (put w :col-width nil)
            (put w :col-weight nil)
            (seat/focus-output seat adjacent))))))))

(defn focus-output
  "Action: focus the next or adjacent output."
  [&opt dir]
  (act "focus-output" "Focus output" [(or dir :next)]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (if dir
        (when-let [current (or (seat :focused-output) (first outputs))
                   adjacent (find-adjacent-output current outputs dir)]
          (seat/focus-output seat adjacent)
          (seat/focus seat nil outputs render-order config))
        (when-let [focused (seat :focused-output)
                   i (assert (index-of focused outputs))
                   t (or (get outputs (+ i 1)) (first outputs))]
          (seat/focus-output seat t)
          (seat/focus seat nil outputs render-order config)))))))

(defn focus-last
  "Action: focus the previously focused window."
  []
  (act "focus-last" "Focus last" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (when-let [prev (seat :focus-prev)]
        (when (and (not (prev :closed))
                   (window/tag-output prev outputs))
          (seat/focus seat prev outputs render-order config)))))))

(defn send-to-output
  "Action: send the focused window to the next output."
  []
  (act "send-to-output" "Send to output" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs} ctx)
      (when-let [w (seat :focused)
                 current (seat :focused-output)
                 i (assert (index-of current outputs))
                 t (or (get outputs (+ i 1)) (first outputs))]
        (put w :tag (or (min-of (keys (t :tags))) 1)))))))

(defn float
  "Action: toggle floating on the focused window."
  []
  (act "float" "Toggle float" []
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        (window/set-float w (not (w :float))))))))

(defn fullscreen
  "Action: toggle fullscreen on the focused window."
  []
  (act "fullscreen" "Toggle fullscreen" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs} ctx)
      (when-let [w (seat :focused)]
        (if (w :fullscreen)
          (window/set-fullscreen w nil)
          (window/set-fullscreen w (window/tag-output w outputs))))))))

# --- Tags ---

(defn set-tag
  "Action: move the focused window to a tag."
  [tag]
  (act "set-tag" "Set tag" [tag]
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        (put w :tag tag))))))

(defn focus-tag
  "Action: show only the given tag on the focused output."
  [tag]
  (act "focus-tag" "Focus tag" [tag]
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)]
        (put o :tags @{tag true}))))))

(defn toggle-tag
  "Action: toggle a tag's visibility on the focused output."
  [tag]
  (act "toggle-tag" "Toggle tag" [tag]
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)]
        (if ((o :tags) tag)
          (put (o :tags) tag nil)
          (put (o :tags) tag true)))))))

(defn focus-all-tags
  "Action: show all tags on the focused output."
  []
  (act "focus-all-tags" "Show all tags" []
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)]
        (put o :tags (table ;(mapcat |[$ true] (range 1 10)))))))))

(defn toggle-scratchpad
  "Action: toggle scratchpad (tag 0) visibility."
  []
  (act "toggle-scratchpad" "Toggle scratchpad" []
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)]
        (if ((o :tags) 0)
          (put (o :tags) 0 nil)
          (put (o :tags) 0 true)))))))

(defn send-to-scratchpad
  "Action: send the focused window to the scratchpad."
  []
  (act "send-to-scratchpad" "Send to scratchpad" []
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        (put w :tag 0)
        (window/set-float w true))))))

# --- Layout ---

(defn adjust-ratio
  "Action: adjust the layout split ratio by delta."
  [delta]
  (act "adjust-ratio" "Adjust ratio" [delta]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows :tag-layouts tag-layouts} ctx)
      (when-let [o (seat :focused-output)]
        (def params (o :layout-params))
        (case (o :layout)
          :scroll (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
          :dwindle (when-let [w (seat :focused)
                             visible (output/visible o windows)
                             tiled (filter |(not (or ($ :float) ($ :fullscreen))) visible)
                             ti (index-of w tiled)]
                     (when (< ti (- (length tiled) 1))
                       (def ratios (or (params :dwindle-ratios) @{}))
                       (def current (or (get ratios ti) (params :dwindle-ratio)))
                       (put ratios ti (max 0.1 (min 0.9 (+ current delta))))
                       (put params :dwindle-ratios ratios)))
          (put params :main-ratio (max 0.1 (min 0.9 (+ (params :main-ratio) delta)))))
        (tag-layout/save o tag-layouts))))))

(defn adjust-main-count
  "Action: adjust the main window count by delta."
  [delta]
  (act "adjust-main-count" "Adjust main count" [delta]
    (fn [] (fn [ctx]
      (def {:seat seat :tag-layouts tag-layouts} ctx)
      (when-let [o (seat :focused-output)]
        (def params (o :layout-params))
        (put params :main-count (max 1 (+ (params :main-count) delta)))
        (tag-layout/save o tag-layouts))))))

(defn cycle-layout
  "Action: cycle to the next/prev layout."
  [dir]
  (act "cycle-layout" "Cycle layout" [dir]
    (fn [] (fn [ctx]
      (def {:seat seat :config config :tag-layouts tag-layouts} ctx)
      (when-let [o (seat :focused-output)]
        (def layouts (config :layouts))
        (def current (o :layout))
        (def i (or (index-of current layouts) 0))
        (def next-i (case dir
                      :next (% (+ i 1) (length layouts))
                      :prev (% (+ (- i 1) (length layouts)) (length layouts))))
        (put o :layout (get layouts next-i))
        (tag-layout/save o tag-layouts))))))

(defn set-layout
  "Action: set the layout on the focused output."
  [lo]
  (act "set-layout" "Set layout" [lo]
    (fn [] (fn [ctx]
      (def {:seat seat :tag-layouts tag-layouts} ctx)
      (when-let [o (seat :focused-output)]
        (put o :layout lo)
        (tag-layout/save o tag-layouts))))))

(defn adjust-column-width
  "Action: adjust the default column width by delta."
  [delta]
  (act "adjust-column-width" "Adjust column width" [delta]
    (fn [] (fn [ctx]
      (def {:seat seat :tag-layouts tag-layouts} ctx)
      (when-let [o (seat :focused-output)]
        (def params (o :layout-params))
        (put params :column-width (max 0.1 (min 1.0 (+ (params :column-width) delta))))
        (tag-layout/save o tag-layouts))))))

(defn resize-column
  "Action: resize the focused scroll column by delta."
  [delta]
  (act "resize-column" "Resize column" [delta]
    (fn [] (fn [ctx]
      (when-let [col (focused-column ctx)]
        (def current (or ((first col) :col-width)
                         (get-in ((ctx :seat) :focused-output) [:layout-params :column-width] 0.5)))
        (def new-width (max 0.1 (min 1.0 (+ current delta))))
        (each win col (put win :col-width new-width)))))))

(defn resize-window
  "Action: resize the focused window's weight by delta."
  [delta]
  (act "resize-window" "Resize window" [delta]
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)
                 col (focused-column ctx)]
        (when (> (length col) 1)
          (def current (or (w :col-weight) 1.0))
          (put w :col-weight (max 0.1 (+ current delta)))))))))

(defn preset-column-width
  "Action: cycle the focused column through width presets."
  []
  (act "preset-column-width" "Cycle column width" []
    (fn [] (fn [ctx]
      (when-let [col (focused-column ctx)]
        (def presets ((ctx :config) :column-presets))
        (when (and presets (> (length presets) 0))
          (def current (or ((first col) :col-width)
                           (get-in ((ctx :seat) :focused-output) [:layout-params :column-width] 0.5)))
          (def next-width
            (or (find |(> $ (+ current 0.01)) (sorted presets))
                (first (sorted presets))))
          (each win col (put win :col-width next-width))))))))

(defn equalize-column
  "Action: reset all row weights in the focused column."
  []
  (act "equalize-column" "Equalize column" []
    (fn [] (fn [ctx]
      (when-let [col (focused-column ctx)]
        (each win col (put win :col-weight nil)))))))

(defn consume-column
  "Action: merge the focused window into an adjacent column."
  [dir]
  (act "consume-column" "Consume column" [dir]
    (fn [] (fn [ctx]
      (def {:seat seat :windows windows} ctx)
      (when-let [o (seat :focused-output)
                 w (seat :focused)
                 ctx-fn (get layout/context-fns (o :layout))]
        (when-let [sctx (ctx-fn o windows w (seat :focus-prev))]
          (def {:cols cols :num-cols num-cols :focused-col my-col} sctx)
          (def target-ci (case dir :left (- my-col 1) :right (+ my-col 1)))
          (when (and (>= target-ci 0) (< target-ci num-cols) (not= target-ci my-col))
            (put w :column ((first (get cols target-ci)) :column)))))))))

(defn expel-column
  "Action: expel the focused window into a new column."
  []
  (act "expel-column" "Expel column" []
    (fn [] (fn [ctx]
      (def {:seat seat :windows windows} ctx)
      (when-let [o (seat :focused-output)
                 w (seat :focused)
                 ctx-fn (get layout/context-fns (o :layout))]
        (when-let [sctx (ctx-fn o windows w (seat :focus-prev))]
          (def {:cols cols :focused-col my-col :windows tiled} sctx)
          (when (> (length (get cols my-col)) 1)
            (var max-col -1)
            (each win tiled (set max-col (max max-col (or (win :column) 0))))
            (put w :column (+ max-col 1)))))))))

# --- Input ---

(defn pointer-move
  "Action: start a pointer move operation."
  []
  (act "pointer-move" "Pointer move" []
    (fn [] (fn [ctx]
      (def {:seat seat :render-order render-order :config config} ctx)
      (when-let [w (seat :pointer-target)]
        (seat/pointer-move seat w outputs render-order config))))))

(defn pointer-resize
  "Action: start a pointer resize operation."
  []
  (act "pointer-resize" "Pointer resize" []
    (fn [] (fn [ctx]
      (def {:seat seat :render-order render-order :config config} ctx)
      (when-let [w (seat :pointer-target)]
        (seat/pointer-resize seat w {:bottom true :right true} outputs render-order config))))))

(defn passthrough
  "Action: toggle keybinding passthrough."
  []
  (act "passthrough" "Passthrough" []
    (fn [] (fn [ctx]
      (def {:seat seat :binding binding} ctx)
      (put binding :passthrough (not (binding :passthrough)))
      (def request (if (binding :passthrough) :disable :enable))
      (each other (seat :xkb-bindings)
        (unless (= other binding) (request (other :obj))))
      (each other (seat :pointer-bindings)
        (unless (= other binding) (request (other :obj))))))))

# --- Session ---

(defn restart
  "Action: restart tidepool (exit code 42)."
  []
  (act "restart" "Restart" []
    (fn [] (fn [ctx]
      (os/exit 42)))))

(defn exit
  "Action: exit tidepool."
  []
  (act "exit" "Exit" []
    (fn [] (fn [ctx]
      (:stop ((ctx :registry) "river_window_manager_v1"))))))

# --- Signals ---

(var emit-signal-fn nil)

(defn signal
  "Action: emit a named signal to IPC watchers."
  [parsed]
  (def [name args] parsed)
  (act "signal" "Emit signal" [name ;args]
    (fn [] (fn [ctx]
      (when emit-signal-fn
        (emit-signal-fn name (if (> (length args) 0) args)))))))

# --- Action registry for IPC dispatch ---

(def registry
  "Registry of action constructors for IPC dispatch."
  @{"spawn" @{:create spawn :parse |[(string ;$)]}
    "close" @{:create close}
    "zoom" @{:create zoom}
    "focus" @{:create focus :parse |(keyword ($ 0))}
    "swap" @{:create swap :parse |(keyword ($ 0))}
    "focus-output" @{:create focus-output :parse |(keyword ($ 0))}
    "focus-last" @{:create focus-last}
    "send-to-output" @{:create send-to-output}
    "float" @{:create float}
    "fullscreen" @{:create fullscreen}
    "set-tag" @{:create set-tag :parse |(scan-number ($ 0))}
    "focus-tag" @{:create focus-tag :parse |(scan-number ($ 0))}
    "toggle-tag" @{:create toggle-tag :parse |(scan-number ($ 0))}
    "focus-all-tags" @{:create focus-all-tags}
    "toggle-scratchpad" @{:create toggle-scratchpad}
    "send-to-scratchpad" @{:create send-to-scratchpad}
    "adjust-ratio" @{:create adjust-ratio :parse |(scan-number ($ 0))}
    "adjust-main-count" @{:create adjust-main-count :parse |(scan-number ($ 0))}
    "cycle-layout" @{:create cycle-layout :parse |(keyword ($ 0))}
    "set-layout" @{:create set-layout :parse |(keyword ($ 0))}
    "adjust-column-width" @{:create adjust-column-width :parse |(scan-number ($ 0))}
    "resize-column" @{:create resize-column :parse |(scan-number ($ 0))}
    "resize-window" @{:create resize-window :parse |(scan-number ($ 0))}
    "preset-column-width" @{:create preset-column-width}
    "equalize-column" @{:create equalize-column}
    "consume-column" @{:create consume-column :parse |(keyword ($ 0))}
    "expel-column" @{:create expel-column}
    "pointer-move" @{:create pointer-move}
    "pointer-resize" @{:create pointer-resize}
    "passthrough" @{:create passthrough}
    "restart" @{:create restart}
    "exit" @{:create exit}
    "signal" @{:create signal :parse |(do (def name ($ 0)) (def rest (slice $ 1)) [name rest])}})
