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
#   - Janet config = full language for user-side abstractions
#
# Design principle: tidepool provides primitives, user config builds
# abstractions. "Project" is a config concept, not a WM concept.
# Tags, summon, and focus history are the right primitives — pools
# and projects are patterns users compose from them.
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
# 2. Summon (find-or-spawn + toggle)
#
#    The missing primitive for scratchpads, project tools, and
#    context-sensitive window management. Find a window matching a
#    predicate; if found, toggle it (bring to current tag / dismiss);
#    if not found, optionally spawn it.
#
#    (defn summon [pred spawn-cmd &opt opts]
#      (fn [seat binding]
#        (if-let [w (find pred (state/wm :windows))]
#          (toggle-summon seat w opts)
#          (when spawn-cmd (spawn-it spawn-cmd)))))
#
#    The predicate is any Janet function. This is what makes it
#    composable — user config provides the matching logic:
#
#    # Simple: global lazygit scratchpad
#    (action/summon |(= ($ :app-id) "lazygit") ["foot" "lazygit"])
#
#    # Context-sensitive: per-tag lazygit
#    (defn project-git [seat binding]
#      (def tag (primary-tag (seat :focused-output)))
#      (def dir (get my-project-dirs tag))
#      (when dir
#        ((action/summon
#           |(and (= ($ :app-id) "foot")
#                 (string/has-prefix? (string "git-" tag) ($ :title)))
#           ["foot" "-T" (string "git-" tag) "-D" dir "lazygit"]
#           {:float true})
#         seat binding)))
#
#    Toggle semantics: "show" = set window's tag to current tag,
#    float it, focus it. "dismiss" = send it to scratchpad tag (0)
#    or its original tag. Window remembers :summon-home (the tag it
#    was on before being summoned) so dismiss sends it back.
#
#    This subsumes the current scratchpad. toggle-scratchpad becomes:
#      (action/summon |(= ($ :tag) 0) nil)
#    But more useful — any window can be summoned by any predicate.
#
#    Summon is the key primitive that makes "project" possible at
#    the config level without tidepool knowing what a project is.
#    Tags provide context (which tag am I on). Summon provides
#    the action (bring me this window). User config maps context
#    to action however they want.
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
#    and negative matches. Rules could also accept Janet functions
#    as predicates, matching the summon pattern.
#
#    Also: rules only fire on window creation. A "re-evaluate rules"
#    action would be useful for windows whose title changes (e.g.,
#    browser tabs).
#
# Things considered and deferred:
#
#   - Pools (named tag groups): focus-pool "code" activates tags
#     1-3. Nice sugar, but not a primitive — it's just focus-tag
#     for multiple tags. Easy to build in user config with a Janet
#     table + loop. May add as a built-in action later if the
#     pattern proves common enough.
#
#   - IPC beyond netrepl: the WM is configured via Janet, so Janet
#     IPC (netrepl) is the natural fit. File-based IPC covers the
#     bar. Shell scripts can use netrepl via janet -e. A simpler
#     line protocol isn't worth the complexity right now.
#
#   - Layout composition (master-stack where stack is scroll): adds
#     complexity for a niche use case. Better to make individual
#     layouts good enough.
#
#   - Dynamic tag creation (tags beyond 1-9): 9 tags + scratchpad
#     is enough. Summon + per-tag context covers the "not enough
#     tags" feeling without needing more tags.
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
