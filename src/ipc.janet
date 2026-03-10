(import ./state)
(import ./persist)
(import ./pool)
(import ./actions :as action)
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
        :tags (sorted (keys (o :tags)))
        :focused (= o focused-output)})
    :occupied (sorted (keys occupied))})

(defn- compute-layout
  "Compute layout state: per-output active tag pool mode."
  [outputs focused-output]
  @{:outputs (seq [o :in outputs]
      (def tag-pool
        (when-let [root (o :pool)]
          (def active (or (root :active) 0))
          (get (root :children) active)))
      @{:x (o :x) :y (o :y)
        :layout (if tag-pool (string (tag-pool :mode)) "unknown")
        :focused (= o focused-output)})})

(defn- compute-title
  "Compute focused window title."
  [seats]
  (if-let [s (first seats)
           w (s :focused)]
    @{:title (or (w :title) "")
      :app-id (or (w :app-id) "")}
    @{:title "" :app-id ""}))

# --- Change tracking ---

(var last-tags-jdn nil)
(var last-layout-jdn nil)
(var last-title-jdn nil)
(var last-tags nil)
(var last-layout nil)
(var last-title nil)

# --- Watchers ---

(def- watchers @[])

(defn- write-json
  "Write a JSON event line directly to a buffer."
  [buf topic data]
  (def obj (merge-into @{"event" (string topic)} data))
  (buffer/push buf (json/encode obj))
  (buffer/push buf "\n"))

(defn- notify-watcher
  "Signal a watcher that new data is available. Non-blocking."
  [w]
  (when-let [ch (w :wake)]
    (unless (ev/full ch)
      (ev/give ch true))))

(defn emit-events
  "Compute per-topic state, update globals, write changes to watcher buffers."
  [outputs windows seats]
  (def focused-output (when-let [s (first seats)] (s :focused-output)))

  (def tags (compute-tags outputs windows focused-output))
  (def tags-jdn (string/format "%j" (freeze tags)))
  (unless (= tags-jdn last-tags-jdn)
    (set last-tags-jdn tags-jdn)
    (set last-tags tags)
    (each w watchers
      (when ((w :topics) :tags)
        (write-json (w :buf) :tags tags)
        (notify-watcher w))))

  (def layout (compute-layout outputs focused-output))
  (def layout-jdn (string/format "%j" (freeze layout)))
  (unless (= layout-jdn last-layout-jdn)
    (set last-layout-jdn layout-jdn)
    (set last-layout layout)
    (each w watchers
      (when ((w :topics) :layout)
        (write-json (w :buf) :layout layout)
        (notify-watcher w))))

  (def title (compute-title seats))
  (def title-jdn (string/format "%j" (freeze title)))
  (unless (= title-jdn last-title-jdn)
    (set last-title-jdn title-jdn)
    (set last-title title)
    (each w watchers
      (when ((w :topics) :title)
        (write-json (w :buf) :title title)
        (notify-watcher w)))))

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
  (def buf @"")
  (def wake-ch (ev/chan 64))
  (def topic-set (tabseq [t :in topics] t true))
  (def entry @{:buf buf :topics topic-set :wake wake-ch})

  # Send current state immediately.
  (each topic topics
    (def current (case topic
                   :tags last-tags
                   :layout last-layout
                   :title last-title))
    (when current
      (write-json buf topic current)))
  (when (> (length buf) 0)
    (send (string "\xFF" buf))
    (buffer/clear buf))

  (array/push watchers entry)
  (defer (do
           (log "watch-json disconnect: %j" topics)
           (when-let [i (index-of entry watchers)]
             (array/remove watchers i)))
    # Wait for signals from emit-events, flush buffer to stream.
    (while true
      (ev/take wake-ch)
      (when (> (length buf) 0)
        (send (string "\xFF" buf))
        (buffer/clear buf)))))

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
    :last-title (if last-title :cached :nil)})

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
  (action-fn seat nil)
  true)

(defn list-actions
  "Return array of all registered actions with descriptions."
  []
  (sorted-by |($ "name")
    (seq [[name entry] :pairs action/registry]
      @{"name" name})))

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
  (persist/serialize))

(defn apply-state
  "Apply parsed state data."
  [data]
  (persist/apply-state data))
