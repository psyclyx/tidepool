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
    "wl_shm" 1
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
# Design principle: tidepool provides primitives, user config builds
# abstractions. "Project" is a config concept, not a WM concept.
# Janet config = full language for user-side abstractions.
#
# What works:
#   - Per-tag layout save/restore
#   - Scroll layout as daily driver (columns, struts, variable widths)
#   - State persistence (tags, columns, layouts survive restarts)
#   - File-based IPC to waybar (per-output tag/layout files)
#
# --- Groups: unifying tags, pools, and scratchpad ---
#
# Current model: tags are integers 1-9, scratchpad is tag 0 (special),
# pools were proposed as named sets of tags. Three concepts for what
# is really one thing: a visibility group.
#
# Observation: tags and pools are the same abstraction at different
# granularities. A tag is "show these windows." A pool is "show
# these tags" = "show these windows." Scratchpad is "a tag that's
# toggled instead of focused" — also just a visibility group.
#
# Proposed: collapse to one concept — groups.
#
#   - A window belongs to one group
#   - An output shows a set of groups
#   - Groups are any hashable value (keyword, integer, gensym)
#   - Named groups (:a, :code, :comms) — stable, bound to keys
#   - Anonymous groups — created on demand, GC'd when empty
#
# Named groups replace tags. No fixed count — you define what you
# use. Super+asdf for 4 groups, or super+1-9 for 9, or whatever.
# Anonymous groups replace "unused tag numbers" — need a new
# workspace? Create one. Done with it? Windows leave, it vanishes.
# Scratchpad isn't special — it's just a group you toggle.
#
# Keybinding story:
#   super+a..d    focus named group (like current focus-tag)
#   super+n       new anonymous group, move focused window to it
#   super+tab     cycle groups with windows (MRU or ordered)
#   super+shift+  send window to group (like current set-tag)
#
# What changes internally: almost nothing. show-hide, layout, and
# persist use the group identifier where they currently use an
# integer tag. The machinery doesn't care if it's :a or 3 or a
# gensym. Tag-layout save/restore keys on group id instead of int.
#
# What this unlocks for user config:
#
#   # Per-project groups with summon
#   (def projects
#     @{:tidepool {:group :tp :dir "~/projects/tidepool"}
#       :privclyx {:group :px :dir "~/projects/privclyx"}})
#
#   (defn project-lazygit [project-key]
#     (def p (projects project-key))
#     (action/summon
#       |(string/has-prefix? (string "git-" (p :group)) ($ :title))
#       ["foot" "-T" (string "git-" (p :group)) "-D" (p :dir) "lazygit"]
#       {:float true}))
#
# The user defines what "project" means. Tidepool just provides
# groups and summon. Named groups give stable context. Summon
# gives context-sensitive window management.
#
# Migration: existing integer tags work as-is (integers are
# hashable). Config that uses (focus-tag 1) keeps working.
# New config can use keywords. No breaking change.
#
# Open questions:
#   - Group ordering: named groups have config-defined order.
#     Anonymous groups ordered by creation time? MRU?
#   - Bar integration: indicator writes group ids to files.
#     Waybar script needs to handle keywords, not just ints.
#   - Should outputs show at least one group always, or can
#     an output be "empty"?
#
# --- Other missing primitives ---
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
# 2. Summon (find-or-spawn + toggle)
#
#    Find a window matching a predicate; if found, toggle it (bring
#    to current group / dismiss); if not found, optionally spawn it.
#    Predicate is any Janet function — user config controls matching.
#
#    (action/summon |(= ($ :app-id) "lazygit") ["foot" "lazygit"])
#
#    Toggle semantics: "show" = move to current group, float, focus.
#    "dismiss" = send back to :summon-home (the group it came from).
#    Subsumes scratchpad: (action/summon |(= ($ :group) :scratch) nil)
#
# 3. Sticky windows
#
#    :sticky flag — window visible regardless of group membership.
#    Floating only (excluded from tiling). Useful for media, chat.
#
# 4. Window rules improvements
#
#    Pattern matching (functions as predicates), more actions (:sticky,
#    :group, :column, :col-width), re-evaluate on title change.
#
# Things deferred:
#
#   - IPC beyond netrepl: Janet IPC is the natural fit for a Janet
#     WM. File-based IPC covers the bar.
#
#   - Layout composition: better to make individual layouts good.
#
#   - Per-output group namespaces: breaks the global model that
#     makes cross-output operations simple.

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
