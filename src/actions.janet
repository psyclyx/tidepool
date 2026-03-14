(import ./state)
(import ./window)
(import ./output)
(import ./seat)
(import ./pool)
(import ./pool/navigate :as pool-navigate)
(import ./pool/actions :as pool-actions)

# --- Action tagging ---

(defn- act [name desc args f]
  "Wrap an action closure with metadata for introspection."
  @{:fn f :name name :desc desc :args args})

# --- Helpers ---

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

(defn- get-tag-pool
  "Get the active tag pool for the focused output."
  [seat]
  (when-let [o (seat :focused-output)]
    (output/active-tag-pool o)))

# --- Window management ---

(defn spawn
  "Action: spawn a command."
  [command]
  (act "spawn" "Spawn a command" [command]
    (fn [seat binding]
      (ev/spawn (os/proc-wait (os/spawn command :p))))))

(defn close
  "Action: close the focused window."
  []
  (act "close" "Close focused window" []
    (fn [seat binding]
      (when-let [w (seat :focused)]
        (:close (w :obj))))))

(defn zoom
  "Action: move focused window to first position in its parent."
  []
  (act "zoom" "Zoom to first position" []
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/zoom nil focused)))))

(defn float
  "Action: toggle floating on the focused window."
  []
  (act "float" "Toggle float" []
    (fn [seat binding]
      (when-let [w (seat :focused)
                 o (seat :focused-output)]
        (if (w :float)
          (do
            (window/set-float w false)
            (when-let [tag-pool (output/active-tag-pool o)]
              (if (= (tag-pool :mode) :scroll)
                (let [row (get (tag-pool :children) (or (tag-pool :active-row) 0))]
                  (when row (pool/append-child row w)))
                (pool/append-child tag-pool w))))
          (do
            (when-let [parent (w :parent)]
              (when (parent :children)
                (pool-actions/remove-window nil w)))
            (window/set-float w true)))))))

(defn fullscreen
  "Action: toggle fullscreen on the focused window."
  []
  (act "fullscreen" "Toggle fullscreen" []
    (fn [seat binding]
      (when-let [w (seat :focused)]
        (if (w :fullscreen)
          (window/set-fullscreen w nil)
          (window/set-fullscreen w (window/tag-output w (state/wm :outputs))))))))

# --- Navigation ---

(defn focus
  "Action: focus in a direction, crossing outputs if needed."
  [dir]
  (act "focus" "Focus window" [dir]
    (fn [seat binding]
      (def outputs (state/wm :outputs))
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (def tag-pool (output/active-tag-pool o))
        (def target (when tag-pool
                      (pool-navigate/navigate tag-pool focused dir)))
        (if target
          (seat/focus seat target (state/wm :render-order) state/config)
          (when-let [adjacent (find-adjacent-output o outputs dir)]
            (seat/focus-output seat adjacent)
            (seat/focus seat nil (state/wm :render-order) state/config)))))))

(defn swap
  "Action: swap the focused window in a direction."
  [dir]
  (act "swap" "Swap window" [dir]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (def tag-pool (output/active-tag-pool o))
        (when tag-pool
          (pool-actions/swap tag-pool focused dir))))))

(defn focus-output
  "Action: focus the next or adjacent output."
  [&opt dir]
  (act "focus-output" "Focus output" [(or dir "next")]
    (fn [seat binding]
      (def outputs (state/wm :outputs))
      (if dir
        (when-let [current (or (seat :focused-output) (first outputs))
                   adjacent (find-adjacent-output current outputs dir)]
          (seat/focus-output seat adjacent)
          (seat/focus seat nil (state/wm :render-order) state/config))
        (when-let [focused (seat :focused-output)
                   i (assert (index-of focused outputs))
                   t (or (get outputs (+ i 1)) (first outputs))]
          (seat/focus-output seat t)
          (seat/focus seat nil (state/wm :render-order) state/config))))))

(defn focus-last
  "Action: focus the previously focused window."
  []
  (act "focus-last" "Focus last window" []
    (fn [seat binding]
      (when-let [prev (seat :focus-prev)]
        (when (and (not (prev :closed))
                   (window/tag-output prev (state/wm :outputs)))
          (seat/focus seat prev (state/wm :render-order) state/config))))))

(defn send-to-output
  "Action: send the focused window to the next output."
  []
  (act "send-to-output" "Send to next output" []
    (fn [seat binding]
      (def outputs (state/wm :outputs))
      (when-let [w (seat :focused)
                 current (seat :focused-output)
                 i (assert (index-of current outputs))
                 target-output (or (get outputs (+ i 1)) (first outputs))]
        (when-let [parent (w :parent)]
          (when (parent :children)
            (pool-actions/remove-window nil w)))
        (when-let [tag-pool (output/active-tag-pool target-output)]
          (if (= (tag-pool :mode) :scroll)
            (let [row (get (tag-pool :children) (or (tag-pool :active-row) 0))]
              (when row (pool/append-child row w)))
            (pool/append-child tag-pool w)))))))

# --- Tag (pool) management ---

(defn focus-tag
  "Action: show only the given tag on the focused output."
  [t]
  (act "focus-tag" "Focus tag" [t]
    (fn [seat binding]
      (when-let [o (seat :focused-output)]
        (pool-actions/focus-pool o t)
        (put o :multi-active nil)))))

(defn set-tag
  "Action: move the focused window to a tag."
  [t]
  (act "set-tag" "Send to tag" [t]
    (fn [seat binding]
      (when-let [w (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/send-to-pool (o :tag-pools) w t)))))

(defn toggle-tag
  "Action: toggle a tag's visibility on the focused output."
  [t]
  (act "toggle-tag" "Toggle tag" [t]
    (fn [seat binding]
      (when-let [o (seat :focused-output)]
        (pool-actions/toggle-pool o t)))))

(defn focus-all-tags
  "Action: show all tags on the focused output."
  []
  (act "focus-all-tags" "Show all tags" []
    (fn [seat binding]
      (when-let [o (seat :focused-output)]
        (def ma @{})
        (eachp [id _] (o :tag-pools)
          (put ma id true))
        (put o :multi-active ma)))))

(defn toggle-scratchpad
  "Action: toggle scratchpad (tag 0) visibility."
  []
  (act "toggle-scratchpad" "Toggle scratchpad" []
    (fn [seat binding]
      (when-let [o (seat :focused-output)]
        (pool-actions/toggle-pool o 0)))))

(defn send-to-scratchpad
  "Action: send the focused window to the scratchpad."
  []
  (act "send-to-scratchpad" "Send to scratchpad" []
    (fn [seat binding]
      (when-let [w (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/send-to-pool (o :tag-pools) w 0)))))

# --- Layout mode ---

(defn cycle-layout
  "Action: cycle the active tag pool's mode."
  [dir]
  (act "cycle-layout" "Cycle tag layout" [dir]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (def root nil)
        (def mode-kw (if (= dir :prev) :prev :next))
        (pool-actions/set-mode root (or focused @{:parent nil}) mode-kw :tag)))))

(defn set-layout
  "Action: set the layout mode on the focused tag pool."
  [mode]
  (act "set-layout" "Set tag layout" [mode]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/set-mode nil (or focused @{:parent nil}) mode :tag)))))

# --- Resize ---

(defn resize
  "Action: context-sensitive resize (ratio, weight, or scroll column width)."
  [delta]
  (act "resize" "Resize" [delta]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/resize nil focused delta)))))

(defn cycle-width
  "Action: cycle the focused column through width presets."
  []
  (act "cycle-width" "Cycle width presets" []
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/resize nil focused :cycle)))))

(defn equalize
  "Action: reset all weights in the focused pool."
  []
  (act "equalize" "Reset weights" []
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/resize nil focused :reset)))))

# --- Consume/Expel ---

(defn consume
  "Action: pull adjacent sibling into focused window's group."
  [dir]
  (act "consume" "Consume neighbor" [dir]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/consume nil focused dir)))))

(defn expel
  "Action: move focused window out of its current pool."
  []
  (act "expel" "Expel from group" []
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/expel nil focused)))))

# --- Group mode ---

(defn cycle-mode
  "Action: cycle the focused window's parent pool mode."
  []
  (act "cycle-mode" "Cycle group mode" []
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/set-mode nil focused :next :parent)))))

(defn set-mode
  "Action: set the mode on the focused window's parent pool."
  [mode]
  (act "set-mode" "Set group mode" [mode]
    (fn [seat binding]
      (when-let [focused (seat :focused)
                 o (seat :focused-output)]
        (pool-actions/set-mode nil focused mode :parent)))))

# --- Input ---

(defn pointer-move
  "Action: start a pointer move operation."
  []
  (act "pointer-move" "Pointer move" []
    (fn [seat binding]
      (when-let [w (seat :pointer-target)]
        (when-let [parent (w :parent)]
          (when (parent :children)
            (when-let [o (seat :focused-output)]
              (pool-actions/remove-window nil w))))
        (seat/pointer-move seat w (state/wm :render-order) state/config)))))

(defn pointer-resize
  "Action: start a pointer resize operation."
  []
  (act "pointer-resize" "Pointer resize" []
    (fn [seat binding]
      (when-let [w (seat :pointer-target)]
        (seat/pointer-resize seat w {:bottom true :right true} (state/wm :render-order) state/config)))))

(defn passthrough
  "Action: toggle keybinding passthrough."
  []
  (act "passthrough" "Toggle passthrough" []
    (fn [seat binding]
      (put binding :passthrough (not (binding :passthrough)))
      (def request (if (binding :passthrough) :disable :enable))
      (each other (seat :xkb-bindings)
        (unless (= other binding) (request (other :obj))))
      (each other (seat :pointer-bindings)
        (unless (= other binding) (request (other :obj)))))))

# --- Recovery ---

(defn reset-layout
  "Action: rebuild tag pools for the focused output, recovering all windows."
  []
  (act "reset-layout" "Reset layout (recover all windows)" []
    (fn [seat binding]
      (when-let [o (seat :focused-output)
                 tag-pools (o :tag-pools)]
        # Collect ALL windows from all tag pools
        (def all-windows @[])
        (eachp [_ tp] tag-pools
          (array/concat all-windows (pool/collect-windows tp)))
        # Also collect any orphaned tiled windows on this output
        (each w (state/wm :windows)
          (when (and (not (w :closed)) (not (w :closing))
                     (nil? (w :parent)) (not (w :float)))
            (array/push all-windows w)))
        # Group windows by their current :tag (or active tag as fallback)
        (def active-tag (or (output/active-tag-id o) 1))
        (def by-tag @{})
        (each w all-windows
          (def t (or (w :tag) active-tag))
          (unless (by-tag t) (put by-tag t @[]))
          (array/push (by-tag t) w)
          (put w :parent nil))
        # Rebuild tag pools from scratch
        (def default-mode (or (state/config :default-layout) :scroll))
        (def presets (state/config :column-presets))
        (def new-pools @{})
        (for i 0 11
          (def wins (or (by-tag i) @[]))
          (put new-pools i
            (if (= default-mode :scroll)
              (pool/make-pool :scroll
                @[(pool/make-pool :stack-v wins)]
                @{:id i :active-row 0 :presets presets})
              (pool/make-pool default-mode wins @{:id i}))))
        (put o :tag-pools new-pools)
        # Unfloat any stuck floating windows on this output's tags
        (each w (state/wm :windows)
          (when (and (w :float) (not (w :closed)) (not (w :closing))
                     (nil? (w :parent)) (by-tag (w :tag)))
            (def t (or (w :tag) active-tag))
            (when-let [tp (get new-pools t)]
              (if (= (tp :mode) :scroll)
                (when-let [row (get (tp :children) 0)]
                  (pool/append-child row w))
                (pool/append-child tp w))
              (window/set-float w false))))))))

# --- Session ---

(defn restart
  "Action: restart tidepool (exit code 42)."
  []
  (act "restart" "Restart tidepool" []
    (fn [seat binding]
      (os/exit 42))))

(defn exit
  "Action: exit tidepool."
  []
  (act "exit" "Exit tidepool" []
    (fn [seat binding]
      (:stop (state/registry "river_window_manager_v1")))))

# --- Registry for IPC dispatch ---

(def registry
  "Map of action name to constructor + arg parser for IPC dispatch."
  @{"spawn" @{:create spawn :parse |(array ;$)}
    "close" @{:create close}
    "zoom" @{:create zoom}
    "float" @{:create float}
    "fullscreen" @{:create fullscreen}
    "focus" @{:create focus :parse |(keyword ($ 0))}
    "swap" @{:create swap :parse |(keyword ($ 0))}
    "focus-output" @{:create focus-output :parse |(if (> (length $) 0) (keyword ($ 0)))}
    "focus-last" @{:create focus-last}
    "send-to-output" @{:create send-to-output}
    "focus-tag" @{:create focus-tag :parse |(scan-number ($ 0))}
    "set-tag" @{:create set-tag :parse |(scan-number ($ 0))}
    "toggle-tag" @{:create toggle-tag :parse |(scan-number ($ 0))}
    "focus-all-tags" @{:create focus-all-tags}
    "toggle-scratchpad" @{:create toggle-scratchpad}
    "send-to-scratchpad" @{:create send-to-scratchpad}
    "cycle-layout" @{:create cycle-layout :parse |(keyword ($ 0))}
    "set-layout" @{:create set-layout :parse |(keyword ($ 0))}
    "resize" @{:create resize :parse |(scan-number ($ 0))}
    "cycle-width" @{:create cycle-width}
    "equalize" @{:create equalize}
    "consume" @{:create consume :parse |(keyword ($ 0))}
    "expel" @{:create expel}
    "cycle-mode" @{:create cycle-mode}
    "set-mode" @{:create set-mode :parse |(keyword ($ 0))}
    "passthrough" @{:create passthrough}
    "reset-layout" @{:create reset-layout}
    "restart" @{:create restart}
    "exit" @{:create exit}})
