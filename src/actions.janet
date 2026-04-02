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
  "Return an action that switches the focused output to a tag.
   If another output already shows that tag, focus moves there instead."
  [tag]
  (fn [ctx s]
    (when-let [o (s :focused-output)]
      (def other (find |(and (not= $ o) (($ :tags) tag))
                       (ctx :outputs)))
      (if other
        (seat/focus-output s other)
        (output/set-tags o {tag true})))))

(import ./tree)
(import ./state)

(defn send-to-tag
  "Return an action that moves the focused window to a tag."
  [tag]
  (fn [ctx s]
    (when-let [w (s :focused)
               leaf (w :tree-leaf)]
      (def old-tag-id (w :tag))
      (when (= old-tag-id tag) (break))
      (def old-tag (get-in ctx [:tags old-tag-id]))
      # Remove from old tag's tree
      (when old-tag
        (def columns (old-tag :columns))
        (def col-idx (tree/find-column-index columns leaf))
        (def child-idx (or (tree/child-index leaf) 0))
        (def [col-removed result] (tree/remove-leaf columns leaf))
        # Update old tag's focus
        (when (= (old-tag :focused-id) w)
          (def successor (tree/focus-successor columns
                           (or col-idx 0) child-idx
                           (if col-removed nil result)))
          (if successor
            (do (put old-tag :focused-id (successor :window))
                (tree/update-active-path successor))
            (put old-tag :focused-id nil))))
      # Move window to new tag
      (put w :tag tag)
      # Insert into new tag's tree
      (def new-tag (state/ensure-tag ctx tag))
      (tree/insert-column (new-tag :columns) (length (new-tag :columns)) leaf)
      (put new-tag :focused-id w)
      (tree/update-active-path leaf)
      # Clear position so layout recomputes
      (put w :x nil)
      (put w :y nil))))
