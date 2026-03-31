(import ./log)

(def- proto-handlers
  "Protocol event registry: [interface event-keyword] → (fn [ctx & args])."
  @{})

(def- event-handlers
  "Internal event registry: keyword → (fn [ctx & args])."
  @{})

(defn reg-proto
  "Register a protocol event handler."
  [interface event-name handler]
  (put proto-handlers [interface event-name] handler))

(defn reg-event
  "Register an internal event handler."
  [name handler]
  (put event-handlers name handler))

(defn dispatch
  "Dispatch an internal event."
  [ctx name & args]
  (if-let [handler (event-handlers name)]
    (do
      (log/tracef "dispatch %s" name)
      (handler ctx ;args))
    (log/warnf "no event handler for %s" name)))

(defn dispatch-proto
  "Dispatch a protocol event."
  [ctx interface event]
  (let [event-name (first event)
        key [interface event-name]]
    (if-let [handler (proto-handlers key)]
      (do
        (log/tracef "proto %s %s" interface event-name)
        (handler ctx ;(tuple/slice event 1)))
      (log/tracef "unhandled proto %s %s" interface event-name))))

(defn handler
  "Return a handler factory for client specs. Closes over ctx."
  [ctx interface]
  (fn [_global-name _global]
    (fn [event]
      (dispatch-proto ctx interface event))))

(defn proxy-handler
  "Return a handler fn for a proxy object that dispatches through reg-proto.
   Extra args are appended to every event."
  [ctx interface & extra]
  (fn [event]
    (dispatch-proto ctx interface [;event ;extra])))
