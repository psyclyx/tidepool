# Pools: Recursive Group Architecture

## Executive Summary

Replace tidepool's named layout algorithms (master-stack, dwindle, grid, centered-master, monocle, scroll) with a single recursive concept: **pools**. A pool is a group of children (windows or other pools) with a **mode** that determines how children are arranged. Four modes cover all current layouts and composable combinations thereof: `scroll`, `stack-h`, `stack-v`, and `tabbed`.

Tags become pools. Columns become pools. Tabbed groups become pools. "Master-stack" is a `stack-h` pool with two `stack-v` children. The user builds layouts by grouping, splitting, and changing modes — not by selecting named algorithms.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Core Concepts](#2-core-concepts)
3. [Pool Modes](#3-pool-modes)
4. [The Tree](#4-the-tree)
5. [Rendering](#5-rendering)
6. [Navigation](#6-navigation)
7. [User Interaction Model](#7-user-interaction-model)
8. [Actions Reference](#8-actions-reference)
9. [Window Routing](#9-window-routing)
10. [Animation](#10-animation)
11. [Persistence](#11-persistence)
12. [IPC](#12-ipc)
13. [River Integration](#13-river-integration)
14. [Config Migration](#14-config-migration)
15. [Implementation Plan](#15-implementation-plan)
16. [Data Structures](#16-data-structures)
17. [File Changes](#17-file-changes)
18. [Test Strategy](#18-test-strategy)

---

## 1. Motivation

### What's wrong now

The current system has 6 named layout algorithms, each implemented as an independent pure function. This worked well for static layouts but breaks down when users want composition:

1. **Sublayouts are bolted onto scroll.** Scroll became a meta-layout that delegates to other layouts within columns. This makes scroll privileged and complex (~570 lines), violating "don't privilege any layout."

2. **Named layouts can't compose.** You can't put a grid inside a master-stack. You can't have a tabbed group inside a dwindle. Composition only exists within scroll, and only as a special case.

3. **Tags are a separate concept from groups.** But they're really just "groups of windows the user can show/hide." The tag switching code, the layout code, and the column code all implement grouping independently.

4. **6 layout algorithms share patterns but not code.** Every layout computes padding, divides space, handles navigation. The patterns are the same; the implementations are independent.

### What pools give us

- **One concept instead of many.** Pool modes (scroll, stack-h, stack-v, tabbed) replace 6 layouts + tabs + strips + sublayouts.
- **Composition is structural.** Any pool can contain any pool. No special cases.
- **Tags collapse into the model.** A tag is a pool. Tag switching is just "which child of the output pool is active."
- **User agency.** Users construct layouts by grouping windows and choosing modes, not by selecting from a fixed menu.

---

## 2. Core Concepts

### Pool

A pool is a table with a `:parent` back-pointer for O(1) tree traversal:

```janet
@{:mode :stack-v          # :scroll | :stack-h | :stack-v | :tabbed
  :children @[...]        # array of windows or pools
  :parent <pool-or-nil>   # back-pointer to parent (nil for root)
  :active 0               # index of visible child (tabbed mode)
  :ratio 0.55             # split ratio (stack-h/stack-v with 2 children)
  :weights @{}            # per-child weight overrides (index -> weight)
  :active-row 0           # visible row index (scroll mode)
  :scroll-offset-x @{}    # per-row horizontal scroll state {row-idx offset}
  :scroll-offset-y 0      # vertical offset for row transitions (scroll mode)
  :width 0.5              # this pool's width ratio (when child of scroll)
  :id :main               # stable identity for pool targeting/persistence (user-defined)
  :presets [0.5 0.7 1.0]  # width presets for cycling (optional)
  }
```

### Back-pointers

Every pool and every window in the tree has a `:parent` back-pointer to its containing pool. This is maintained by all tree mutation functions (`insert-child`, `remove-child`, `wrap-children`, `unwrap-pool`, `move-child`). Back-pointers enable:
- O(1) parent lookup (for border computation, mode detection)
- O(depth) `find-path` (walk up from focused window to root)
- O(1) "am I in a tabbed pool?" check for border colors

**Invariant:** After every tree mutation, `(child :parent)` equals the pool containing that child. Violation is a bug. Validation runs in debug mode.

### Window

Windows remain tables with compositor state. Layout properties (`:column`, `:col-width`, `:col-weight`, `:col-mode`, `:col-active`, `:strip`, `:strip-weight`, `:col-sublayout`, `:col-sublayout-params`) are **removed entirely**. The pool tree replaces them.

A window's position in the tree fully determines its layout behavior. No redundant properties, no per-frame normalization.

Windows retain `:tag` for bookkeeping, but it is **derived** from the tree — see Section 13 (River Integration) for the synchronization pass.

### Mode

Four modes, each defining how a pool arranges its children:

| Mode | Arrangement | Scroll | Use cases |
|------|------------|--------|-----------|
| `scroll` | 2D grid: rows × columns, one row visible, horizontal scroll within | Yes, both axes | Main workspace layout (replaces scroll layout) |
| `stack-h` | Divide width among children by ratio/weight | No | Side-by-side splits (replaces master-stack, centered-master) |
| `stack-v` | Divide height among children by ratio/weight | No | Vertical stacking (replaces column rows) |
| `tabbed` | Show one child, hide rest | No | Tabs (replaces col-mode :tabbed, monocle) |

---

## 3. Pool Modes

### 3.1 `scroll`

2D grid of **rows × columns**. One row is visible at a time. Within the visible row, columns scroll horizontally. Vertical scrolling switches between rows.

**Structure:** A scroll pool's direct children are **rows**. Each row's children are **columns** (windows or pools). Rows are independent — each has its own set of columns with their own widths. A column occupies the full viewport height (it can be subdivided internally via `stack-v`, `tabbed`, etc., but it doesn't overflow).

Each column can be a single window, a `stack-v` of windows, a `tabbed` group, a `stack-h` split — anything. Columns are viewport-height; internal subdivision divides that height, it doesn't extend past it.

**Scroll-specific pool properties:**
- `:active-row` — index of the currently visible row (animated vertical transitions)
- `:scroll-offset-x` — per-row horizontal scroll state (table: `{row-index offset}`)
- `:scroll-offset-y` — vertical scroll offset for animated row transitions
- `:width` on columns — column width as ratio of viewport (default from config)

**Rows:** Each row is a pool whose children are columns. Scroll manages the horizontal column layout of each row — the row's `:mode` is not used for rendering (scroll handles it). Rows are structural containers for grouping columns. A new scroll workspace starts with one row; rows are added/removed via actions.

**Simplification vs. old model:** The old `column-row-height` / per-column `scroll-y` / vertical peek behavior is replaced by a clean row model. Each row is an independent horizontal scroll strip. No per-column overflow — columns are viewport-height. Vertical expansion means adding rows, not overflowing columns.

**Rendering:** For the active row: compute column x-positions from child `:width` values. Animate horizontal scroll offset to keep focused column visible (with peek at edges). Clip off-screen columns. Recurse into each visible column with its rect (full viewport height). For row transitions: animate `:scroll-offset-y` when `:active-row` changes, cross-fading between rows.

### 3.2 `stack-h`

Divide width among children proportionally. With 2 children and a `:ratio`, the first child gets `ratio * width`, the second gets the rest (master-stack pattern). With 3+ children, divide by weight (`:weights` table, default 1.0 per child).

**Replaces:** master-stack (stack-h with 2 children: one window + one stack-v), centered-master (stack-h with 3 children: stack-v + window + stack-v), and horizontal splits within scroll columns.

### 3.3 `stack-v`

Divide height among children proportionally. Same ratio/weight semantics as `stack-h` but vertical.

**Replaces:** vertical stacking within scroll columns (current default column behavior), and can replicate dwindle (nested alternating stack-h/stack-v).

### 3.4 `tabbed`

Show the child at index `:active`, hide the rest. Children can be windows or pools (a tab can contain a complex layout).

**Replaces:** `:col-mode :tabbed`, monocle layout, and — crucially — **tags**. The output-level pool that holds tags is a `tabbed` pool (with multi-active for viewing multiple tags simultaneously).

---

## 4. The Tree

### Structure

```
output
  +-- tabbed (the "tag pool" -- :active selects visible tag)
       +-- scroll (:main)                     [keybind: Mod+1]
       |    +-- row 0 (active row)
       |    |    +-- stack-v (column 1)
       |    |    |    +-- window (terminal)
       |    |    |    +-- window (terminal)
       |    |    +-- window (column 2 -- bare window, no wrapper needed)
       |    |    +-- tabbed (column 3)
       |    |         +-- window (browser tab 1)
       |    |         +-- window (browser tab 2)
       |    |         +-- window (browser tab 3)
       |    +-- row 1
       |         +-- window (scratch terminal)
       +-- scroll (:web)                      [keybind: Mod+2]
       |    +-- row 0
       |         +-- window (editor)
       +-- stack-h (:media -- master-stack)   [keybind: Mod+3]
       |    +-- window (master -- left side)
       |    +-- stack-v (stack -- right side)
       |         +-- window (terminal)
       |         +-- window (htop)
```

Scroll pools are 2D grids: rows × columns. One row is visible at a time, with horizontal scrolling within it. Moving between rows is like changing floors — each row is an independent workspace strip. Most users will have a single row per tag, but rows give you vertical expansion when you need it.

### Depth conventions

The tree is typically 4-6 levels deep:

1. **Output pool** (tabbed) — one per physical monitor
2. **Tag pools** — children of the output pool
3. **Row pools** (scroll tags only) — rows within a scroll tag
4. **Group pools** — columns, splits, tabbed groups within a row
5. **Windows** — leaves

Levels 2-3 often merge: a tag pool's children are directly the windows/groups.

### No wrapper requirement

A pool with one child that is a window can be simplified: the window IS the child, no intermediate pool needed. A `scroll` pool can have bare windows as children (they're treated as single-window columns). Pool wrappers are created on demand when the user groups things.

### Auto-unwrap policy

When a pool reaches 1 child after a removal, it MAY auto-unwrap (replace itself with its sole child in the parent). The policy:

- **Tag pools never unwrap.** Even an empty tag persists.
- **Pools with non-default mode preserve themselves.** A `tabbed` pool with 1 child stays `tabbed` — the user explicitly chose that mode and may add more children. A `stack-h` with a configured `:ratio` stays. Only a `stack-v` with default weights (the implicit wrapper created by consume) auto-unwraps.
- **Rationale:** Unwrapping `tabbed` or configured pools destroys user intent. The current system preserves `:col-mode :tabbed` on single-window columns for this reason.

### Tag pools and visibility

Each tag is a child of the output's tabbed pool. Tidepool owns window visibility entirely — river has no tag bitmask. Tidepool calls `:show`/`:hide` on windows.

- When the user presses Mod+1, tidepool sets `:active 0` on the output pool
- Visible windows are those reachable through "active" paths in the tree (not hidden by any tabbed ancestor)
- A tag synchronization pass stamps `:tag <pool-id>` on each window based on its position in the tag tree, keeping the window property consistent for IPC and other consumers

**Multi-pool view:** When multiple pools are toggled visible (`toggle-pool`), the output pool enters **multi-active** mode: multiple children are marked active. Rendering treats the output pool as a temporary `stack-v` of the active pools — each visible pool gets a horizontal strip of the output. This replaces the "strips" concept from the old design. The relative heights of strips default to equal, but can be adjusted with `resize`.

This is a behavioral change from the current system (which merges windows from multiple tags into one flat layout). The new behavior is more predictable: each tag retains its own layout when viewed alongside other tags.

---

## 5. Rendering

### Algorithm

Rendering is recursive. Each pool mode has a render function:

```janet
(defn render-pool
  "Render a pool into a bounding rect. Returns {:placements [...] :animating bool}."
  [pool rect config focused now]
  (case (pool :mode)
    :scroll  (render-scroll pool rect config focused now)
    :stack-h (render-stack pool rect config focused now :h)
    :stack-v (render-stack pool rect config focused now :v)
    :tabbed  (render-tabbed pool rect config focused now)))
```

Each render function:
1. Computes child rects (how to divide the parent rect among children)
2. For window children: emits `{:window w :x :y :w :h}` placements
3. For pool children: recursively calls `render-pool`
4. Returns `{:placements [...] :animating bool}` — the `:animating` flag bubbles up so the pipeline knows to request another frame

### Validation

Before rendering, each mode validates its state:
- `render-tabbed`: clamp `:active` to `[0, (- (length children) 1)]`
- `render-scroll`: clamp `:active-row`, ensure `:scroll-offset-x` is a table, `:scroll-offset-y` is numeric
- `render-stack`: ensure `:ratio` is in `[0.1, 0.9]` if present

This prevents crashes from transient inconsistency (e.g., `:active` pointing past the end after a child removal).

### `render-stack`

```
(render-stack pool rect config focused now axis)
```

Divides `rect` along `axis` (`:h` = horizontal, `:v` = vertical) among children:
- 2 children + `:ratio`: first child gets `ratio * extent`, second gets rest
- N children: divide by weight (each child's weight from `(pool :weights)` / total weight, default 1.0)
- Apply inner padding between children
- Recurse into each child with its sub-rect

### `render-scroll`

2D grid of rows × columns. Simpler than the current `scroll/layout` (~570 lines → ~170 lines) because columns are explicit children (no `group`/`assign`/`normalize` pipeline), rows replace per-column vertical overflow, and there's no `column-row-height` config.

Algorithm:
- Determine `:active-row` (clamp to valid range)
- Get the active row's children (columns)
- Each column has a `:width` ratio (default from config `:column-width`)
- Compute column x-positions from widths; total content width
- Each column gets the **full viewport height** (subdivided internally by the column's own mode)
- Animate horizontal scroll offset for this row to keep focused column visible (with peek at edges)
- For each column: compute rect, check if off-screen horizontally
  - Off-screen: emit `{:hidden true}` for all windows in the subtree
  - On-screen: recurse into column with its rect (full viewport height)
- All non-active rows: emit `{:hidden true}` for all their windows
- When `:active-row` changes, animate `:scroll-offset-y` for a vertical transition

The key simplification vs. current code: no per-column scroll state, no `column-row-height` config, no per-column vertical overflow. Rows are explicit children of scroll, columns are explicit children of rows. Vertical expansion = add rows, not overflow columns.

### `render-tabbed`

Render only the child at index `:active`. All other children's windows get `{:hidden true}` placements (collected by walking the hidden subtrees).

### Padding

`padded-rect` applies outer padding at the **tag level** (the first pool under the output). Inner pools use inner padding between children. Sublayout pools (pools nested inside scroll columns) inherit the column's bounds with zero additional outer padding — this falls out naturally from the recursion.

### Scroll-placed flag

Any window rendered by or beneath a `scroll` pool gets `:scroll-placed true`. This flag controls clipping behavior (scroll-placed windows use output-edge clipping instead of padding-inset clipping). The render function propagates this through recursion.

---

## 6. Navigation

### Principle

Navigation is **geometric + structural**. Within a pool, navigation follows the pool's spatial arrangement. At pool boundaries, navigation bubbles up to the parent and crosses to an adjacent child.

### Algorithm

```janet
(defn navigate
  "Navigate from the focused window in a direction. Returns target window or nil."
  [root focused dir]
  (navigate-from root focused dir))
```

Uses `:parent` back-pointers to walk up from the focused window:

1. At the innermost pool, try to navigate within it (mode-specific)
2. If navigation returns nil (hit an edge), walk up via `:parent` to the containing pool
3. At the parent, try to navigate to an adjacent child in `dir`
4. If entering a new child pool, descend into it (pick the edge-closest window)
5. If bubbling reaches the tag pool with no result, fall back to geometry-based navigation

### Per-mode navigation

**`stack-h`:**
- `:left`/`:right` → move to adjacent child (or bubble up)
- `:up`/`:down` → bubble up immediately (no vertical relationship at this level)

**`stack-v`:**
- `:up`/`:down` → move to adjacent child (or bubble up)
- `:left`/`:right` → bubble up immediately

**`scroll`:**
- `:left`/`:right` → move to adjacent column within the active row (or bubble up)
- `:up`/`:down` → first try to navigate within the focused column's child pool. If that bubbles up to the row level, switch to the adjacent row (`:active-row` ± 1). When entering a new row, focus the last column (from above) or first column (from below). If no adjacent row, bubble up.

**`tabbed`:**
- `:up`/`:down` → cycle active tab (wrapping). Never bubbles — tab cycling is self-contained.
- `:left`/`:right` → bubble up (tabs are spatially stacked, left/right exits the tabbed group)

### Entering a pool from outside

When navigation crosses into a new child pool, we need to pick which window to focus:
- **`stack-h`/`stack-v`**: pick the child closest to the entry direction. Coming from the left into a `stack-h`? Pick the leftmost child. Coming from above into a `stack-v`? Pick the topmost.
- **`scroll`**: pick the column closest to where we came from
- **`tabbed`**: always pick the active tab's window

### Nested scroll restriction

`set-mode :next` skips `scroll` when the parent or any ancestor is already a `scroll` pool. Nested scroll-within-scroll would create competing horizontal scroll regions and confusing input behavior.

### Geometry fallback

If structural navigation yields no result at the tag level, use `navigate-by-geometry` on the flat placement results. This ensures the user can always navigate to any visible window regardless of tree complexity.

---

## 7. User Interaction Model

### Design principle

Every action works the same regardless of what pool mode you're in. There are no scroll-specific actions, no tag-specific actions. The 13 core actions compose uniformly across the entire tree.

### Core actions (13 total)

| Action | What it does | Suggested keybind |
|--------|-------------|-------------------|
| **focus** dir | Navigate focus directionally | Mod+h/j/k/l |
| **swap** dir | Move window in direction | Mod+Shift+h/j/k/l |
| **consume** dir | Pull adjacent sibling into your group | Mod+Ctrl+h/l |
| **expel** | Leave current group, insert into grandparent | Mod+Ctrl+j |
| **resize** delta | Context-sensitive resize | Mod+[/] |
| **set-mode** mode &opt target | Change pool mode (`:parent` or `:tag`) | Mod+t / Mod+Tab |
| **cycle-preset** | Apply next named layout preset | Mod+Shift+Tab |
| **zoom** | Promote to first position | Mod+Space |
| **focus-pool** id | Activate child pool by id (= tag switching) | Mod+1-9 |
| **send-to-pool** id | Move window to pool by id (= send to tag) | Mod+Shift+1-9 |
| **toggle-pool** id | Toggle pool visibility (= toggle tag) | Mod+Ctrl+1-9 |
| **focus-last** | Focus previously focused window | Mod+Backspace |
| **float** | Toggle floating | Mod+f |
| **fullscreen** | Toggle fullscreen | Mod+Shift+f |
| **close** | Close window | Mod+q |

Note: `spawn` is config-level (keybinds call shell commands directly). `fullscreen` and `close` are window lifecycle, not pool manipulation, but listed for completeness.

### How actions generalize across modes

**`swap`** at a pool boundary moves the window into the adjacent container. Within a `stack-v`, `swap :down` exchanges with the sibling below. At the bottom edge, it bubbles up — in a scroll row, that means moving to the next row. In a `stack-h`, swap left/right exchanges siblings; at the edge, it bubbles to the parent. No special-case code for rows, columns, or tags.

**`resize`** figures out what to adjust from context:
- In scroll: column width (`:width` ratio)
- In stack-h/stack-v with 2 children: `:ratio`
- In stack-h/stack-v with 3+ children: child weight in `:weights`
- In multi-tag view: tag strip height
- `(resize :reset)` resets weights/ratios (= equalize)
- `(resize :cycle)` cycles through width presets (scroll columns)

**`set-mode`** targets the focused window's immediate parent pool by default. `(set-mode :tabbed :tag)` targets the tag-level pool. `(set-mode :next)` and `(set-mode :next :tag)` cycle modes. This replaces the old `set-mode`/`set-tag-mode`/`cycle-mode`/`cycle-tag-mode` — one action, optional target.

**`focus-pool`**, **`send-to-pool`**, **`toggle-pool`** operate on pool ids. Tags are just pools with ids that the user defined in config and bound to keys. There are no hardcoded tag numbers — the user creates pools and binds them:

```janet
# User config creates their workspace pools:
(def pools [:main :web :media :scratch])
(each-with-index [i pool] pools
  (bind (+ i 1) {:mod4 true} (action/focus-pool pool))
  (bind (+ i 1) {:mod4 true :shift true} (action/send-to-pool pool))
  (bind (+ i 1) {:mod4 true :ctrl true} (action/toggle-pool pool)))
```

### How named layouts emerge

Users don't pick "master-stack" from a menu. Instead:

**Master-stack:** `Mod+Shift+Tab` to cycle presets → picks `master-stack`. Or: `Mod+Tab` to set tag mode to `stack-h`, then `consume` to group windows.

**Monocle:** `Mod+Tab` to set tag mode to `tabbed`.

**Tabbed column:** `Mod+Ctrl+h` to consume neighbor, `Mod+t` to change column mode to `tabbed`.

**Grid:** `Mod+Shift+Tab` to cycle presets → picks `grid`.

### Layout presets

Presets construct a pool tree from the current tag's windows. They are **convenience functions** — the result is a normal pool tree that the user can then modify.

```janet
(defn preset-scroll [windows]
  "Each window is a scroll column in a single row."
  @{:mode :scroll :children @[@{:children (array ;windows)}]})

(defn preset-master-stack [windows config]
  "First window is master (left), rest are stacked (right)."
  @{:mode :stack-h :ratio (config :main-ratio)
    :children @[(first windows)
                @{:mode :stack-v :children (tuple/slice windows 1)}]})

(defn preset-monocle [windows]
  "All windows tabbed, first is active."
  @{:mode :tabbed :active 0 :children (array ;windows)})

(defn preset-grid [windows]
  "Balanced grid: stack-v of stack-h rows."
  (def n (length windows))
  (def cols (math/ceil (math/sqrt n)))
  (def rows @[])
  (var i 0)
  (while (< i n)
    (def row-end (min n (+ i cols)))
    (def row-wins (tuple/slice windows i row-end))
    (array/push rows
      (if (= (length row-wins) 1) (first row-wins)
        @{:mode :stack-h :children (array ;row-wins)}))
    (set i row-end))
  (if (= (length rows) 1) (first rows)
    @{:mode :stack-v :children rows}))
```

Presets are cycled with `Mod+Shift+Tab`. The cycle: scroll → master-stack → monocle → grid → scroll.

### Mode targeting

`set-mode` takes an optional target level:

- **`(set-mode :tabbed)`**: Changes the focused window's **immediate parent pool**.
- **`(set-mode :tabbed :tag)`**: Changes the **tag-level pool** (the focused tag). Equivalent of old `cycle-layout`.
- **`(set-mode :next)`** / **`(set-mode :next :tag)`**: Cycle to next mode.

This replaces four old actions (`set-mode`, `cycle-mode`, `set-tag-mode`, `cycle-tag-mode`) with one.

---

## 8. Actions Reference

### Directional primitives

```janet
(defn focus [dir]
  "Navigate focus in direction (:left :right :up :down).
  Uses structural navigation (per-mode rules + bubble-up at boundaries)
  with geometry fallback at the tag level."
  ...)

(defn swap [dir]
  "Move focused window in direction. Within a pool, exchanges position
  with adjacent sibling. At pool boundaries, moves into the adjacent
  container (e.g., across scroll rows, between stack children).
  Positional: weights/widths stay with the position, not the window."
  ...)

(defn consume [dir]
  "Pull the adjacent sibling in `dir` into the focused window's parent pool.
  If focused is a bare window (direct child of a row), wraps it in a stack-v
  first, then absorbs the neighbor. No-op if no adjacent sibling."
  ...)

(defn expel []
  "Move focused window out of its current pool into the grandparent pool.
  No-op at the row/tag level (cannot expel from top-level containers).
  If this leaves the parent pool with one child and the parent has default
  mode/config, auto-unwrap the parent."
  ...)
```

### Resize

```janet
(defn resize [delta]
  "Context-sensitive resize. `delta` is a number, :reset, or :cycle.
  Numeric: adjust the focused child's size within its parent pool.
    - scroll column: adjusts :width ratio
    - stack-h/stack-v (2 children): adjusts :ratio
    - stack-h/stack-v (3+ children): adjusts child weight in :weights
    - multi-tag view: adjusts tag strip height
  :reset — reset all weights/ratios in the parent pool to defaults.
  :cycle — cycle through width presets (scroll columns)."
  ...)
```

### Mode and presets

```janet
(defn set-mode [mode &opt target]
  "Set pool mode. `mode` is :scroll, :stack-h, :stack-v, :tabbed, :next, or :prev.
  `target` is :parent (default) or :tag.
  :parent — changes the focused window's immediate parent pool.
  :tag — changes the tag-level pool.
  :next/:prev cycle through modes. Skips :scroll if an ancestor is already scroll."
  ...)

(defn cycle-preset [&opt dir]
  "Apply the next layout preset to the focused tag's windows.
  Cycle: scroll -> master-stack -> monocle -> grid -> scroll.
  dir is :next (default) or :prev."
  ...)
```

### Pool targeting

```janet
(defn focus-pool [id]
  "Activate the child pool with :id `id` on the focused output.
  This IS tag switching — 'tags' are just pools the user gave ids to."
  ...)

(defn send-to-pool [id]
  "Move focused window to the pool with :id `id`. Removes from current
  position in the tree, inserts at the end of the target pool's active row
  (scroll) or children (other modes)."
  ...)

(defn toggle-pool [id]
  "Toggle visibility of pool `id` on the focused output. When multiple
  pools are visible, the output renders as stack-v of strips."
  ...)
```

### Other

```janet
(defn zoom []
  "Move focused window to first position in the nearest scroll row
  or tag-level pool."
  ...)

(defn focus-last []
  "Focus the previously focused window."
  ...)

(defn float []
  "Toggle floating. Float: removes window from pool tree.
  Unfloat: inserts back at the focused position."
  ...)

(defn fullscreen []
  "Toggle fullscreen."
  ...)

(defn close []
  "Close focused window. Pool tree auto-prunes per the unwrap policy."
  ...)
```

---

## 9. Window Routing

### Insertion rule

When a new window appears:

1. Find the focused window's position in the tree
2. Insert the new window as a sibling **after** the focused window in the same parent pool
3. **Exception:** if the focused window's parent is a `tabbed` pool, insert as a new tab and optionally switch to it

This means a new window in a scroll tag appears as a new column next to the focused column. A new window spawned while focused inside a `stack-v` column appears as a new row in that column.

**Rationale:** Inserting into the immediate parent is the most intuitive behavior — the new window appears "next to" the focused one. Users who want new windows to always appear as new scroll columns can bind spawn to a function that inserts at the tag level.

### Removal rule

When a window closes:

1. Remove it from its parent pool
2. **Auto-unwrap check:** If the parent pool has 1 child remaining:
   - If the pool is a tag pool: keep it (tags never unwrap)
   - If the pool has non-default mode (`:tabbed`, or `stack-h` with custom `:ratio`): keep it — user intent is preserved
   - If the pool is a `stack-v` with default weights (the implicit wrapper from consume): unwrap it, replacing the pool with its sole child in the grandparent
3. **Empty check:** If the parent pool has 0 children and is not a tag pool, remove it (recursive up)
4. In `tabbed` mode: if the active tab closes, activate the adjacent tab (prefer `(min active (- (length children) 1))` — i.e., stay at the same index or move left)

### Float/unfloat

- **Float:** Remove window from pool tree. Window becomes unmanaged by layout.
- **Unfloat:** Insert window back into tree at the focused position (same as new window routing).

### Pool transfer (send-to-pool)

- Remove window from its current pool (with auto-unwrap/prune)
- Insert into the target pool (appended to the pool's active row if scroll, or children otherwise)

### Swap semantics

`swap` is a **positional exchange**: two children trade tree positions. Properties that belong to the *position* (weight in parent's `:weights` table, `:width` if child of scroll) stay with the position. Properties that belong to the *child* (everything on the window/pool itself) move with the child.

When swapping into a `tabbed` pool, if the incoming child was the active tab's target, `:active` is updated to point to the new position of that child.

Cross-pool swap (windows in different parent pools) is supported: each window is removed from its parent and inserted into the other's former position. Weights/widths are not exchanged since they belong to different pools with potentially different semantics.

---

## 10. Animation

### Scroll animation

Unchanged from current: `animation/scroll-toward` and `animation/scroll-update` handle smooth scrolling. These operate on the scroll pool's per-row `:scroll-offset-x` entries (horizontal) and `:scroll-offset-y` (vertical row transitions). Per-row horizontal offsets replace the old per-column vertical scroll state.

Each `render-scroll` call returns `{:placements [...] :animating true/false}`. The `render-pool` dispatcher collects `:animating` flags from all children — if any child is animating, the parent reports animating. This bubbles up to the root, where the pipeline sets `(state/wm :anim-active)` to request continuous re-rendering during animation.

### Window open/close animation

Unchanged: window-level `:anim` with clip-from/clip-to.

### Move animation

Current behavior: save positions before layout, detect moves, animate. This works identically with pools — the output of `render-pool` is the same flat placement array.

### Scroll-placed flag

Windows placed by a `scroll` pool (or any descendant of a scroll pool) get `:scroll-placed true`. This flag controls clipping behavior. The render function propagates this flag through recursion by detecting when any ancestor in the current render call is a scroll pool.

---

## 11. Persistence

### Overview

The pool tree is the persisted state. On save, window leaves are replaced with match keys (`{:app-id :title}`). On load, the tree is reconstructed and windows are matched back in. The format is pretty-printed JDN (Janet Data Notation), readable from the CLI.

**API** (called by systemd units):
- `tidepoolmsg save > ~/.local/state/tidepool/layout.jdn` — on shutdown
- `tidepoolmsg load < ~/.local/state/tidepool/layout.jdn` — on startup

### Save

```janet
(defn serialize [outputs]
  "Walk each output's pool tree, replacing window leaves with
  {:app-id :title} match keys. Returns pretty-printed JDN string."
  ...)
```

The output is human-readable:

```janet
@{:outputs
  @[@{:connector "DP-1"
      :pool
      @{:mode :tabbed
        :active 0
        :children
        @[@{:mode :scroll
            :id :main
            :active-row 0
            :children
            @[@{:children
                @[@{:app-id "foot" :title "~"}
                  @{:mode :stack-v
                    :children
                    @[@{:app-id "firefox" :title "GitHub"}
                      @{:app-id "firefox" :title "Docs"}]}]}]}
          @{:mode :tabbed
            :id :scratch
            :children
            @[@{:app-id "foot" :title "scratch"}]}]}}]}
```

Pool properties saved: `:mode`, `:id`, `:active`, `:active-row`, `:ratio`, `:weights`, `:width`, `:scroll-offset-x` (zeroed — no point saving mid-scroll state). Animation state and transient flags are stripped.

### Load

```janet
(defn restore [data windows]
  "Reconstruct pool trees from saved state. Match window leaves by
  (app-id, title). First match wins, consumed from the available set.
  Unmatched tree leaves are pruned (empty pools auto-unwrap).
  Unmatched windows are appended to the first pool."
  ...)
```

Matching is best-effort: `(app-id, title)` is not unique (5 terminals all named "foot" + "~"). Order in the saved tree serves as tiebreaker. This is the same limitation as the current system.

### Pretty-printer

A simple recursive JDN formatter (indent 2 spaces per level). This makes `tidepoolmsg save` useful as a CLI diagnostic — you can inspect the full tree state, diff it, pipe it, or edit it by hand.

```janet
(defn pp-jdn [val &opt indent]
  "Pretty-print a JDN value with indentation."
  ...)
```

### In-memory persistence

Tag switching doesn't need disk persistence — each tag IS a subtree that stays in memory. Switching tags just changes `:active` on the output pool. The tree is the persistence.

### Per-tag layout save/restore

Unnecessary — the old `tag-layouts` cache is removed. Each tag pool retains its full subtree in memory at all times.

---

## 12. IPC

### Events

```json
{"event": "tags", "tags": [{"id": 1, "active": true, "windows": 3}, ...]}
{"event": "layout", "mode": "scroll", "output": "DP-1"}
{"event": "title", "title": "vim", "app-id": "foot"}
{"event": "focus-path", "output": "DP-1", "path": ["scroll", "stack-v", "window"]}
```

The `layout` event reports the active tag pool's mode for backward compatibility with existing waybar widgets. The new `focus-path` event reports the path from tag to focused window, enabling richer status bar displays (e.g., "scroll > stack-v > terminal").

### Watch mechanism

The current watcher buffer system (direct stream writes, bypassing netrepl flusher) is preserved.

### Tree introspection

A `tidepoolmsg tree` command prints the full pool tree for debugging. This is essential since the tree structure is otherwise invisible to the user.

---

## 13. River Integration

### What river controls vs what tidepool controls

**River:** Window lifecycle (create, close, dimensions, app-id, title), focus at Wayland level, pointer operations, output configuration, layer shell.

**Tidepool:** Layout computation (positions/sizes), window visibility (`:show`/`:hide`), border colors, background, keybindings.

**Tags are tidepool's responsibility.** River has no tag bitmask. Tidepool calls `:show`/`:hide` on windows directly based on tree visibility.

### Tag synchronization pass

Early in the manage cycle, **before** seat focus or any code that reads `(window :tag)`:

```janet
(defn sync-tags [output-pool]
  "Walk the output pool tree, stamp :tag on each window based on tag pool id."
  (each tag-pool (output-pool :children)
    (def tag-id (tag-pool :id))
    (walk-windows tag-pool (fn [w] (put w :tag tag-id)))))
```

This ensures `(window :tag)` is always consistent with tree position. Tags are identified by pool `:id` (e.g., `:main`, `:web`), not hardcoded numbers. All existing code that reads `:tag` (e.g., `window/tag-output`, `output/visible`, `seat/focus`) continues to work — it just sees ids instead of numbers.

### Visibility computation

Replace `output/visible` filtering with tree-based visibility:

```janet
(defn compute-visible [output-pool]
  "Collect windows reachable through active paths in the tree."
  ...)
```

A window is visible if every `tabbed` ancestor on the path from root to window has the window's branch as active (or is in multi-active mode with the branch included). The pipeline then calls `:show`/`:hide` accordingly.

### Manage/render cycle

The manage/render cycle structure is preserved. The only change in pipeline:

```janet
# Before:
(each o outputs (layout/apply o windows seats config now))

# After:
(each o outputs
  (sync-tags (o :pool))
  (def result (render-pool (active-tag-pool o) (usable-area o) config focused now))
  (apply-geometry (result :placements) config)
  (when (result :animating) (put state/wm :anim-active true)))
```

---

## 14. Config Migration

### Current config (from user's river.nix)

```janet
(put config :default-layout :scroll)
(put config :main-ratio 0.55)
(put config :column-row-height 1.0)
```

### New config

```janet
(put config :default-mode :scroll)      # was :default-layout
(put config :main-ratio 0.55)           # unchanged, used by master-stack preset
(put config :column-width 0.5)          # unchanged
(put config :column-presets [0.5 0.7 1.0])  # unchanged
# :column-row-height removed — use rows for vertical expansion instead.

# Tags are user-defined pools, not hardcoded 1-9:
(put config :pools [:main :web :media :scratch])
```

### Keybinding changes

The action set is smaller and more uniform. Most old actions map directly:

```janet
# Unchanged (same name, same behavior):
(action/focus :left)       # Mod+h/j/k/l
(action/swap :left)        # Mod+Shift+h/j/k/l
(action/zoom)              # Mod+Space
(action/float)             # Mod+f
(action/fullscreen)        # Mod+Shift+f
(action/close)             # Mod+q
(action/focus-last)        # Mod+Backspace
(action/consume :left)     # was consume-column
(action/consume :right)
(action/expel)             # was expel-column

# Collapsed into `resize`:
(action/adjust-ratio -0.05)      ->  (action/resize -0.05)
(action/resize-window -0.1)      ->  (action/resize -0.1)   # context-sensitive
(action/equalize-column)         ->  (action/resize :reset)
(action/preset-column-width)     ->  (action/resize :cycle)

# Collapsed into `set-mode`:
(action/cycle-layout :next)      ->  (action/set-mode :next :tag)
(action/cycle-mode)              ->  (action/set-mode :next)

# Tags are now pool ids:
(action/focus-tag 1)             ->  (action/focus-pool :main)
(action/set-tag 1)               ->  (action/send-to-pool :main)
(action/toggle-tag 1)            ->  (action/toggle-pool :main)
(action/toggle-scratchpad)       ->  (action/toggle-pool :scratch)
(action/send-to-scratchpad)      ->  (action/send-to-pool :scratch)
(action/focus-all-tags)          # bind to a loop over pool ids if desired

# Removed (subsumed):
(action/adjust-main-count 1)     # use consume/expel to restructure
(action/send-to-row :down)       # swap :down crosses row boundaries naturally
```

### Updated river.nix

```janet
# Config:
(put config :default-mode :scroll)
(put config :pools [:main :web :media :scratch])

# Pool (tag) bindings — user defines their own:
(each-with-index [i pool] (config :pools)
  (bind (+ i 1) {:mod4 true} (action/focus-pool pool))
  (bind (+ i 1) {:mod4 true :shift true} (action/send-to-pool pool))
  (bind (+ i 1) {:mod4 true :ctrl true} (action/toggle-pool pool)))

# Navigation:
[:h {:mod4 true} (action/focus :left)]
[:j {:mod4 true} (action/focus :down)]
[:k {:mod4 true} (action/focus :up)]
[:l {:mod4 true} (action/focus :right)]

# Movement:
[:h {:mod4 true :shift true} (action/swap :left)]
[:j {:mod4 true :shift true} (action/swap :down)]
[:k {:mod4 true :shift true} (action/swap :up)]
[:l {:mod4 true :shift true} (action/swap :right)]

# Tree manipulation:
[:h {:mod4 true :ctrl true} (action/consume :left)]
[:l {:mod4 true :ctrl true} (action/consume :right)]
[:j {:mod4 true :ctrl true} (action/expel)]

# Resize:
[:bracketleft {:mod4 true} (action/resize -0.05)]
[:bracketright {:mod4 true} (action/resize 0.05)]
[:k {:mod4 true :ctrl true} (action/resize :reset)]
[:r {:mod4 true} (action/resize :cycle)]

# Mode:
[:t {:mod4 true} (action/set-mode :next)]
[:Tab {:mod4 true} (action/set-mode :next :tag)]
[:Tab {:mod4 true :shift true} (action/cycle-preset)]

# Other:
[:space {:mod4 true} (action/zoom)]
[:backspace {:mod4 true} (action/focus-last)]
[:f {:mod4 true} (action/float)]
[:f {:mod4 true :shift true} (action/fullscreen)]
[:q {:mod4 true} (action/close)]
```

---

## 15. Implementation Plan

### Phase 0: Pool data structure + rendering

**Goal:** Implement pool tables, recursive rendering, and tree construction.

**Files:**
- NEW `src/pool.janet` — pool creation, tree traversal, child manipulation
- NEW `src/pool/render.janet` — recursive render functions

**Tasks:**

1. **Pool constructors and tree primitives** (~100 lines)
   - `make-pool [mode children]` — create pool, set `:parent` on all children
   - `insert-child [pool child index]` — insert, set `(child :parent)`
   - `remove-child [pool index]` — remove, clear `:parent`, return removed child
   - `wrap-children [pool start end mode]` — wrap range of children in a new sub-pool
   - `unwrap-pool [pool index]` — replace child pool with its children, fix `:parent` pointers
   - `move-child [from-pool from-idx to-pool to-idx]` — atomic move between pools
   - `find-window [pool window]` — returns path (array of indices) from pool to window
   - `walk-windows [pool fn]` — call fn on every window leaf in the tree
   - `collect-windows [pool]` — return flat array of all window leaves

2. **`render-stack`** (~60 lines)
   - Divide rect by ratio (2 children) or weights (N children) along axis
   - Apply inner padding between children
   - Recurse into children
   - Tests: 2 children with ratio, 3 children with weights, nested stacks, padding

3. **`render-tabbed`** (~30 lines)
   - Clamp `:active` to valid range
   - Render active child at full rect
   - Walk inactive children, emit `{:hidden true}` for all their windows
   - Tests: active child placed, inactive hidden, out-of-bounds active clamped

4. **`render-scroll`** (~170 lines, simplified port of current scroll/layout)
   - Active row selection and clamping
   - Column x-position computation from active row's children `:width` values
   - Per-row horizontal scroll offset (animated, with peek)
   - Clip detection (hide off-screen columns)
   - Non-active rows: all windows hidden
   - Row transition animation (`:scroll-offset-y`)
   - Recurse into each visible column with full-viewport-height rect
   - Tests: horizontal scroll, column widths, clipping, peek, multi-row, row transitions, swap across rows

5. **`render-pool` dispatcher** (~20 lines)
   - Dispatch on `:mode`, collect placements and animating flags
   - Apply outer padding at tag level

6. **Comprehensive render tests** (~400 lines in `test/pool.janet`)
   - Each mode independently
   - Nested: scroll containing stack-v containing windows
   - Nested: stack-h containing tabbed containing windows
   - Padding: outer at tag level, inner between children
   - Edge cases: empty pool, single child, deeply nested
   - Animation flag propagation

### Phase 1: Navigation

**Files:**
- NEW `src/pool/navigate.janet`

**Tasks:**

1. **`navigate-within`** for each mode (~100 lines)
   - stack-h: left/right between children, up/down bubbles
   - stack-v: up/down between children, left/right bubbles
   - scroll: left/right between columns, up/down into children
   - tabbed: up/down cycles `:active`, left/right bubbles

2. **`enter-pool`** — pick entry point when entering from outside (~30 lines)
   - Direction-aware: entering from left → pick leftmost child
   - Tabbed: always pick active child

3. **`navigate`** — walk up via `:parent`, try within, enter siblings (~50 lines)
   - Bubble up on nil
   - Descend into entered pool recursively
   - Geometry fallback at tag level

4. **Tests** (~300 lines in `test/pool-navigate.janet`)
   - Within each mode
   - Bubble up at edges
   - Cross-pool navigation
   - Enter tabbed → active tab
   - Nested scroll → stack-v → stack-h

### Phase 2: Tree manipulation actions

**Files:**
- REWRITE `src/actions.janet`
- EXTEND `src/pool.janet`

**Tasks:**

1. **consume** — pull adjacent sibling (~40 lines)
   - If focused is bare window in scroll, wrap in stack-v first
   - Pull neighbor into the wrapper pool
   - No-op if no adjacent sibling

2. **expel** — push out to grandparent (~30 lines)
   - No-op if parent is a tag pool
   - Remove from parent, insert into grandparent after parent's position
   - Auto-unwrap parent if applicable

3. **swap** — positional exchange (~40 lines)
   - Within same pool: swap children at indices
   - Cross-pool: remove both, insert at each other's former positions
   - Update tabbed `:active` if needed

4. **zoom** — promote to first position (~20 lines)
   - Walk up to nearest scroll ancestor or tag pool
   - Move focused window to index 0

5. **set-mode** (~30 lines)
   - Validate mode, skip scroll if nested
   - `:next`/`:prev` cycle: stack-h → stack-v → tabbed → stack-h (parent), or scroll → stack-h → stack-v → tabbed → scroll (tag)
   - Optional `:tag` target walks up to tag-level pool

6. **cycle-preset** (~30 lines)
   - Collect tag's windows, apply next preset, replace tag pool children

7. **resize** (~50 lines)
   - Numeric delta: modify `:ratio` (2 children) or `:weights` (3+) or `:width` (scroll child)
   - `:reset`: clear `:weights` and `:ratio`
   - `:cycle`: cycle through width presets

8. **focus-pool / send-to-pool / toggle-pool** (~50 lines)
   - Operate by pool `:id` on the output pool's children
   - `toggle-pool` manages multi-active state

9. **Tests** (~300 lines in `test/pool-actions.janet`)
   - Each action with before/after tree assertions
   - Edge cases: consume with no neighbor, expel from tag, swap across rows, swap cross-pool

### Phase 3: Window routing + tag integration + pipeline

**Files:**
- MODIFY `src/window.janet` — simplify (remove layout-prop clearing)
- MODIFY `src/output.janet` — create output pool, tag pool management
- MODIFY `src/pipeline.janet` — pool rendering, tag sync, visibility from tree
- MODIFY `src/tidepool.janet` — new window insertion via pool tree

**Tasks:**

1. **Output pool creation** — on output creation, build tabbed pool with user-configured pool ids as children
2. **Tag sync pass** — walk tree, stamp `:tag` (pool id) on windows
3. **New window routing** — insert into focused pool per insertion rule
4. **Window close** — remove from tree, auto-unwrap/prune
5. **Float/unfloat** — remove from / insert into tree
6. **Replace `layout/apply`** with `render-pool` in pipeline manage cycle
7. **Visibility from tree** — replace `output/visible` with tree-based collection
8. **Border computation** — use `(window :parent :mode)` for tabbed border color

### Phase 4: Persistence + IPC

**Files:**
- REWRITE `src/persist.janet`
- MODIFY `src/ipc.janet`

**Tasks:**

1. **Pretty-print JDN** — recursive formatter (indent 2 spaces per level)
2. **Serialize pool tree** — walk tree, replace window leaves with `{:app-id :title}`, strip animation state, pretty-print
3. **Restore pool tree** — reconstruct from JDN, match windows by `(app-id, title)`, prune unmatched leaves, append unmatched windows
4. **`tidepoolmsg save`** — calls serialize, prints to stdout (pipe to file via systemd)
5. **`tidepoolmsg load`** — reads stdin, calls restore
6. IPC: emit pool/layout/title/focus-path events from tree state
7. `tidepoolmsg tree` command for debugging (pretty-prints live tree)

### Phase 5: Cleanup + config migration

**Files:**
- DELETE `src/layout/` (all 8 files)
- MODIFY `src/state.janet` — remove `layout-props`, update config defaults
- MODIFY `src/tidepool.janet` — remove old imports
- UPDATE user config (river.nix)
- UPDATE/REWRITE tests

---

## 16. Data Structures

### Pool table

```janet
# Scroll pool (tag level)
@{:mode :scroll
  :parent <output-pool>
  :id :main
  :active-row 0
  :scroll-offset-x @{0 0}    # per-row horizontal offset
  :scroll-offset-y 0          # vertical row-transition offset
  :children @[<row-pool> ...]}

# Row pool (child of scroll)
@{:parent <scroll-pool>
  :children @[<window-or-pool> ...]}

# Stack-h (master-stack pattern)
@{:mode :stack-h
  :parent <tag-pool>
  :ratio 0.55
  :children @[<master-window>
              @{:mode :stack-v :parent <this> :children @[<w1> <w2> <w3>]}]}

# Tabbed
@{:mode :tabbed
  :parent <scroll-pool>
  :active 0
  :children @[<w1> <w2> <w3>]}

# Output pool (tags container)
@{:mode :tabbed
  :parent nil
  :active 0
  :multi-active @{}    # tag-index -> true, for multi-tag view
  :children @[<tag-pool-1> <tag-pool-2> ...]}
```

### What lives on pools vs windows

**On the pool:**
- `:mode`, `:ratio`, `:weights`, `:active` — layout state
- `:active-row`, `:scroll-offset-x` (per-row table), `:scroll-offset-y` — scroll state
- `:width` — column width (child of scroll)
- `:parent` — back-pointer
- `:id` — for persistence/IPC

**Stays on the window (unchanged):**
- `:tag` — derived from tree position, kept for compatibility
- `:float`, `:fullscreen` — window state
- `:app-id`, `:title` — identity
- `:x`, `:y`, `:w`, `:h` — computed positions
- `:anim` — animation state
- `:border-*`, `:clip-rect` — rendering state
- `:parent` — back-pointer into pool tree

**Removed from window:**
- `:column`, `:col-width`, `:col-weight`, `:col-mode`, `:col-active`
- `:strip`, `:strip-weight`
- `:col-sublayout`, `:col-sublayout-params`

---

## 17. File Changes

### New files

| File | Purpose | ~Lines |
|------|---------|--------|
| `src/pool.janet` | Pool creation, tree traversal, child manipulation | ~200 |
| `src/pool/render.janet` | Recursive rendering (scroll, stack, tabbed) | ~350 |
| `src/pool/navigate.janet` | Structural navigation | ~200 |
| `test/pool.janet` | Pool rendering tests | ~400 |
| `test/pool-navigate.janet` | Navigation tests | ~300 |
| `test/pool-actions.janet` | Tree manipulation tests | ~300 |

### Modified files

| File | Changes |
|------|---------|
| `src/actions.janet` | Rewrite all layout/column actions to use pool tree |
| `src/pipeline.janet` | Replace `layout/apply` with `pool/render`, tag sync, tree-based visibility |
| `src/state.janet` | Remove `layout-props`, update config defaults |
| `src/window.janet` | Remove layout-prop clearing in `set-float`, add `:parent` |
| `src/output.janet` | Create output pool on output creation, tag pool management |
| `src/persist.janet` | Save/restore pool trees instead of flat window properties |
| `src/ipc.janet` | Compute events from pool tree state |
| `src/tidepool.janet` | Update imports, window insertion via pool tree |

### Deleted files

| File | Replaced by |
|------|------------|
| `src/layout/init.janet` | `src/pool/render.janet` + `src/pool.janet` |
| `src/layout/scroll.janet` | `src/pool/render.janet` (render-scroll) |
| `src/layout/master-stack.janet` | preset-master-stack + stack-h mode |
| `src/layout/monocle.janet` | tabbed mode |
| `src/layout/grid.janet` | preset-grid + stack-v/stack-h composition |
| `src/layout/dwindle.janet` | nested alternating stacks (manual or preset) |
| `src/layout/centered-master.janet` | stack-h with 3 children |
| `src/layout/util.janet` | inlined into pool/render.janet |

---

## 18. Test Strategy

### Unit tests

All pool logic is pure (no compositor dependencies). Tests create pool trees with mock window tables and verify:

**Rendering (test/pool.janet):**
- Each mode produces correct geometry for given rect
- Padding: outer at tag level, inner between children
- Scroll: per-row horizontal offset, clipping, peek, multi-row, row transitions
- Tabbed: only active child placed, rest hidden; `:active` clamping
- Nested: geometry composes correctly across 3-4 levels
- Edge cases: empty pools, single-child pools, deeply nested
- Animation flag bubbles up correctly

**Navigation (test/pool-navigate.janet):**
- Each mode navigates correctly within
- Bubble-up at pool boundaries
- Enter-pool picks correct entry point by direction
- Tabbed cycling wraps
- Cross-pool navigation (scroll column to scroll column)
- Nested: stack-v inside scroll, tabbed inside stack-h
- Geometry fallback at tag level

**Tree manipulation (test/pool-actions.janet):**
- insert/remove/wrap/unwrap maintain `:parent` invariants
- Auto-unwrap policy: default stack-v unwraps, tabbed does not
- Auto-prune when pool reaches 0 children
- consume: creates wrapper, absorbs neighbor
- expel: moves to grandparent, no-op at tag level
- swap: within pool, cross-pool, tabbed `:active` adjustment
- zoom: promotes to first position in nearest scroll/tag ancestor
- set-mode: validates, skips nested scroll, :next/:prev cycling, :tag targeting
- resize: numeric delta, :reset, :cycle
- presets: construct correct tree shapes

**Pool targeting (extends test/pool-actions.janet):**
- Tag sync stamps correct `:tag` (pool id) on windows
- focus-pool updates `:active`
- toggle-pool enables multi-active
- send-to-pool moves window between subtrees
- Multi-pool view renders as stack-v of strips

### Integration tests

- Full pipeline: create output → create pool tree → create windows → render → verify positions
- Window lifecycle: new window → tree insertion → close → tree pruning
- Tag switching: change active tag → verify correct windows visible
- Persistence: save tree → restore → verify structure
- IPC: verify events match tree state
