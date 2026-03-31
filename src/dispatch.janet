(import ./log)

(def- proto-handlers
  "Protocol event registry: [interface event-keyword] → (fn [ctx & args] effects)."
  @{})

(def- event-handlers
  "Internal event registry: keyword → (fn [ctx & args] effects)."
  @{})

(def- fx-handlers
  "Effect registry: keyword → (fn [ctx value])."
  @{})

(defn reg-proto
  "Register a protocol event handler."
  [interface event-name handler]
  (put proto-handlers [interface event-name] handler))

(defn reg-event
  "Register an internal event handler."
  [name handler]
  (put event-handlers name handler))

(defn reg-fx
  "Register an effect handler."
  [name handler]
  (put fx-handlers name handler))

(defn- run-fx [ctx k v]
  (if-let [handler (fx-handlers k)]
    (handler ctx v)
    (log/warnf "no fx handler for %s" k)))

(defn apply-fx
  "Apply effects. Accepts a table {k v ...} or an array of [k v] tuples."
  [ctx effects]
  (if (indexed? effects)
    (each [k v] effects
      (run-fx ctx k v))
    (eachp [k v] effects
      (run-fx ctx k v))))

(defn dispatch
  "Dispatch an internal event."
  [ctx name & args]
  (if-let [handler (event-handlers name)]
    (do
      (log/tracef "dispatch %s" name)
      (when-let [effects (handler ctx ;args)]
        (apply-fx ctx effects)))
    (log/warnf "no event handler for %s" name)))

(defn dispatch-proto
  "Dispatch a protocol event."
  [ctx interface event]
  (let [event-name (first event)
        key [interface event-name]]
    (if-let [handler (proto-handlers key)]
      (do
        (log/tracef "proto %s %s" interface event-name)
        (when-let [effects (handler ctx ;(tuple/slice event 1))]
          (apply-fx ctx effects)))
      (log/tracef "unhandled proto %s %s" interface event-name))))

# Built-in fx
(reg-fx :dispatch
  (fn [ctx [name & args]]
    (dispatch ctx name ;args)))

(reg-fx :dispatch-n
  (fn [ctx events]
    (each [name & args] events
      (dispatch ctx name ;args))))

(reg-fx :put
  (fn [_ctx [tbl k v]]
    (put tbl k v)))

(reg-fx :put-all
  (fn [_ctx args]
    (let [tbl (first args)]
      (var i 1)
      (while (< i (length args))
        (put tbl (args i) (args (+ i 1)))
        (+= i 2)))))

(reg-fx :spawn
  (fn [_ctx cmd]
    (os/spawn [;cmd] :p)))

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
