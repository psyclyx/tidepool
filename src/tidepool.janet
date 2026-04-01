(import protocols)
(import wayland)

(import ./config)
(import ./dispatch)
(import ./wayland-client)
(import ./state)
(import ./output)
(import ./window)
(import ./seat)
(import ./actions)
(import ./scroll-actions)
(import ./tree)
(import ./scroll)
(import ./pipeline)
(import ./log)
(import ./ipc)

# Load protocol event handlers (self-registering on import)
(import ./protocols/river_window_manager_v1)
(import ./protocols/river_window_v1)
(import ./protocols/river_output_v1)
(import ./protocols/river_layer_shell_output_v1)
(import ./protocols/river_seat_v1)
(import ./protocols/river_layer_shell_seat_v1)
(import ./protocols/river_xkb_binding_v1)
(import ./protocols/wl_output)

(def interfaces
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

(var ctx nil)

(defn specs
  [c]
  {"wl_compositor" {:min-version 4}
   "wl_shm" {:min-version 1}
   "river_layer_shell_v1" {:min-version 1}
   "river_xkb_bindings_v1" {:min-version 1}
   "wp_viewporter" {:min-version 1}
   "wp_single_pixel_buffer_manager_v1" {:min-version 1}

   "river_window_manager_v1"
   {:min-version 3
    :handler (dispatch/handler c "river_window_manager_v1")}

   "zwlr_output_manager_v1"
   {:min-version 1
    :optional true
    :handler (dispatch/handler c "zwlr_output_manager_v1")}})


(defn main "Connect to Wayland, load config, and run the event loop."
  [& args]
  (let [opts (config/parse-opts args)
        display (wayland/connect interfaces)]
    (set ctx @{})
    (state/init ctx)
    (defer (:disconnect display)
      # Create registry and put in ctx before roundtrip, so that
      # protocol handlers for initial events can access proxies.
      (def registry (wayland-client/create display (specs ctx)))
      (put ctx :registry registry)
      (wayland-client/connect display registry)

      (def ipc-server (ipc/create ctx))
      (defer (:close ipc-server)
        (def env (curenv))
        (when-let [path (opts :init-path)]
          (config/exec-path path env))
        (def repl-server (config/repl-server-create env))
        (defer (:close repl-server)
          (forever (:dispatch display)))))))
