(import spork/json)
(import ./log)
(import ./actions)
(import ./tree)

(var- ctx-ref nil)
(def- watchers @[])
(def- action-registry @{})
(var- decorator nil)  # the active decorator watcher, or nil

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
(reg-action "absorb-left" actions/absorb-left)
(reg-action "absorb-right" actions/absorb-right)
(reg-action "absorb-up" actions/absorb-up)
(reg-action "absorb-down" actions/absorb-down)
(reg-action "eject" actions/eject)
(reg-action "expel-left" actions/expel-left)
(reg-action "expel-right" actions/expel-right)
(reg-action "expel-up" actions/expel-up)
(reg-action "expel-down" actions/expel-down)
(reg-action "grow" actions/grow)
(reg-action "toggle-split-tabbed" actions/toggle-split-tabbed)
(reg-action "focus-tab-next" actions/focus-tab-next)
(reg-action "focus-tab-prev" actions/focus-tab-prev)
(reg-action "focus-tag" actions/focus-tag true)
(reg-action "send-to-tag" actions/send-to-tag true)
(reg-action "spawn" actions/spawn true)
(reg-action "toggle-float" actions/toggle-float)
(reg-action "focus-float-next" actions/focus-float-next)
(reg-action "focus-float-prev" actions/focus-float-prev)
(reg-action "gather-floats" actions/gather-floats)

# --- Write helpers ---

(defn- try-write
  "Write to stream with 5s timeout. Returns true on success, false on failure."
  [stream buf]
  (try
    (do (ev/write stream buf 5) true)
    ([_] false)))

(defn- watcher-writer
  "Fiber loop: take messages from channel and write them serially."
  [w]
  (def ch (w :ch))
  (while (not (w :closed))
    (def buf (ev/take ch))
    (when (nil? buf) (break))
    (unless (try-write (w :stream) buf)
      (put w :closed true)
      (try (:close (w :stream)) ([_])))))

# --- Watcher management ---

(defn- prune-watchers []
  (var i 0)
  (while (< i (length watchers))
    (if ((watchers i) :closed)
      (do
        # Detect decorator disconnect
        (when (= (watchers i) decorator)
          (set decorator nil)
          (log/info "ipc: decorator disconnected")
          (when ctx-ref
            (put (ctx-ref :config) :decoration-height 0)
            (when-let [wm (get-in ctx-ref [:registry :proxies "river_window_manager_v1"])]
              (:manage-dirty wm))))
        (when-let [ch ((watchers i) :ch)]
          (ev/chan-close ch))
        (array/remove watchers i))
      (++ i))))

(defn has-watchers?
  "Check if there are any active watchers."
  []
  (not (empty? watchers)))

(defn emit
  "Send a JSON-RPC notification to matching watchers (non-blocking).
   Messages are queued in a per-watcher channel and written serially by
   a dedicated fiber, preventing concurrent writes from corrupting the stream."
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
        (ev/give (w :ch) buf)))))

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
              (when-let [wm (get-in ctx-ref [:registry :proxies "river_window_manager_v1"])]
                (:manage-dirty wm))
              (respond stream id {"ok" true}))
            (respond-error stream id -32603 "no seat available"))
          ([err]
            (respond-error stream id -32603 (string err)))))
      (respond-error stream id -32602 (string "unknown action: " name)))
    (respond-error stream id -32602 "missing 'name' in params")))

(defn- handle-watch [stream id params]
  (def events (when params (get params "events")))
  (def w @{:stream stream :events events :ch (ev/chan 16)})
  (array/push watchers w)
  (ev/go (fn [] (watcher-writer w)))
  (respond stream id {"ok" true}))

(defn- handle-list-actions [stream id]
  (respond stream id {"actions" (sorted (keys action-registry))}))

(defn- handle-register-decorator [stream id params]
  # Close existing decorator (takeover)
  (when decorator
    (put decorator :closed true)
    (try (:close (decorator :stream)) ([_]))
    (log/info "ipc: decorator replaced"))
  # Register as watcher with all events
  (def w @{:stream stream
            :events ["state" "focus:changed" "window:new" "window:closed"
                     "decoration:create" "decoration:update"
                     "decoration:resize" "decoration:destroy"]
            :ch (ev/chan 64)})
  (array/push watchers w)
  (ev/go (fn [] (watcher-writer w)))
  (set decorator w)
  # Activate decoration height
  (def config (ctx-ref :config))
  (def dh (config :decoration-height))
  (when (<= dh 0)
    (put config :decoration-height (or (config :decoration-config-height) 28)))
  (log/infof "ipc: decorator registered (height=%d)" (config :decoration-height))
  # Trigger re-layout
  (when-let [wm (get-in ctx-ref [:registry :proxies "river_window_manager_v1"])]
    (:manage-dirty wm))
  (respond stream id {"ok" true
                       "height" (config :decoration-height)}))

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
        "register-decorator" (handle-register-decorator stream id params)
        "debug-windows" (respond stream id
          {"windows"
           (seq [w :in (ctx-ref :windows)
                 :when (not (w :pending-destroy))]
             {"wid" (w :wid) "app-id" (or (w :app-id) "")
              "tag" (or (w :tag) 0)
              "w" (or (w :w) 0) "h" (or (w :h) 0)
              "proposed-w" (or (w :proposed-w) 0)
              "proposed-h" (or (w :proposed-h) 0)
              "vx" (or (w :vx) -1)
              "x" (if (w :x) true false)
              "y" (or (w :y) 0)
              "visible" (if (w :visible) true false)
              "layout-hidden" (if (w :layout-hidden) true false)
              "render-hidden" (if (w :render-hidden) true false)
              "closed" (if (w :closed) true false)
              "float" (if (w :float) true false)
              "has-leaf" (if (w :tree-leaf) true false)
              "clip-applied" (if (w :clip-applied) true false)})})
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

(defn- count-leaves [node]
  (case (node :type)
    :leaf 1
    :container (sum (map count-leaves (node :children)))
    0))

(defn- build-tree [node focused-id &opt depth]
  "Build a JSON-friendly tree representation of the column layout.
   Includes window metadata (title, app-id) at leaves for decorator use."
  (default depth 0)
  (case (node :type)
    :leaf (let [w (get node :window)]
            {"type" "leaf"
             "focused" (if (and focused-id (= w focused-id)) true false)
             "app-id" (if w (or (w :app-id) "") "")
             "title" (if w (or (w :title) "") "")})
    :container {"type" "container"
                "mode" (string (node :mode))
                "active" (or (node :active) 0)
                "orientation" (string (tree/orientation-at-depth depth))
                "children" (map |(build-tree $ focused-id (inc depth)) (node :children))}
    nil))

# --- Decorator state ---

(defn has-decorator?
  "Check if an active decorator is registered."
  []
  (not (nil? decorator)))

(var- next-deco-id 0)

(defn- deco-tree-for-window [ctx w]
  "Build tree data for the column containing window w."
  (when-let [leaf (w :tree-leaf)
             col (tree/column-of leaf)
             tag (get-in ctx [:tags (w :tag)])
             fid (tag :focused-id)]
    (build-tree col fid)))

(defn emit-decoration-create
  "Emit decoration:create for a window that just got a decoration."
  [ctx w]
  (when (not decorator) (break))
  (def id (++ next-deco-id))
  (put w :deco-id id)
  (def focused (when-let [s (first (ctx :seats))] (s :focused)))
  (emit "decoration:create"
    {"id" id
     "width" (or (w :proposed-w) (w :w) 0)
     "height" ((ctx :config) :decoration-height)
     "app-id" (or (w :app-id) "")
     "title" (or (w :title) "")
     "focused" (= w focused)
     "tree" (or (deco-tree-for-window ctx w) {})}))

(defn emit-decoration-destroy
  "Emit decoration:destroy for a window losing its decoration."
  [ctx w]
  (when (and decorator (w :deco-id))
    (emit "decoration:destroy" {"id" (w :deco-id)})
    (put w :deco-id nil)))

(defn emit-decoration-updates
  "Pipeline step: emit decoration updates for title/focus/size changes."
  [ctx]
  (when (not decorator) (break))
  (def focused (when-let [s (first (ctx :seats))] (s :focused)))
  (each w (ctx :windows)
    (when (w :deco-id)
      (def cur-focused (= w focused))
      (def cur-title (or (w :title) ""))
      (def cur-app-id (or (w :app-id) ""))
      (def cur-w (or (w :proposed-w) (w :w) 0))
      # Check for changes
      (when (or (not= cur-focused (w :deco-was-focused))
                (not= cur-title (w :deco-was-title))
                (not= cur-app-id (w :deco-was-app-id)))
        (put w :deco-was-focused cur-focused)
        (put w :deco-was-title cur-title)
        (put w :deco-was-app-id cur-app-id)
        (emit "decoration:update"
          {"id" (w :deco-id)
           "title" cur-title
           "app-id" cur-app-id
           "focused" cur-focused
           "tree" (or (deco-tree-for-window ctx w) {})}))
      # Check for resize
      (when (not= cur-w (w :deco-was-w))
        (put w :deco-was-w cur-w)
        (emit "decoration:resize"
          {"id" (w :deco-id)
           "width" cur-w
           "height" ((ctx :config) :decoration-height)})))))

# --- State snapshot ---

(defn- build-state [ctx]
  "Build structural state snapshot (frozen for cheap deep= comparison).
   Camera is excluded — it changes every animation frame and would defeat
   deduplication. Added back in the emitted version."
  (def focused-output
    (when-let [s (first (ctx :seats))] (s :focused-output)))
  (def focused-window
    (when-let [s (first (ctx :seats))] (s :focused)))

  # Per-output state with scroll viewport
  (def outputs
    (tuple/slice
      (seq [o :in (ctx :outputs)]
        (def tag-id (o :primary-tag))
        (def tag (when tag-id (get-in ctx [:tags tag-id])))
        (def columns
          (when tag
            (def cols (tag :columns))
            (def fid (tag :focused-id))
            (def focused-col
              (when-let [fl (when fid (fid :tree-leaf))]
                (tree/column-of fl)))
            (tuple/slice
              (seq [col :in cols]
                {"width" (col :width)
                 "leaves" (count-leaves col)
                 "focused" (if (= col focused-col) true false)
                 "tree" (build-tree col fid)}))))
        {"name" (or (o :name) "")
         "x" (or (o :x) 0) "y" (or (o :y) 0)
         "w" (or (o :w) 0) "h" (or (o :h) 0)
         "focused" (= o focused-output)
         "tag" (or tag-id 0)
         "columns" (or columns [])})))

  # Occupied tags (tags with at least one non-closed window)
  (def occ @{})
  (each w (ctx :windows)
    (when (and (w :tag) (not (w :closed)) (not (w :pending-destroy)))
      (put occ (w :tag) true)))

  {"outputs" outputs
   "occupied-tags" (tuple ;(sorted (keys occ)))
   "focused" (if focused-window
               {"app-id" (or (focused-window :app-id) "")
                "title" (or (focused-window :title) "")}
               {})})

(defn- state-with-cameras [state ctx]
  "Add camera values to a state snapshot for emission."
  (def outputs
    (seq [o :in (state "outputs")]
      (def tag-id (o "tag"))
      (def tag (when tag-id (get-in ctx [:tags tag-id])))
      (merge o {"camera" (if tag (or (tag :camera) 0) 0)})))
  (merge state {"outputs" outputs}))

(var- last-state nil)

(defn emit-state-events
  "Pipeline step: emit state snapshot and granular events.
   Builds a frozen state struct (excluding camera) and uses deep= to detect
   changes — short-circuits on identical substructures. Only encodes JSON
   and emits when something structural actually changed."
  [ctx]
  (when (not (has-watchers?)) (break))
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
          {}))))
  (def state (build-state ctx))
  (when (not (deep= state last-state))
    (set last-state state)
    (emit "state" (state-with-cameras state ctx))))

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
