(import protocols)
(import wayland)
(import spork/netrepl)

# --- Modules ---

(import ./state)
(import ./animation)
(import ./output)
(import ./output-config)
(import ./window)
(import ./seat)
(import ./indicator)
(import ./actions :as action)
(import ./pipeline)
(import ./layout)
(import ./layout/columns)
(import ./persist)

# --- Protocol Setup ---

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

(def required-interfaces
  @{"wl_compositor" 4
    "wp_viewporter" 1
    "wp_single_pixel_buffer_manager_v1" 1
    "river_window_manager_v1" 3
    "river_layer_shell_v1" 1
    "river_xkb_bindings_v1" 1})

(def optional-interfaces
  @{"zwlr_output_manager_v1" 1})

# --- User Config API ---
# Re-export for user config compatibility.
# User config sees: config, wm, action/focus, action/spawn, layout/layout-fns, etc.

(def config state/config)
(def wm state/wm)
(def xkb-binding/create seat/xkb-binding/create)
(def pointer-binding/create seat/pointer-binding/create)

# --- Event Dispatch ---

(defn wm/handle-event [event]
  (match event
    [:unavailable] (do (print "tidepool: another window manager is already running")
                       (os/exit 1))
    [:finished] (os/exit 0)
    [:manage-start] (pipeline/manage)
    [:render-start] (pipeline/render)
    [:output obj] (array/push (state/wm :outputs) (output/create obj))
    [:seat obj] (array/push (state/wm :seats) (seat/create obj))
    [:window obj] (array/insert (state/wm :windows) 0 (window/create obj))))

(defn registry/handle-event [event]
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
      # Set handler immediately so events arriving in the same
      # roundtrip aren't discarded by libwayland.
      (when (= interface "zwlr_output_manager_v1")
        (:set-handler obj output-config/handle-event)))))

# --- REPL Server ---

(def repl-env (curenv))

(defn repl-server-create []
  (def path (string/format "%s/tidepool-%s"
                           (assert (os/getenv "XDG_RUNTIME_DIR"))
                           (assert (os/getenv "WAYLAND_DISPLAY"))))
  (protect (os/rm path))
  (netrepl/server :unix path repl-env))

# --- Design: Workspace Abstraction ("Pools") ---
#
# Current model: outputs have a set of visible tags (integers 0-N).
# Each window has a single tag. Tags are global — any output can show
# any tag, and toggling a tag on one output removes it from others.
#
# Limitation: no way to group related tags, name them, or create
# ephemeral workspaces. Power users want named contexts (e.g., "code",
# "comms", "media") that persist across output changes and can contain
# multiple tags. The current flat tag model can't express this.
#
# Proposed: "Pools" — a composable workspace layer on top of tags.
#
#   (def pool @{:name "code"
#               :tags #{1 2 3}       # tags belonging to this pool
#               :sticky false        # if true, pool stays on its output
#               :output nil})        # preferred output (or nil for floating)
#
# A pool groups tags into a named unit. Switching to a pool activates
# all its tags on the target output. Pools can be:
#   - Static: defined in config (e.g., "code" = tags 1-3)
#   - Dynamic: created on the fly, tags allocated from a free pool
#   - Sticky: bound to a specific output (e.g., "chat" always on right monitor)
#
# Composable views: an output can show multiple pools simultaneously.
# This is already supported by the tag model — just union the tag sets.
# Pools add naming and grouping, not new visibility semantics.
#
# Transition path:
#   1. Pools are opt-in. Without pool config, behavior is unchanged.
#   2. action/focus-pool, action/send-to-pool, action/create-pool
#   3. Bar indicator shows pool names instead of/alongside tag numbers
#   4. Dynamic pools: action/create-pool allocates unused tags
#
# Open questions:
#   - Should tags be hidden from the user entirely when pools are active?
#   - How to handle tag conflicts (two pools wanting the same tag)?
#   - Per-output pool stacks (MRU pool switching per monitor)?
#
# This is a future direction. The current tag system is the right
# foundation — pools are sugar on top, not a replacement.

# --- Entry Point ---

(defn main [& args]
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

  (persist/load)

  # zwlr_output_manager_v1 handler was set in registry/handle-event.
  # If output config was applied during the roundtrips, the done event
  # will have fired already. Otherwise it arrives in the event loop.

  (def repl-server (repl-server-create))
  (defer (:close repl-server)
    (forever (:dispatch display))))
