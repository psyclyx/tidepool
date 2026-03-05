(import ./state)
(import ./persist)

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

(defn watch
  "Watch events on a topic, printing each as JSON. Blocks until disconnect.
  For use from the REPL socket."
  [topic]
  (def ch (subscribe topic))
  (defer (unsubscribe topic ch)
    (forever
      (printf "%j" (ev/take ch))
      (flush))))

(defn- compute-state
  "Build a state summary for IPC consumers."
  [outputs windows focused-output]
  (def occupied @{})
  (each w windows
    (unless (or (w :closed) (w :closing))
      (put occupied (w :tag) true)))
  @{:outputs (seq [o :in outputs]
      @{:x (o :x) :y (o :y)
        :tags (sorted (keys (o :tags)))
        :layout (o :layout)
        :focused (= o focused-output)})
    :occupied (sorted (keys occupied))})

(var- last-state nil)

(defn emit-state
  "Compute current state and emit if changed. No-op when no subscribers."
  [outputs windows seats]
  (when-let [subs (get subscribers :state)]
    (when (> (length subs) 0)
      (def focused-output (when-let [s (first seats)] (s :focused-output)))
      (def s (compute-state outputs windows focused-output))
      (unless (deep= s last-state)
        (set last-state s)
        (emit :state s)))))

(defn save-state
  "Save current window/output/tag-layout state to disk."
  []
  (persist/save (state/wm :windows) (state/wm :outputs) state/tag-layouts))
