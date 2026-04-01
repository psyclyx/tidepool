(import spork/json)
(import ./log)
(import ./actions)

(var- ctx-ref nil)
(def- watchers @[])
(def- action-registry @{})

# --- Action registration ---

(defn reg-action
  "Register an IPC action. If factory is truthy, f is called with args to produce
   the action fn. Otherwise f is the action fn directly."
  [name f &opt factory]
  (put action-registry name @{:fn f :factory (if factory true false)}))

# Built-in actions
(reg-action "close-focused" actions/close-focused)
(reg-action "focus-left" actions/focus-left)
(reg-action "focus-right" actions/focus-right)
(reg-action "focus-up" actions/focus-up)
(reg-action "focus-down" actions/focus-down)
(reg-action "swap-left" actions/swap-left)
(reg-action "swap-right" actions/swap-right)
(reg-action "swap-up" actions/swap-up)
(reg-action "swap-down" actions/swap-down)
(reg-action "join-left" actions/join-left)
(reg-action "join-right" actions/join-right)
(reg-action "join-up" actions/join-up)
(reg-action "join-down" actions/join-down)
(reg-action "leave" actions/leave)
(reg-action "cycle-width-forward" actions/cycle-width-forward)
(reg-action "cycle-width-backward" actions/cycle-width-backward)
(reg-action "toggle-insert-mode" actions/toggle-insert-mode)
(reg-action "make-tabbed" actions/make-tabbed)
(reg-action "make-split" actions/make-split)
(reg-action "focus-tab-next" actions/focus-tab-next)
(reg-action "focus-tab-prev" actions/focus-tab-prev)
(reg-action "focus-tag" actions/focus-tag true)
(reg-action "send-to-tag" actions/send-to-tag true)
(reg-action "spawn" actions/spawn true)

# --- Write helpers ---

(defn- try-write
  "Write to stream with 1s timeout. Returns true on success, false on failure."
  [stream buf]
  (try
    (do (ev/write stream buf 1) true)
    ([_] false)))

# --- Watcher management ---

(defn- prune-watchers []
  (var i 0)
  (while (< i (length watchers))
    (if ((watchers i) :closed)
      (array/remove watchers i)
      (++ i))))

(defn emit
  "Send a JSON-RPC notification to matching watchers."
  [event-type &opt params]
  (prune-watchers)
  (when (not (empty? watchers))
    (def buf (string (json/encode {"jsonrpc" "2.0"
                                    "method" event-type
                                    "params" (or params {})}) "\n"))
    (each w watchers
      (when (and (not (w :closed))
                 (or (not (w :events))
                     (find |(= $ event-type) (w :events))))
        (unless (try-write (w :stream) buf)
          (put w :closed true)
          (try (:close (w :stream)) ([_])))))))

# --- JSON-RPC response helpers ---

(defn- respond [stream id result]
  (try-write stream
    (string (json/encode {"jsonrpc" "2.0" "id" id "result" result}) "\n")))

(defn- respond-error [stream id code message]
  (try-write stream
    (string (json/encode {"jsonrpc" "2.0" "id" id
                           "error" {"code" code "message" message}}) "\n")))

# --- RPC method handlers ---

(defn- handle-action [stream id params]
  (if-let [name (get params "name")]
    (if-let [entry (action-registry name)]
      (let [args (get params "args")
            action-fn (if (entry :factory)
                        ((entry :fn) ;(or args []))
                        (entry :fn))]
        (try
          (if-let [s (first (ctx-ref :seats))]
            (do
              (array/push (s :pending-actions) action-fn)
              (respond stream id {"ok" true}))
            (respond-error stream id -32603 "no seat available"))
          ([err]
            (respond-error stream id -32603 (string err)))))
      (respond-error stream id -32602 (string "unknown action: " name)))
    (respond-error stream id -32602 "missing 'name' in params")))

(defn- handle-watch [stream id params]
  (def events (when params (get params "events")))
  (array/push watchers @{:stream stream :events events})
  (respond stream id {"ok" true}))

(defn- handle-list-actions [stream id]
  (respond stream id {"actions" (sorted (keys action-registry))}))

# --- Request dispatch ---

(defn- handle-request [stream line]
  (try
    (let [req (json/decode line)
          id (get req "id")
          method (get req "method")
          params (get req "params")]
      (case method
        "action" (handle-action stream id params)
        "watch" (handle-watch stream id params)
        "list-actions" (handle-list-actions stream id)
        (respond-error stream id -32601 (string "unknown method: " method))))
    ([err]
      (log/debugf "ipc: parse error: %s" err)
      (respond-error stream nil -32700 "parse error"))))

# --- Connection handler ---

(defn- handle-connection [stream]
  (defer (do
           (each w watchers
             (when (= (w :stream) stream)
               (put w :closed true)))
           (try (:close stream) ([_])))
    (def buf @"")
    (forever
      (def chunk (ev/read stream 4096))
      (unless chunk (break))
      (buffer/push buf chunk)
      (while (def idx (string/find "\n" buf))
        (def line (string/slice buf 0 idx))
        (def rest (buffer/slice buf (+ idx 1)))
        (buffer/clear buf)
        (buffer/push buf rest)
        (when (> (length line) 0)
          (handle-request stream line))))))

# --- Pipeline steps for event emission ---

(defn emit-close-events
  "Pipeline step: emit window:closed before windows are destroyed."
  [ctx]
  (each w (ctx :windows)
    (when (w :pending-destroy)
      (emit "window:closed" {"app-id" (w :app-id)
                              "title" (w :title)
                              "tag" (w :tag)}))))

(defn emit-state-events
  "Pipeline step: emit new-window and focus-change events."
  [ctx]
  (each w (ctx :windows)
    (when (w :new)
      (emit "window:new" {"app-id" (w :app-id)
                           "title" (w :title)
                           "tag" (w :tag)})))
  (each s (ctx :seats)
    (when (s :focus-changed)
      (def w (s :focused))
      (emit "focus:changed"
        (if w
          {"app-id" (w :app-id) "title" (w :title) "tag" (w :tag)}
          {})))))

# --- Server ---

(defn- socket-path []
  (string/format "%s/tidepool-ipc-%s"
    (assert (os/getenv "XDG_RUNTIME_DIR"))
    (assert (os/getenv "WAYLAND_DISPLAY"))))

(defn create
  "Start the IPC server. Returns the server stream."
  [ctx]
  (set ctx-ref ctx)
  (def path (socket-path))
  (protect (os/rm path))
  (def server (net/listen :unix path))
  (log/infof "ipc: listening on %s" path)
  (ev/go (fn []
           (try
             (forever
               (def stream (net/accept server))
               (log/debug "ipc: client connected")
               (ev/go (fn [] (handle-connection stream))))
             ([err]
               (log/debugf "ipc: accept loop ended: %s" err)))))
  server)
