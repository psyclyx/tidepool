(import protocols)
(import wayland)
(import spork/netrepl)

(import ./state)
(import ./animation)
(import ./output)
(import ./output-config)
(import ./window)
(import ./seat)
(import ./actions :as action)
(import ./pipeline)
(import ./layout)
(import ./layout/scroll)
(import ./persist)
(import ./ipc)

(def interfaces
  "Wayland protocol interface definitions."
  (wayland/scan
    :wayland-xml protocols/wayland-xml
    :system-protocols-dir protocols/wayland-protocols
    :system-protocols ["stable/viewporter/viewporter.xml"
                       "staging/single-pixel-buffer/single-pixel-buffer-v1.xml"]
    :custom-protocols (map |(string protocols/river-protocols $)
                           ["/river-window-management-v1.xml"
                            "/river-layer-shell-v1.xml"
                            "/river-xkb-bindings-v1.xml"
                            "/wlr-output-management-unstable-v1.xml"])))

(def required-interfaces
  "Minimum required compositor interface versions."
  @{"wl_compositor" 4
    "wl_shm" 1
    "wp_viewporter" 1
    "wp_single_pixel_buffer_manager_v1" 1
    "river_window_manager_v1" 3
    "river_layer_shell_v1" 1
    "river_xkb_bindings_v1" 1})

(def optional-interfaces
  "Optional compositor interfaces."
  @{"zwlr_output_manager_v1" 1})

# Re-exports for user config
(def config state/config)
(def wm state/wm)
(def xkb-binding/create seat/xkb-binding/create)
(def pointer-binding/create seat/pointer-binding/create)

(defn wm/handle-event "Dispatch window manager protocol events." [event]
  (match event
    [:unavailable] (do (print "tidepool: another window manager is already running")
                       (os/exit 1))
    [:finished] (os/exit 0)
    [:manage-start] (pipeline/manage)
    [:render-start] (pipeline/render)
    [:output obj] (array/push (state/wm :outputs)
                    (output/create obj state/config state/registry))
    [:seat obj] (array/push (state/wm :seats) (seat/create obj state/registry state/config))
    [:window obj]
    (let [windows (state/wm :windows)
          pos (if-let [seat (first (state/wm :seats))
                       focused (seat :focused)
                       i (index-of focused windows)]
                (+ i 1)
                0)]
      (array/insert windows pos (window/create obj)))))

(defn registry/handle-event "Bind required Wayland globals from the registry." [event]
  (match event
    [:global name interface version]
    (when-let [min-version (or (get required-interfaces interface)
                               (get optional-interfaces interface))]
      (when (< version min-version)
        (when (get required-interfaces interface)
          (errorf "compositor %s version too old (need %d, got %d)"
                  interface min-version version))
        (break))
      (def obj (:bind (state/registry :obj) name interface min-version))
      (put state/registry interface obj)
      (when (= interface "zwlr_output_manager_v1")
        (:set-handler obj output-config/handle-event)))))

(def repl-env (curenv))

(defn repl-server-create "Start a REPL server on a Unix socket." []
  (def path (string/format "%s/tidepool-%s"
                           (assert (os/getenv "XDG_RUNTIME_DIR"))
                           (assert (os/getenv "WAYLAND_DISPLAY"))))
  (protect (os/rm path))
  (netrepl/server :unix path
                  (fn [name stream]
                    (table/setproto @{:netrepl-stream stream} repl-env))))

(defn main "Connect to Wayland, load config, and run the event loop." [& args]
  (def display (wayland/connect interfaces))
  (os/setenv "WAYLAND_DEBUG" nil)

  (def config-dir (or (os/getenv "XDG_CONFIG_HOME")
                      (string (os/getenv "HOME") "/.config")))
  (def init-path (get 1 args (string config-dir "/tidepool/init.janet")))
  (when-let [init (file/open init-path :r)]
    (dofile init :env repl-env)
    (file/close init))

  (put state/registry :obj (:get-registry display))
  (:set-handler (state/registry :obj) registry/handle-event)
  (:roundtrip display)
  (eachk i required-interfaces
    (unless (get state/registry i)
      (errorf "compositor does not support %s" i)))

  (:set-handler (state/registry "river_window_manager_v1") wm/handle-event)
  (:roundtrip display)

  (ipc/emit-events (state/wm :outputs) (state/wm :windows) (state/wm :seats))

  (def repl-server (repl-server-create))
  (defer (:close repl-server)
    (forever (:dispatch display))))
