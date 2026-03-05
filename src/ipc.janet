(import ./state)
(import ./persist)
(import spork/json)

(def- subscribers
  "Topic -> array of channels."
  @{})

(defn subscribe
  "Subscribe to a topic. Returns a channel that receives events."
  [topic]
  (def ch (ev/chan 256))
  (unless (subscribers topic) (put subscribers topic @[]))
  (array/push (subscribers topic) ch)
  ch)

(defn unsubscribe
  "Remove a channel from a topic's subscriber list."
  [topic ch]
  (when-let [subs (subscribers topic)]
    (when-let [i (index-of ch subs)]
      (array/remove subs i))))

(defn emit
  "Emit an event to all subscribers of a topic."
  [topic data]
  (when-let [subs (subscribers topic)]
    (each ch subs
      (ev/give ch data))))

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
  (seq [o :in outputs]
    @{:x (o :x) :y (o :y)
      :layout (o :layout)
      :focused (= o focused-output)}))

(defn- compute-title
  "Compute focused window title."
  [seats]
  (when-let [s (first seats)
             w (s :focused)]
    @{:title (or (w :title) "")
      :app-id (or (w :app-id) "")}))

# --- Change tracking + emission ---

(var- last-tags nil)
(var- last-layout nil)
(var- last-title nil)

(defn- has-subscribers? [& topics]
  (some |(when-let [subs (get subscribers $)]
           (> (length subs) 0))
        topics))

(defn emit-events
  "Compute per-topic state and emit only changed topics."
  [outputs windows seats]
  (when (has-subscribers? :tags :layout :title)
    (def focused-output (when-let [s (first seats)] (s :focused-output)))

    (when (has-subscribers? :tags)
      (def tags (compute-tags outputs windows focused-output))
      (unless (deep= tags last-tags)
        (set last-tags tags)
        (emit :tags tags)))

    (when (has-subscribers? :layout)
      (def layout (compute-layout outputs focused-output))
      (unless (deep= layout last-layout)
        (set last-layout layout)
        (emit :layout layout)))

    (when (has-subscribers? :title)
      (def title (compute-title seats))
      (unless (deep= title last-title)
        (set last-title title)
        (emit :title title)))))

# --- JSON watch (for tidepoolmsg watch) ---

(defn watch-json
  "Watch multiple topics, printing JSON lines. Blocks until disconnect."
  [topics]
  (def channels @[])
  (def topic-map @{})
  (each topic topics
    (def ch (subscribe topic))
    (array/push channels ch)
    (put topic-map ch topic))
  (defer (each ch channels
           (unsubscribe (topic-map ch) ch))
    (forever
      (def [_ ch data] (ev/select ;channels))
      (def topic (get topic-map ch))
      (def obj (merge-into @{"event" (string topic)} data))
      (print (json/encode obj))
      (flush))))

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
