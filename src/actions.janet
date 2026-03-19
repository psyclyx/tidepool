(import ./state)
(import ./window)
(import ./output)
(import ./seat)
(import ./layout)
(import ./layout/scroll)

(defn- clamp [x lo hi] (min hi (max lo x)))
(defn- wrap [x n] (% (+ (% x n) n) n))

# Forward declaration — set by ipc.janet to avoid circular import
(var emit-signal-fn nil)

(defn- output/primary-tag [o]
  (min-of (keys (o :tags))))

# --- Navigation trail ---

(defn- nav-trail/push
  "Push current focus state onto the nav trail.
  Truncates forward history if cursor is mid-trail."
  [seat]
  (def trail state/nav-trail)
  (def entries (trail :entries))
  (def cursor (trail :cursor))
  (when-let [w (seat :focused)]
    (def entry @{:window w :tag (w :tag)})
    # If mid-trail, truncate forward entries
    (when (and cursor (< cursor (- (length entries) 1)))
      (array/remove entries (+ cursor 1) (- (length entries) cursor 1)))
    # Push and cap
    (array/push entries entry)
    (when (> (length entries) (trail :capacity))
      (array/remove entries 0))
    (put trail :cursor nil)))

(defn- nav-trail/try-push
  "Push to trail if the navigation crosses a tag or output boundary."
  [ctx target]
  (def {:seat seat :outputs outputs} ctx)
  (when-let [current (seat :focused)]
    (when (not= current target)
      (def cur-output (window/tag-output current outputs))
      (def tgt-output (window/tag-output target outputs))
      (when (or (not= (current :tag) (target :tag))
                (not= cur-output tgt-output))
        (nav-trail/push seat)))))

(defn tag-layout/save
  "Persist the current layout for the output's primary tag."
  [o tag-layouts]
  (when-let [tag (output/primary-tag o)]
    (put tag-layouts tag
         @{:layout (o :layout)
           :params (state/clone-layout-params (o :layout-params))})))

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
  "Find the navigation target window for a seat in the given direction.
  For directional navigation, tries tiled-only layout nav first, then
  falls back to geometry over all visible (including floats)."
  [ctx dir]
  (def {:seat seat :outputs outputs :windows windows :config config} ctx)
  (when-let [w (seat :focused)
             o (window/tag-output w outputs)
             visible (output/visible o windows)
             i (index-of w visible)]
    (case dir
      :next (get visible (+ i 1) (first visible))
      :prev (get visible (- i 1) (last visible))
      (do
        # Try tiled-only layout navigation first
        (def tiled (filter |(not (or ($ :float) ($ :fullscreen))) visible))
        (def ti (index-of w tiled))
        (def tiled-result
          (when ti
            (def lo (o :layout))
            (def ctx-fn (get layout/context-fns lo))
            (def nav-ctx (when ctx-fn (ctx-fn o windows w (seat :focus-prev))))
            (def target-i
              (if-let [nav-fn (get layout/navigate-fns lo)]
                (nav-fn (length tiled) (get-in o [:layout-params :main-count] 1) ti dir
                  (or nav-ctx {:output o :windows tiled :focused w}))
                (let [layout-fn (get layout/layout-fns lo (layout/layout-fns :master-stack))
                      results (layout-fn (output/usable-area o) tiled
                                (o :layout-params) config w)]
                  (layout/navigate-by-geometry results ti dir))))
            # Use the nav context's window list for lookup when available,
            # since layout navigators return indices into their own window subset
            # (e.g. scroll returns indices into active-row windows, not all tiled).
            (def nav-windows (if nav-ctx (nav-ctx :windows) tiled))
            (when target-i (get nav-windows target-i))))
        (or tiled-result
            # Fall back to geometry nav over all visible (includes floats)
            (let [candidates (filter |(not (or ($ :fullscreen) ($ :layout-hidden))) visible)
                  results (seq [c :in candidates]
                            @{:x (or (c :x) 0) :y (or (c :y) 0)
                              :w (or (c :w) 1) :h (or (c :h) 1)
                              :window c})
                  fi (index-of w candidates)]
              (when fi
                (when-let [ri (layout/navigate-by-geometry results fi dir)]
                  (get candidates ri)))))))))

(defn- resolve-target
  "Resolve a target window from a resolver spec.
  Specs: keyword direction (:left, :right, :last, etc.) or
  tuple resolver ([:mark name], [:wid id])."
  [ctx spec]
  (cond
    (= spec :last)
    (let [prev ((ctx :seat) :focus-prev)]
      (when (and prev (not (prev :closed)) (not (prev :closing)))
        prev))

    (keyword? spec)
    (target ctx spec)

    (and (indexed? spec) (= (first spec) :mark))
    (let [w (get state/marks (get spec 1))]
      (when (and w (not (w :closed)) (not (w :closing)))
        w))

    (and (indexed? spec) (= (first spec) :wid))
    (find |(= ($ :wid) (get spec 1))
          (filter |(not (or ($ :closed) ($ :closing)))
                  (ctx :windows)))))

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
  "Action: swap the focused window with master position."
  []
  (act "zoom" "Zoom to master" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows
            :render-order render-order :config config} ctx)
      (when-let [focused (seat :focused)
                 o (window/tag-output focused outputs)
                 visible (output/visible o windows)
                 t (if (= focused (first visible)) (get visible 1) focused)
                 ti (index-of t windows)
                 mi (index-of (first visible) windows)]
        (put windows ti (first visible))
        (put windows mi t)
        (seat/focus seat t outputs render-order config))))))

(defn focus
  "Action: focus a target window. Accepts direction keywords (:left, :right,
  :next, :prev, :last) or resolver tuples ([:mark name], [:wid id]).
  For directional resolvers, crosses outputs if no target found."
  [resolver]
  (act "focus" "Focus" [resolver]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows
            :render-order render-order :config config} ctx)
      (if-let [t (resolve-target ctx resolver)]
        # Target found -- ensure its tag is visible, switch output if needed
        (do
          (nav-trail/try-push ctx t)
          (def to (window/tag-output t outputs))
          (if to
            (do
              (when (not= to (seat :focused-output))
                (seat/focus-output seat to))
              (unless ((to :tags) (t :tag))
                (put to :tags @{(t :tag) true})))
            # Tag not visible anywhere -- show it on the focused output
            (when-let [fo (seat :focused-output)]
              (put fo :tags @{(t :tag) true})))
          (seat/focus seat t outputs render-order config))
        # No target -- for directional resolvers, try scroll row boundary, then cross-output
        (when (keyword? resolver)
          (when-let [current (or (when-let [w (seat :focused)] (window/tag-output w outputs))
                                 (seat :focused-output))]
            # Try scroll row boundary crossing for up/down
            (if (and (= (current :layout) :scroll)
                     (find |(= $ resolver) [:up :down])
                     (when-let [w (seat :focused)
                                ctx-fn (get layout/context-fns :scroll)
                                sctx (ctx-fn current windows w (seat :focus-prev))
                                info (scroll/row-boundary-info sctx resolver (sctx :all-tiled))]
                       (def params (current :layout-params))
                       (scroll/switch-to-row params (or (params :active-row) 0) (info :target-row))
                       (when-let [landing (first (info :windows))]
                         (seat/focus seat landing outputs render-order config))
                       true))
              nil
              (if-let [adjacent (find-adjacent-output current outputs resolver)]
                (do (seat/focus-output seat adjacent)
                    (seat/focus seat nil outputs render-order config))
                # Nothing focused and no adjacent output — pick top visible window
                (unless (seat :focused)
                  (when-let [visible (output/visible current windows)
                             top (last visible)]
                    (seat/focus seat top outputs render-order config))))))))))))


(defn swap
  "Action: swap the focused window with a target. Accepts direction keywords
  or resolver tuples ([:mark name], [:wid id]).
  When the focused window is floating and the resolver is a direction keyword,
  nudges the float by :float-step pixels instead of swapping."
  [resolver]
  (act "swap" "Swap" [resolver]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows :config config} ctx)
      (when-let [w (seat :focused)]
        # Floating + directional: nudge instead of swap
        (if (and (w :float) (keyword? resolver)
                 (find |(= $ resolver) [:left :right :up :down]))
          (when (and (w :x) (w :y))
            (def step (or (config :float-step) 20))
            (def [dx dy] (case resolver
                           :left [(- step) 0]
                           :right [step 0]
                           :up [0 (- step)]
                           :down [0 step]))
            (window/set-position w (+ (w :x) dx) (+ (w :y) dy))
            (window/update-tag w outputs))
          # Tiled: swap positions in layout
          (if-let [t (resolve-target ctx resolver)
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
            (when (keyword? resolver)
              (when-let [current (window/tag-output w outputs)]
                (if (and (= (current :layout) :scroll)
                         (find |(= $ resolver) [:up :down])
                         (when-let [ctx-fn (get layout/context-fns :scroll)
                                    sctx (ctx-fn current windows w (seat :focus-prev))
                                    info (scroll/swap-boundary-info sctx resolver (sctx :all-tiled))]
                           (put w :row (info :target-row))
                           (put w :column nil)
                           (when (info :new)
                             (def params (current :layout-params))
                             (scroll/switch-to-row params (or (params :active-row) 0) (info :target-row)))
                           true))
                  nil
                  (when-let [adjacent (find-adjacent-output current outputs resolver)]
                    (put w :tag (or (min-of (keys (adjacent :tags))) 1))
                    (window/clear-layout-placement w)
                    (seat/focus-output seat adjacent))))))))))))

(defn focus-output
  "Action: focus the next or adjacent output."
  [&opt dir]
  (act "focus-output" "Focus output" [(or dir :next)]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (nav-trail/push seat)
      (if dir
        (when-let [current (or (seat :focused-output) (first outputs))
                   adjacent (find-adjacent-output current outputs dir)]
          (seat/focus-output seat adjacent)
          (seat/focus seat nil outputs render-order config))
        (when-let [focused (seat :focused-output)
                   i (index-of focused outputs)
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
                 i (index-of current outputs)
                 t (or (get outputs (+ i 1)) (first outputs))]
        (put w :tag (or (min-of (keys (t :tags))) 1))
        (window/clear-layout-placement w))))))

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
        (when (and (= (w :tag) 0) (not= tag 0) (w :float))
          (window/set-float w false))
        (put w :tag tag))))))

(defn focus-tag
  "Action: show only the given tag on the focused output.
  If the tag is already visible on another output, focus that output instead."
  [tag]
  (act "focus-tag" "Focus tag" [tag]
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)]
        # Check if tag is already visible on another output
        (def other (find |(and (not= $ o) (($ :tags) tag)) (ctx :outputs)))
        (if other
          # Tag is visible elsewhere — just move focus to that output
          (do
            (nav-trail/push (ctx :seat))
            (seat/focus-output (ctx :seat) other))
          # Tag not visible — switch this output to it
          (do
            (def current-tag (output/primary-tag o))
            (unless (= current-tag tag)
              (nav-trail/push (ctx :seat)))
            (put o :tags @{tag true}))))))))

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


# --- Summon ---

(defn summon
  "Action: bring a target window to the current tag and focus it.
  Accepts resolver tuples ([:mark name], [:wid id]) or direction keywords."
  [resolver]
  (act "summon" "Summon" [resolver]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (when-let [t (resolve-target ctx resolver)
                 o (seat :focused-output)]
        (def target-tag (or (output/primary-tag o) 1))
        (unless (= (t :tag) target-tag)
          (nav-trail/push seat)
          (put t :tag target-tag)
          (window/clear-layout-placement t))
        (seat/focus seat t outputs render-order config))))))

(defn send-to
  "Action: send the focused window to the resolved target, inserting
  it right after the target in the window list (same tag, adjacent position).
  Accepts resolver tuples ([:mark name], [:wid id]) or :last."
  [resolver]
  (act "send-to" "Send to" [resolver]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :windows windows} ctx)
      (when-let [w (seat :focused)
                 t (resolve-target ctx resolver)
                 wi (index-of w windows)
                 ti (index-of t windows)]
        (put w :tag (t :tag))
        (window/clear-layout-placement w)
        # Remove w from current position and insert after t
        (array/remove windows wi)
        (def new-ti (index-of t windows))
        (array/insert windows (+ new-ti 1) w))))))

# --- Marks ---

(defn mark-set
  "Action: label the focused window with a mark name."
  [name]
  (act "mark-set" "Set mark" [name]
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        # Clear any existing mark on this window
        (when (w :mark)
          (put state/marks (w :mark) nil))
        # Clear any existing window with this mark name
        (when-let [prev (get state/marks name)]
          (put prev :mark nil))
        (put state/marks name w)
        (put w :mark name))))))

(defn mark-clear
  "Action: remove a mark by name."
  [name]
  (act "mark-clear" "Clear mark" [name]
    (fn [] (fn [ctx]
      (when-let [w (get state/marks name)]
        (put w :mark nil))
      (put state/marks name nil)))))

# --- Navigation trail actions ---

(defn nav-back
  "Action: navigate backward through the nav trail."
  []
  (act "nav-back" "Nav back" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (def trail state/nav-trail)
      (def entries (trail :entries))
      (when (> (length entries) 0)
        (def cursor (or (trail :cursor) (length entries)))
        # Walk backward, skipping closed windows
        (var i (- cursor 1))
        (while (>= i 0)
          (def entry (entries i))
          (def w (entry :window))
          (if (or (w :closed) (w :closing))
            (-- i)
            (do
              # Push current position if this is the first back step
              (when (nil? (trail :cursor))
                (nav-trail/push seat))
              (put trail :cursor i)
              (def to (window/tag-output w outputs))
              (if to
                (do
                  (when (not= to (seat :focused-output))
                    (seat/focus-output seat to))
                  (unless ((to :tags) (w :tag))
                    (put to :tags @{(w :tag) true})))
                (when-let [fo (seat :focused-output)]
                  (put fo :tags @{(w :tag) true})))
              (seat/focus seat w outputs render-order config)
              (when emit-signal-fn (emit-signal-fn "nav-back"))
              (break)))))))))

(defn nav-forward
  "Action: navigate forward through the nav trail."
  []
  (act "nav-forward" "Nav forward" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (def trail state/nav-trail)
      (def entries (trail :entries))
      (when-let [cursor (trail :cursor)]
        # Walk forward, skipping closed windows
        (var i (+ cursor 1))
        (while (< i (length entries))
          (def entry (entries i))
          (def w (entry :window))
          (if (or (w :closed) (w :closing))
            (++ i)
            (do
              (put trail :cursor (if (= i (- (length entries) 1)) nil i))
              (def to (window/tag-output w outputs))
              (if to
                (do
                  (when (not= to (seat :focused-output))
                    (seat/focus-output seat to))
                  (unless ((to :tags) (w :tag))
                    (put to :tags @{(w :tag) true})))
                (when-let [fo (seat :focused-output)]
                  (put fo :tags @{(w :tag) true})))
              (seat/focus seat w outputs render-order config)
              (when emit-signal-fn (emit-signal-fn "nav-forward"))
              (break)))))))))

# --- Scroll home ---

(defn scroll-home-set
  "Action: save the focused window as the scroll home position."
  []
  (act "scroll-home-set" "Set scroll home" []
    (fn [] (fn [ctx]
      (when-let [o ((ctx :seat) :focused-output)
                 w ((ctx :seat) :focused)]
        (put (o :layout-params) :scroll-home-win w))))))

(defn scroll-home
  "Action: focus the scroll home window, auto-scrolling to reveal it."
  []
  (act "scroll-home" "Scroll home" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (when-let [o (seat :focused-output)
                 w (get-in o [:layout-params :scroll-home-win])]
        (if (or (w :closed) (w :closing))
          (put (o :layout-params) :scroll-home-win nil)
          (seat/focus seat w outputs render-order config)))))))

# --- Floating ---

(defn float-move
  "Action: nudge the focused floating window in a direction."
  [dir]
  (act "float-move" "Move float" [dir]
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :config config} ctx)
      (when-let [w (seat :focused)]
        (when (and (w :float) (w :x) (w :y))
          (def step (or (config :float-step) 20))
          (def [dx dy] (case dir
                         :left [(- step) 0]
                         :right [step 0]
                         :up [0 (- step)]
                         :down [0 step]))
          (window/set-position w (+ (w :x) dx) (+ (w :y) dy))
          (window/update-tag w outputs)))))))

(defn float-resize
  "Action: resize the focused floating window. Takes :width or :height
  and a signed pixel delta (positive grows, negative shrinks).
  Resizes symmetrically around center."
  [axis delta]
  (act "float-resize" "Resize float" [axis delta]
    (fn [] (fn [ctx]
      (when-let [w ((ctx :seat) :focused)]
        (when (and (w :float) (w :w) (w :h) (w :x) (w :y))
          (case axis
            :width (let [nw (max 1 (+ (w :w) delta))]
                     (window/set-position w (- (w :x) (div delta 2)) (w :y))
                     (window/propose-dimensions w nw (w :h) (ctx :config)))
            :height (let [nh (max 1 (+ (w :h) delta))]
                      (window/set-position w (w :x) (- (w :y) (div delta 2)))
                      (window/propose-dimensions w (w :w) nh (ctx :config))))))))))

(defn float-center
  "Action: center the focused floating window on its output."
  []
  (act "float-center" "Center float" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs} ctx)
      (when-let [w (seat :focused)]
        (when (and (w :float) (w :w) (w :h))
          (when-let [o (or (window/tag-output w outputs) (seat :focused-output))]
            (def area (output/usable-area o))
            (window/set-position w
              (+ (area :x) (div (- (area :w) (w :w)) 2))
              (+ (area :y) (div (- (area :h) (w :h)) 2))))))))))

# --- Input ---

(defn pointer-move
  "Action: start a pointer move operation."
  []
  (act "pointer-move" "Pointer move" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
      (when-let [w (seat :pointer-target)]
        (seat/pointer-move seat w outputs render-order config))))))

(defn pointer-resize
  "Action: start a pointer resize operation."
  []
  (act "pointer-resize" "Pointer resize" []
    (fn [] (fn [ctx]
      (def {:seat seat :outputs outputs :render-order render-order :config config} ctx)
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

(defn signal
  "Action: emit a named signal to IPC watchers."
  [parsed]
  (def [name args] parsed)
  (def args (or args @[]))
  (act "signal" "Emit signal" [name ;args]
    (fn [] (fn [ctx]
      (when emit-signal-fn
        (emit-signal-fn name (if (> (length args) 0) args)))))))

# --- Action registry for IPC dispatch ---

(defn- parse-resolver
  "Parse IPC args into a resolver spec.
  'left' -> :left, 'mark a' -> [:mark \"a\"], 'wid 5' -> [:wid 5]"
  [args]
  (case (args 0)
    "mark" [:mark (args 1)]
    "wid" [:wid (scan-number (args 1))]
    (keyword (args 0))))

# Arg spec types for interactive dispatch:
#   "resolver"              — direction keyword or mark/wid tuple
#   ["choice" & options]    — pick from list
#   ["number" prompt]       — enter a number
#   ["string" prompt]       — enter a string

(def registry
  "Registry of action constructors for IPC dispatch."
  @{"spawn" @{:create spawn :parse |[(string ;$)]
              :desc "Spawn command" :spec [["string" "Command"]]}
    "close" @{:create close :desc "Close window"}
    "zoom" @{:create zoom :desc "Zoom to master"}
    "focus" @{:create focus :parse parse-resolver
              :desc "Focus window" :spec ["resolver"]}
    "swap" @{:create swap :parse parse-resolver
             :desc "Swap/move window" :spec ["resolver"]}
    "summon" @{:create summon :parse parse-resolver
               :desc "Summon window here" :spec ["resolver"]}
    "send-to" @{:create send-to :parse parse-resolver
                :desc "Send focused to target's tag" :spec ["resolver"]}
    "focus-output" @{:create focus-output :parse |(keyword ($ 0))
                     :desc "Focus output" :spec [["choice" "left" "right"]]}
    "focus-last" @{:create |(focus :last) :desc "Focus previous window"}
    "send-to-output" @{:create send-to-output :desc "Send to next output"}
    "float" @{:create float :desc "Toggle floating"}
    "fullscreen" @{:create fullscreen :desc "Toggle fullscreen"}
    "set-tag" @{:create set-tag :parse |(scan-number ($ 0))
                :desc "Move window to tag" :spec [["choice" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10"]]}
    "focus-tag" @{:create focus-tag :parse |(scan-number ($ 0))
                  :desc "Focus tag" :spec [["choice" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10"]]}
    "toggle-tag" @{:create toggle-tag :parse |(scan-number ($ 0))
                   :desc "Toggle tag visibility" :spec [["choice" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10"]]}
    "focus-all-tags" @{:create focus-all-tags :desc "Show all tags"}
    "toggle-scratchpad" @{:create toggle-scratchpad :desc "Toggle scratchpad"}
    "send-to-scratchpad" @{:create send-to-scratchpad :desc "Send to scratchpad"}
    "adjust-ratio" @{:create adjust-ratio :parse |(scan-number ($ 0))
                     :desc "Adjust split ratio" :spec [["choice" "-0.05" "0.05" "-0.1" "0.1"]]}
    "adjust-main-count" @{:create adjust-main-count :parse |(scan-number ($ 0))
                          :desc "Adjust main count" :spec [["choice" "-1" "1"]]}
    "cycle-layout" @{:create cycle-layout :parse |(keyword ($ 0))
                     :desc "Cycle layout" :spec [["choice" "next" "prev"]]}
    "set-layout" @{:create set-layout :parse |(keyword ($ 0))
                   :desc "Set layout" :spec [["choice" "master-stack" "grid" "dwindle" "scroll" "tabbed"]]}
    "adjust-column-width" @{:create adjust-column-width :parse |(scan-number ($ 0))
                            :desc "Adjust column width" :spec [["choice" "-0.05" "0.05" "-0.1" "0.1"]]}
    "resize-column" @{:create resize-column :parse |(scan-number ($ 0))
                      :desc "Resize column" :spec [["choice" "-0.1" "0.1" "-0.2" "0.2"]]}
    "resize-window" @{:create resize-window :parse |(scan-number ($ 0))
                      :desc "Resize window weight" :spec [["choice" "-0.1" "0.1" "-0.2" "0.2"]]}
    "preset-column-width" @{:create preset-column-width :desc "Cycle column width presets"}
    "equalize-column" @{:create equalize-column :desc "Equalize column"}
    "consume-column" @{:create consume-column :parse |(keyword ($ 0))
                       :desc "Consume column" :spec [["choice" "left" "right"]]}
    "expel-column" @{:create expel-column :desc "Expel to new column"}
    "mark-set" @{:create mark-set :parse |($ 0)
                 :desc "Set mark on window" :spec [["string" "Mark name"]]}
    "mark-clear" @{:create mark-clear :parse |($ 0)
                   :desc "Clear mark" :spec [["string" "Mark name"]]}
    "float-move" @{:create float-move :parse |(keyword ($ 0))
                   :desc "Move floating window" :spec [["choice" "left" "right" "up" "down"]]}
    "float-resize" @{:create float-resize :parse |(do [(keyword ($ 0)) (scan-number ($ 1))])
                     :desc "Resize floating window" :spec [["choice" "width" "height"] ["number" "Delta (px)"]]}
    "float-center" @{:create float-center :desc "Center floating window"}
    "nav-back" @{:create nav-back :desc "Navigate back"}
    "nav-forward" @{:create nav-forward :desc "Navigate forward"}
    "scroll-home-set" @{:create scroll-home-set :desc "Set scroll home"}
    "scroll-home" @{:create scroll-home :desc "Jump to scroll home"}
    "pointer-move" @{:create pointer-move :desc "Pointer move"}
    "pointer-resize" @{:create pointer-resize :desc "Pointer resize"}
    "passthrough" @{:create passthrough :desc "Toggle passthrough"}
    "restart" @{:create restart :desc "Restart tidepool"}
    "exit" @{:create exit :desc "Exit tidepool"}
    "signal" @{:create signal :parse |(do (def name ($ 0)) (def rest (slice $ 1)) [name rest])
               :desc "Emit signal" :spec [["string" "Signal name"]]}})
