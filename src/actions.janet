(import ./state)
(import ./window)
(import ./output)
(import ./seat)
(import ./pool)
(import ./pool/navigate :as pool-navigate)
(import ./pool/actions :as pool-actions)

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
  (fn [seat binding]
    (ev/spawn (os/proc-wait (os/spawn command :p)))))

(defn close
  "Action: close the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (:close (w :obj)))))

(defn zoom
  "Action: move focused window to first position in its parent."
  []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/zoom (o :pool) focused))))

(defn float
  "Action: toggle floating on the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)
               o (seat :focused-output)]
      (if (w :float)
        (do
          # Unfloat: insert back into pool tree
          (window/set-float w false)
          (when-let [tag-pool (output/active-tag-pool o)]
            (if (= (tag-pool :mode) :scroll)
              (let [row (get (tag-pool :children) (or (tag-pool :active-row) 0))]
                (when row (pool/append-child row w)))
              (pool/append-child tag-pool w))))
        (do
          # Float: remove from pool tree
          (when-let [parent (w :parent)]
            (when (parent :children)
              (pool-actions/remove-window (o :pool) w)))
          (window/set-float w true))))))

(defn fullscreen
  "Action: toggle fullscreen on the focused window."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)]
      (if (w :fullscreen)
        (window/set-fullscreen w nil)
        (window/set-fullscreen w (window/tag-output w (state/wm :outputs)))))))

# --- Navigation ---

(defn focus
  "Action: focus in a direction, crossing outputs if needed."
  [dir]
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
          (seat/focus seat nil (state/wm :render-order) state/config))))))

(defn swap
  "Action: swap the focused window in a direction."
  [dir]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (def tag-pool (output/active-tag-pool o))
      (when tag-pool
        (pool-actions/swap tag-pool focused dir)))))

(defn focus-output
  "Action: focus the next or adjacent output."
  [&opt dir]
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
        (seat/focus seat nil (state/wm :render-order) state/config)))))

(defn focus-last
  "Action: focus the previously focused window."
  []
  (fn [seat binding]
    (when-let [prev (seat :focus-prev)]
      (when (and (not (prev :closed))
                 (window/tag-output prev (state/wm :outputs)))
        (seat/focus seat prev (state/wm :render-order) state/config)))))

(defn send-to-output
  "Action: send the focused window to the next output."
  []
  (fn [seat binding]
    (def outputs (state/wm :outputs))
    (when-let [w (seat :focused)
               current (seat :focused-output)
               i (assert (index-of current outputs))
               target-output (or (get outputs (+ i 1)) (first outputs))]
      # Remove from current pool tree
      (when-let [parent (w :parent)]
        (when (parent :children)
          (pool-actions/remove-window (current :pool) w)))
      # Insert into target output's active tag pool
      (when-let [tag-pool (output/active-tag-pool target-output)]
        (if (= (tag-pool :mode) :scroll)
          (let [row (get (tag-pool :children) (or (tag-pool :active-row) 0))]
            (when row (pool/append-child row w)))
          (pool/append-child tag-pool w))))))

# --- Tag (pool) management ---

(defn focus-tag
  "Action: show only the given tag on the focused output."
  [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def root (o :pool))
      (pool-actions/focus-pool root tag)
      (put root :multi-active nil))))

(defn set-tag
  "Action: move the focused window to a tag."
  [tag]
  (fn [seat binding]
    (when-let [w (seat :focused)
               o (seat :focused-output)]
      (def root (o :pool))
      (pool-actions/send-to-pool root w tag))))

(defn toggle-tag
  "Action: toggle a tag's visibility on the focused output."
  [tag]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (pool-actions/toggle-pool (o :pool) tag))))

(defn focus-all-tags
  "Action: show all tags on the focused output."
  []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (def root (o :pool))
      (def ma @{})
      (for i 0 (length (root :children))
        (put ma i true))
      (put root :multi-active ma))))

(defn toggle-scratchpad
  "Action: toggle scratchpad (tag 0) visibility."
  []
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (pool-actions/toggle-pool (o :pool) 0))))

(defn send-to-scratchpad
  "Action: send the focused window to the scratchpad."
  []
  (fn [seat binding]
    (when-let [w (seat :focused)
               o (seat :focused-output)]
      (pool-actions/send-to-pool (o :pool) w 0))))

# --- Layout mode ---

(defn cycle-layout
  "Action: cycle the active tag pool's mode."
  [dir]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (def root (o :pool))
      (def mode-kw (if (= dir :prev) :prev :next))
      (pool-actions/set-mode root (or focused @{:parent nil}) mode-kw :tag))))

(defn set-layout
  "Action: set the layout mode on the focused tag pool."
  [mode]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/set-mode (o :pool) (or focused @{:parent nil}) mode :tag))))

# --- Resize ---

(defn resize
  "Action: context-sensitive resize (ratio, weight, or scroll column width)."
  [delta]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/resize (o :pool) focused delta))))

(defn cycle-width
  "Action: cycle the focused column through width presets."
  []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/resize (o :pool) focused :cycle))))

(defn equalize
  "Action: reset all weights in the focused pool."
  []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/resize (o :pool) focused :reset))))

# --- Consume/Expel ---

(defn consume
  "Action: pull adjacent sibling into focused window's group."
  [dir]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/consume (o :pool) focused dir))))

(defn expel
  "Action: move focused window out of its current pool."
  []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/expel (o :pool) focused))))

# --- Group mode ---

(defn cycle-mode
  "Action: cycle the focused window's parent pool mode."
  []
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/set-mode (o :pool) focused :next :parent))))

(defn set-mode
  "Action: set the mode on the focused window's parent pool."
  [mode]
  (fn [seat binding]
    (when-let [focused (seat :focused)
               o (seat :focused-output)]
      (pool-actions/set-mode (o :pool) focused mode :parent))))

# --- Input ---

(defn pointer-move
  "Action: start a pointer move operation."
  []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      # Remove from pool tree before floating
      (when-let [parent (w :parent)]
        (when (parent :children)
          (when-let [o (seat :focused-output)]
            (pool-actions/remove-window (o :pool) w))))
      (seat/pointer-move seat w (state/wm :render-order) state/config))))

(defn pointer-resize
  "Action: start a pointer resize operation."
  []
  (fn [seat binding]
    (when-let [w (seat :pointer-target)]
      (seat/pointer-resize seat w {:bottom true :right true} (state/wm :render-order) state/config))))

(defn passthrough
  "Action: toggle keybinding passthrough."
  []
  (fn [seat binding]
    (put binding :passthrough (not (binding :passthrough)))
    (def request (if (binding :passthrough) :disable :enable))
    (each other (seat :xkb-bindings)
      (unless (= other binding) (request (other :obj))))
    (each other (seat :pointer-bindings)
      (unless (= other binding) (request (other :obj))))))

# --- Session ---

(defn restart
  "Action: restart tidepool (exit code 42)."
  []
  (fn [seat binding]
    (os/exit 42)))

(defn exit
  "Action: exit tidepool."
  []
  (fn [seat binding]
    (:stop (state/registry "river_window_manager_v1"))))
