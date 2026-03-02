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
(import ./layout/scroll)
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

# --- Design Notes ---
#
# Tidepool's model: tags (integers) are the visibility primitive.
# Each window has one tag. Outputs have a set of visible tags. Tags
# are global — toggling one on an output steals it from others.
# Per-tag layouts are saved/restored on tag switch. State (tags,
# columns, layouts) persists across restarts via JDN.
#
# What works well enough to build on:
#   - Tags as flat integers (simple, composable, no allocation)
#   - Per-tag layout save/restore (tag 1 = scroll, tag 2 = monocle)
#   - Scroll layout as daily driver (columns, struts, variable widths)
#   - State persistence (window→tag, column assignments survive restarts)
#   - File-based IPC to waybar (per-output tag/layout files)
#
# What's missing, roughly in priority order:
#
# 1. Focus history
#
#    No MRU tracking. Alt-tab doesn't exist. When focus leaves an
#    output, there's no record of what was focused before. This is
#    the most felt gap in daily use.
#
#    Minimal version: per-output focus stack (array of windows, most
#    recent last). action/focus-prev pops the stack. The stack is
#    already approximated by render-order but not per-output and not
#    exposed as an action.
#
#    (defn focus-prev []
#      (fn [seat binding]
#        (when-let [o (seat :focused-output)
#                   stack (o :focus-stack)
#                   prev (last stack)]
#          (seat/focus seat prev))))
#
# 2. Pools (workspace groups)
#
#    Named groups of tags. "code" = tags 1-3, "comms" = tag 4.
#    focus-pool activates all of a pool's tags on the current output.
#    Pools are bookmarks for tag configurations, not a new primitive.
#
#    (def pool @{:name "code" :tags [1 2 3]})
#
#    Key insight: pools don't own tags exclusively. Tag 1 can be in
#    multiple pools. A pool is just a saved tag selection — like
#    focus-tag but for multiple tags at once. This avoids allocation
#    problems and tag conflicts entirely.
#
#    Static pools are defined in config. Dynamic pools could be
#    created from the current output's visible tags (snapshot).
#
#    Interaction with persist: pools themselves are config, not state.
#    But "which pool is active on which output" is state worth saving.
#
#    Bar integration: indicator already writes per-output tag files.
#    Pool names could be appended (or replace tag numbers when active).
#
# 3. Sticky windows
#
#    Windows visible on all tags. Useful for media players, chat,
#    terminals you always want accessible. Currently approximated by
#    the scratchpad (tag 0, float), but that's a single hidden tag,
#    not "always visible."
#
#    Implementation: a :sticky flag on the window. show-hide includes
#    sticky windows regardless of tag membership. Simple, but needs
#    thought on how sticky windows interact with layouts (excluded
#    from tiling? floating only? per-output?).
#
# 4. Window rules improvements
#
#    Rules currently match exact app-id and title strings. Missing:
#    pattern matching (regex or glob on title), more actions beyond
#    :float and :tag (e.g., :sticky, :output, :column, :col-width),
#    and negative matches.
#
#    Also: rules only fire on window creation. A "re-evaluate rules"
#    action would be useful for windows whose title changes (e.g.,
#    browser tabs).
#
# 5. IPC beyond netrepl
#
#    netrepl is powerful but requires Janet. A simpler command
#    protocol (read lines from a socket, dispatch to actions) would
#    let shell scripts and external tools interact with tidepool.
#    Could coexist with netrepl — same socket, detect Janet vs.
#    line protocol by first byte.
#
# Things considered and deferred:
#
#   - Layout composition (master-stack where stack is scroll): adds
#     complexity for a niche use case. Better to make individual
#     layouts good enough.
#
#   - Dynamic tag creation (tags beyond 1-9): 9 tags + scratchpad
#     is enough. Pools solve the "not enough tags" feeling without
#     needing more tags.
#
#   - Per-output tag namespaces: breaks the global tag model that
#     makes cross-output tag operations simple. Not worth it.

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
