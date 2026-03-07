(import ./state)
(import ./persist)
(import spork/json)

# --- Debug logging ---

(var debug false)

(defn- log [fmt & args]
  (when debug
    (eprintf (string "ipc: " fmt) ;args)))

# --- Pub/sub ---

(def- subscribers
  "Topic -> array of channels."
  @{})

(defn subscribe
  "Subscribe to a topic. Returns a channel that receives events."
  [topic]
  (def ch (ev/chan 256))
  (unless (subscribers topic) (put subscribers topic @[]))
  (array/push (subscribers topic) ch)
  (log "subscribe %s (now %d subs)" topic (length (subscribers topic)))
  ch)

(defn unsubscribe
  "Remove a channel from a topic's subscriber list."
  [topic ch]
  (when-let [subs (subscribers topic)]
    (when-let [i (index-of ch subs)]
      (array/remove subs i)
      (log "unsubscribe %s (now %d subs)" topic (length subs)))))

(defn emit
  "Emit an event to all subscribers of a topic.
  Non-blocking: drops oldest events from full channels."
  [topic data]
  (when-let [subs (subscribers topic)]
    (when (> (length subs) 0)
      (var dropped 0)
      (each ch subs
        (while (>= (ev/count ch) (ev/capacity ch))
          (ev/take ch)
          (++ dropped))
        (ev/give ch data))
      (when (> dropped 0)
        (log "emit %s to %d subs (dropped %d old)" topic (length subs) dropped))
      (when (and debug (= dropped 0))
        (log "emit %s to %d subs" topic (length subs))))))

# --- Per-topic state computation ---

(defn- compute-tags
  "Compute tag state: per-output tag assignments + occupied tags."
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
  "Compute layout state: per-output layout name."
  [outputs focused-output]
  @{:outputs (seq [o :in outputs]
      @{:x (o :x) :y (o :y)
        :layout (o :layout)
        :focused (= o focused-output)})})

(defn- compute-title
  "Compute focused window title."
  [seats]
  (if-let [s (first seats)
           w (s :focused)]
    @{:title (or (w :title) "")
      :app-id (or (w :app-id) "")}
    @{:title "" :app-id ""}))

# --- Change tracking + emission ---

(var last-tags-jdn nil)
(var last-layout-jdn nil)
(var last-title-jdn nil)
(var last-tags nil)
(var last-layout nil)
(var last-title nil)

(defn emit-events
  "Compute per-topic state, cache it, and emit changed topics to subscribers."
  [outputs windows seats]
  (def focused-output (when-let [s (first seats)] (s :focused-output)))

  (def tags (compute-tags outputs windows focused-output))
  (def tags-jdn (string/format "%j" (freeze tags)))
  (unless (= tags-jdn last-tags-jdn)
    (set last-tags-jdn tags-jdn)
    (set last-tags tags)
    (emit :tags tags))

  (def layout (compute-layout outputs focused-output))
  (def layout-jdn (string/format "%j" (freeze layout)))
  (unless (= layout-jdn last-layout-jdn)
    (set last-layout-jdn layout-jdn)
    (set last-layout layout)
    (emit :layout layout))

  (def title (compute-title seats))
  (def title-jdn (string/format "%j" (freeze title)))
  (unless (= title-jdn last-title-jdn)
    (set last-title-jdn title-jdn)
    (set last-title title)
    (emit :title title)))

# --- JSON watch (for tidepoolmsg watch) ---

(defn- emit-json [topic data]
  (when data
    (log "emit-json %s (%d bytes)" topic (length (json/encode data)))
    (def obj (merge-into @{"event" (string topic)} data))
    (print (json/encode obj))
    (flush)))

(defn watch-json
  "Watch multiple topics, printing JSON lines. Blocks until disconnect.
  Sends current state for each topic immediately on connect."
  [topics]
  (log "watch-json start: %j" topics)
  (def channels @[])
  (def topic-map @{})
  (each topic topics
    (def ch (subscribe topic))
    (array/push channels ch)
    (put topic-map ch topic))
  # Send current state immediately so new subscribers don't wait for a change.
  (each topic topics
    (def current (case topic
                   :tags last-tags
                   :layout last-layout
                   :title last-title))
    (log "watch-json initial %s: %s" topic (if current "has data" "nil"))
    (emit-json topic current))
  (defer (do
           (log "watch-json disconnect: %j" topics)
           (each ch channels
             (unsubscribe (topic-map ch) ch)))
    (forever
      (def [_ ch data] (ev/select ;channels))
      (def topic (get topic-map ch))
      (log "watch-json event %s (ch count: %d)" topic (ev/count ch))
      (emit-json topic data)
      (when (> (length (dyn :out)) 65536)
        (log "watch-json outbuf overflow, flusher likely dead")
        (break)))))

# --- Introspection ---

(defn status
  "Return a table of IPC debug info."
  []
  @{:subscribers (tabseq [[topic subs] :pairs subscribers]
                   topic (seq [ch :in subs]
                           @{:count (ev/count ch)
                             :capacity (ev/capacity ch)}))
    :last-tags (if last-tags :cached :nil)
    :last-layout (if last-layout :cached :nil)
    :last-title (if last-title :cached :nil)
    :last-tags-jdn last-tags-jdn})

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
