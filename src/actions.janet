# Public action API. All keybindings reference this module.
# Re-exports scroll-actions and adds tag/spawn actions.

(import ./scroll-actions)
(import ./output)
(import ./seat)

# --- Directional focus ---
(def focus-left scroll-actions/focus-left)
(def focus-right scroll-actions/focus-right)
(def focus-up scroll-actions/focus-up)
(def focus-down scroll-actions/focus-down)

# --- Directional swap ---
(def swap-left scroll-actions/swap-left)
(def swap-right scroll-actions/swap-right)
(def swap-up scroll-actions/swap-up)
(def swap-down scroll-actions/swap-down)

# --- Join / Leave ---
(def join-left scroll-actions/join-left)
(def join-right scroll-actions/join-right)
(def join-up scroll-actions/join-up)
(def join-down scroll-actions/join-down)
(def leave scroll-actions/leave)

# --- Tabs ---
(def focus-tab-next scroll-actions/focus-tab-next)
(def focus-tab-prev scroll-actions/focus-tab-prev)
(def make-tabbed scroll-actions/make-tabbed)
(def make-split scroll-actions/make-split)
(def make-horizontal scroll-actions/make-horizontal)
(def make-vertical scroll-actions/make-vertical)

# --- Width ---
(def cycle-width-forward scroll-actions/cycle-width-forward)
(def cycle-width-backward scroll-actions/cycle-width-backward)

# --- Insert mode ---
(def toggle-insert-mode scroll-actions/toggle-insert-mode)

# --- Close ---
(def close-focused scroll-actions/close-focused)

# --- Spawn ---
(def spawn scroll-actions/spawn)

# --- Tag management ---

(defn focus-tag
  "Return an action that switches the focused output to a tag."
  [tag]
  (fn [ctx s]
    (when-let [o (s :focused-output)]
      (output/set-tags o {tag true}))))

(defn send-to-tag
  "Return an action that moves the focused window to a tag."
  [tag]
  (fn [ctx s]
    (when-let [w (s :focused)]
      (put w :tag tag))))
