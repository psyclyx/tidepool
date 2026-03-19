(import ./state)
(import ./persist)
(import ./actions :as action)
(import ./output)
(import ./layout/scroll)
(import spork/json)

# --- Debug logging ---

(var debug false)

(defn- log [fmt & args]
  (when debug
    (eprintf (string "ipc: " fmt) ;args)))

# --- Per-topic state computation ---

(defn- compute-tags
  "Compute tag state: per-output active tags + occupied tags."
  [outputs windows focused-output]
  (def occupied @{})
  (each w windows
    (unless (or (w :closed) (w :closing))
      (put occupied (w :tag) true)))
  @{:outputs (seq [o :in outputs]
      @{:x (o :x) :y (o :y)
        :name (or (o :name) "")
        :tags (sorted (keys (o :tags)))
        :focused (= o focused-output)})
    :occupied (sorted (keys occupied))})

(defn- compute-viewport
  "Compute viewport context for an output's current layout."
  [o]
  (def params (o :layout-params))
  (when (nil? params) (break nil))
  (def usable (output/usable-area o))
  (def base @{:x (usable :x) :y (usable :y)
              :w (usable :w) :h (usable :h)})
  (when (= (o :layout) :scroll)
    (put base :scroll-offset (or (params :scroll-offset) 0))
    (put base :total-content-w (or (params :total-content-w) 0))
    (when (params :column-widths)
      (put base :column-widths (params :column-widths))))
  base)

(defn- compute-layout
  "Compute layout state: per-output layout name and viewport."
  [outputs focused-output]
  @{:outputs (seq [o :in outputs]
      @{:x (o :x) :y (o :y)
        :name (or (o :name) "")
        :w (or (o :w) 0) :h (or (o :h) 0)
        :layout (string (o :layout))
        :active-row (or (get-in o [:layout-params :active-row]) 0)
        :focused (= o focused-output)
        :viewport (compute-viewport o)})})

(defn- compute-title
  "Compute focused window title."
  [seats]
  (if-let [s (first seats)
           w (s :focused)]
    @{:title (or (w :title) "")
      :app-id (or (w :app-id) "")}
    @{:title "" :app-id ""}))

(defn- compute-windows
  "Compute window state for IPC. Excludes volatile geometry (x/y/w/h) that
  changes every animation frame — consumers use column/row metadata instead."
  [windows seats outputs]
  (def focused (when-let [s (first seats)] (s :focused)))
  (def tag-map @{})
  (each o outputs (eachk tag (o :tags) (put tag-map tag o)))
  (seq [w :in windows :when (not (or (w :closed) (w :closing)))]
    (def o (get tag-map (w :tag)))
    @{:wid (w :wid)
      :app-id (or (w :app-id) "")
      :title (or (w :title) "")
      :tag (w :tag)
      :focused (= w focused)
      :float (if (w :float) true false)
      :fullscreen (if (w :fullscreen) true false)
      :visible (if (w :visible) true false)
      :row (or (w :row) 0)
      :mark (w :mark)
      :layout (when o (string (o :layout)))
      :meta (w :layout-meta)}))

# --- Change tracking ---

(var last-tags nil)
(var last-layout nil)
(var last-title nil)
(var last-windows nil)

# --- Watchers ---

(def- watchers @[])

(defn- write-json
  "Write a JSON event line directly to a buffer."
  [buf topic data]
  (def obj (merge-into @{"event" (string topic)} data))
  (buffer/push buf (json/encode obj))
  (buffer/push buf "\n"))

(def- max-buf-size 65536)

(defn- notify-watcher
  "Signal a watcher that new data is available. Non-blocking."
  [w]
  # Drop stale buffered data if backpressure is building up — the consumer
  # only cares about the latest state, which will be re-sent on next change.
  (when (> (length (w :buf)) max-buf-size)
    (buffer/clear (w :buf)))
  (when-let [ch (w :wake)]
    (unless (ev/full ch)
      (ev/give ch true))))

(defn emit-events
  "Compute per-topic state, update globals, write changes to watcher buffers."
  [outputs windows seats]
  (def focused-output (when-let [s (first seats)] (s :focused-output)))

  # freeze before comparing — Janet's deep= considers mutable tables/arrays
  # and frozen structs/tuples as different types, so comparing a fresh mutable
  # result against a frozen last-* always returns false.
  (def tags (freeze (compute-tags outputs windows focused-output)))
  (def tags-changed (not (deep= tags last-tags)))
  (when tags-changed (set last-tags tags))

  # When tags change, force-emit all topics — they're correlated (different
  # tag → different viewport, visible windows, focused title). Without this,
  # consumers see stale viewport data from the previous tag.
  (def layout (freeze (compute-layout outputs focused-output)))
  (def layout-changed (or tags-changed (not (deep= layout last-layout))))
  (when layout-changed (set last-layout layout))

  (def title (freeze (compute-title seats)))
  (def title-changed (or tags-changed (not (deep= title last-title))))
  (when title-changed (set last-title title))

  (def win-state (freeze (compute-windows windows seats outputs)))
  (def windows-changed (or tags-changed (not (deep= win-state last-windows))))
  (when windows-changed (set last-windows win-state))

  # Write changed topics to watcher buffers, then notify once
  (var any-changed false)
  (each w watchers
    (when (and tags-changed ((w :topics) :tags))
      (write-json (w :buf) :tags last-tags)
      (set any-changed true))
    (when (and layout-changed ((w :topics) :layout))
      (write-json (w :buf) :layout last-layout)
      (set any-changed true))
    (when (and title-changed ((w :topics) :title))
      (write-json (w :buf) :title last-title)
      (set any-changed true))
    (when (and windows-changed ((w :topics) :windows))
      (write-json (w :buf) :windows @{:windows last-windows})
      (set any-changed true))
    (when any-changed
      (notify-watcher w)
      (set any-changed false))))

(defn emit-signal
  "Emit a named signal to watchers on the :signal topic."
  [name &opt args]
  (def data @{"name" name})
  (when args (put data "args" args))
  (each w watchers
    (when ((w :topics) :signal)
      (write-json (w :buf) :signal data)
      (notify-watcher w))))

# Wire emit-signal into actions to avoid circular import.
(set action/emit-signal-fn emit-signal)

# --- JSON watch (for tidepoolmsg watch) ---

(defn- make-stream-send
  "Create a function that sends a length-prefixed message to a stream."
  [stream]
  (def sbuf @"")
  (fn [msg]
    (buffer/clear sbuf)
    (buffer/push-word sbuf (length msg))
    (buffer/push-string sbuf msg)
    (:write stream sbuf)))

(defn watch-json
  "Watch topics reactively. Writes events directly to the network
  stream as they arrive, bypassing the netrepl flusher."
  [topics]
  (log "watch-json start: %j" topics)
  (def stream (dyn :netrepl-stream))
  (def send (make-stream-send stream))
  (def wake-ch (ev/chan 64))
  (def topic-set (tabseq [t :in topics] t true))
  # Use a queue of ready-to-send snapshots instead of a shared mutable buffer.
  # emit-events writes JSON into `buf`, then the wake handler snapshots and
  # enqueues it. This avoids the buffer growing unboundedly when sends are slow.
  (def buf @"")
  (def outbox (ev/chan 256))
  (def entry @{:buf buf :topics topic-set :wake wake-ch :outbox outbox})

  # Send current state immediately — one message per topic to keep messages small.
  (each topic topics
    (def current (case topic
                   :tags last-tags
                   :layout last-layout
                   :title last-title
                   :windows (when last-windows @{:windows last-windows})))
    (when current
      (def topic-buf @"")
      (write-json topic-buf topic current)
      (send (string "\xFF" topic-buf))))

  (array/push watchers entry)
  (defer (do
           (log "watch-json disconnect: %j" topics)
           (when-let [i (index-of entry watchers)]
             (array/remove watchers i)))
    # Wait for signals from emit-events, flush buffer to stream.
    (while true
      (ev/take wake-ch)
      (when (> (length buf) 0)
        # Snapshot and clear buffer BEFORE sending — send yields for async I/O,
        # during which emit-events can append new data to buf. Clearing after
        # send would discard those writes.
        (def snapshot (string "\xFF" buf))
        (buffer/clear buf)
        (send snapshot)))))

# --- Introspection ---

(defn status
  "Return a table of IPC debug info."
  []
  @{:num-watchers (length watchers)
    :watchers (seq [w :in watchers]
               @{:topics (keys (w :topics))
                 :buf-len (length (w :buf))})
    :last-tags (if last-tags :cached :nil)
    :last-layout (if last-layout :cached :nil)
    :last-title (if last-title :cached :nil)
    :last-windows (if last-windows :cached :nil)})

# --- Action dispatch ---

(defn- format-mods [mods]
  "Format modifier table as a human-readable string."
  (def parts @[])
  (when (mods :mod4) (array/push parts "Super"))
  (when (mods :shift) (array/push parts "Shift"))
  (when (mods :ctrl) (array/push parts "Ctrl"))
  (when (mods :mod1) (array/push parts "Alt"))
  (string/join parts "+"))

(defn- format-keybind [binding]
  "Format a binding's key combo as a string like 'Super+Shift+h'."
  (def mods-str (format-mods (binding :mods)))
  (def key-str (string (binding :keysym)))
  (if (> (length mods-str) 0)
    (string mods-str "+" key-str)
    key-str))

(defn dispatch
  "Execute an action by name with string arguments.
  Returns true on success, or throws on unknown action."
  [name & args]
  (def entry (get action/registry name))
  (when (nil? entry) (error (string "unknown action: " name)))
  (def seat (first (state/wm :seats)))
  (when (nil? seat) (error "no seat available"))
  (def action-obj
    (if-let [parse (entry :parse)]
      ((entry :create) (parse args))
      ((entry :create))))
  (def action-fn (if (table? action-obj) (action-obj :fn) action-obj))
  (action-fn (state/action-context seat))
  true)

(defn list-actions
  "Return all registered actions with descriptions, specs, and keybinds as a JSON string."
  []
  # Build reverse map: action-name+args -> keybind string
  (def bind-map @{})
  (each seat (state/wm :seats)
    (each b (seat :xkb-bindings)
      (when (b :action-name)
        (def args (b :action-args))
        (def key (if (and args (> (length args) 0))
                   (string (b :action-name) " " (string/join (map string args) " "))
                   (b :action-name)))
        (put bind-map key (format-keybind b)))))
  (json/encode
    (sorted-by |($ "name")
      (seq [[name entry] :pairs action/registry]
        (def out @{"name" name})
        (when (entry :desc) (put out "desc" (entry :desc)))
        (when (entry :spec) (put out "spec" (entry :spec)))
        # Check for keybinds matching this action (with no args = bare action)
        (when-let [key (get bind-map name)]
          (put out "key" key))
        out))))

(defn list-bindings
  "Return all keyboard bindings with action metadata as a JSON string."
  []
  (def result @[])
  (each seat (state/wm :seats)
    (each b (seat :xkb-bindings)
      (def entry @{"key" (format-keybind b)})
      (when (b :action-name)
        (put entry "action" (b :action-name))
        (put entry "desc" (or (b :action-desc) ""))
        (def args (b :action-args))
        (when (and args (> (length args) 0))
          (put entry "args" (map string args))))
      (array/push result entry)))
  (json/encode result))

(defn list-windows
  "Return all live windows as a JSON string."
  []
  (json/encode
    (seq [w :in (state/wm :windows) :when (not (or (w :closed) (w :closing)))]
      (def out @{"wid" (w :wid) "app" (or (w :app-id) "") "title" (or (w :title) "")})
      (when (w :tag) (put out "tag" (w :tag)))
      (when (w :mark) (put out "mark" (w :mark)))
      out)))

(defn list-marks
  "Return all live marks as a JSON string."
  []
  (json/encode
    (seq [[name w] :pairs state/marks :when (and w (not (w :closed)))]
      @{"name" name "app" (or (w :app-id) "") "title" (or (w :title) "")})))

# --- Debug ---

(defn set-debug
  "Toggle or set debug mode. Returns current state."
  [&opt val]
  (def new-val (if (nil? val) (not (state/config :debug)) val))
  (put state/config :debug new-val)
  (eprintf "tidepool: debug %s" (if new-val "enabled" "disabled"))
  new-val)

# --- Save/load wrappers ---

(defn serialize-state
  "Serialize current state as JDN, prints to stdout."
  []
  (print (persist/serialize (state/wm :windows) (state/wm :outputs) state/tag-layouts))
  (flush))

(defn apply-state
  "Apply parsed state data."
  [data]
  (persist/apply-state data))
