# Composable Layout System Design

## Executive Summary

This document proposes extending tidepool's scroll layout with **tabbed column stacking** as the immediate deliverable, with **scroll strips** (multiple independent scroll rows) and **sublayouts** (delegating a column to another layout algorithm) designed but deferred to v2 and v3 respectively.

The core design principles: **extend, don't replace** and **don't privilege any layout**. The current architecture (pure layout functions, window properties as the only persistent state, emergent column grouping) is preserved. No container trees. No first-class column objects. Composition through data properties and function composition. Column operations, navigation context, and layout properties are layout-system-level infrastructure — scroll is just another layout that uses them, not a special case.

---

## Table of Contents

1. [Current Architecture](#1-current-architecture)
2. [Design Goals and Constraints](#2-design-goals-and-constraints)
3. [Alternatives Considered](#3-alternatives-considered)
4. [Chosen Approach: Column-Centric Extension](#4-chosen-approach-column-centric-extension)
5. [Phase 1: Tabbed Columns](#5-phase-1-tabbed-columns)
6. [Phase 2: Scroll Strips (Deferred)](#6-phase-2-scroll-strips-deferred)
7. [Phase 3: Sublayouts (Deferred)](#7-phase-3-sublayouts-deferred)
8. [User Stories](#8-user-stories)
9. [Structural Cleanup (Phase 0)](#9-structural-cleanup-phase-0)
10. [Feature Implementation Notes](#10-feature-implementation-notes)
11. [Open Questions](#11-open-questions)

---

## 1. Current Architecture

### What we have

The layout system has these invariants:

- **Layout functions are pure.** Signature: `(layout-fn usable windows params config focused &opt now focus-prev)` returning `[{:window :x :y :w :h}]`. No side effects.

- **Windows are the only persistent entities.** Layout-relevant properties live directly on window tables: `:column` (integer), `:col-width` (ratio), `:col-weight` (ratio), `:tag`, `:float`, `:fullscreen`.

- **Columns are emergent.** The `scroll/group` function groups windows by `:column` value. The `scroll/assign` function renumbers columns to be contiguous each frame. There are no column objects.

- **Layout params live on the output** at `(o :layout-params)`, persisted per-tag via `state/tag-layouts`.

- **Navigation functions** dispatch per-layout-keyword, with a geometry-based fallback.

### Key files

| File | Role |
|------|------|
| `src/layout/scroll.janet` | Column grouping, scroll logic, placement, navigation |
| `src/layout/init.janet` | Layout dispatch, geometry navigation, result application |
| `src/actions.janet` | All user actions (keybindings) |
| `src/window.janet` | Window lifecycle, properties |
| `src/persist.janet` | State serialization/restoration |
| `src/pipeline.janet` | Per-frame manage/render lifecycle |
| `src/state.janet` | Config defaults, global state tables |

### Existing patterns worth preserving

The `resize-column` action demonstrates the "column property on windows" pattern:
```janet
# actions.janet:296-300
(defn resize-column [delta]
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def current (or ((first col) :col-width) ...))
      (def new-width (max 0.1 (min 1.0 (+ current delta))))
      (each win col (put win :col-width new-width)))))
```
All windows in a column carry `:col-width`, but only `(first col)` is read by the layout. The redundancy ensures the property follows windows through consume/expel operations and survives column renumbering.

---

## 2. Design Goals and Constraints

### What we want (prioritized)

1. **Tabbed column stacking** -- A column shows one window at a time. The user can cycle through tabs. This is the single most-requested feature (sway's tabbed containers).

2. **Scroll strips** -- Multiple independent horizontal scroll rows stacked vertically. Each row scrolls independently with its own columns.

3. **Sublayouts** -- A scroll column delegates its internal arrangement to another layout algorithm (dwindle, grid, master-stack, etc.).

4. **Horizontal splits within columns** -- Currently, columns stack windows vertically. We'd like side-by-side splits within a column. (Partially addressed by sublayouts -- a column using `:master-stack` gets a horizontal split.)

### Constraints

- Must preserve pure-function layout architecture
- Must not introduce container tree / mutable graph state
- User interaction model must be keyboard-driven, discoverable, muscle-memory compatible
- Must work with existing animation system, IPC events, clipping, persistence
- Changes to non-scroll layouts: zero
- Must be incrementally shippable (tabs first, then strips, then sublayouts)

---

## 3. Alternatives Considered

### 3.1 Container Tree (i3/sway model)

**Proposal:** Replace the flat layout system with a tree of containers. Leaf nodes hold windows, branch nodes hold children plus a layout strategy. Layout is recursive. Focus is a path through the tree.

**Why rejected:**

- **Invisible state driving visible behavior.** In i3, users constantly create nested containers they cannot see, leading to "where did my window go?" confusion. The tree structure is invisible but determines window placement. Our current system avoids this entirely.

- **Breaks the pure-function architecture.** A mutable tree must be kept consistent across operations (split, merge, move, close). Every operation is tree surgery. The current system's layout functions are stateless -- they group windows by property values each frame.

- **Destroys geometric navigation.** Tree-based focus traversal ("bubble up, descend into focused child") produces unintuitive results when the tree structure doesn't match spatial arrangement. Our `navigate-by-geometry` is strictly better for the user.

- **All-or-nothing rewrite.** Converting master-stack, grid, dwindle, centered-master, and monocle into "tree constructors" means rewriting every layout while providing zero new features. The existing layouts work perfectly as flat functions.

- **"Convenience constructors" are an admission of failure.** If the tree model requires compatibility wrappers to make simple cases work, it's too complex.

### 3.2 Slots and Adapters (Layout Algebra)

**Proposal:** Layouts produce named slots (rectangular regions). Adapters assign windows to slots. A composed layout chains slot-producers with adapters. Any slot can contain another layout.

**Why rejected:**

- **Window routing problem.** In the current system, all windows go to one layout. With slots, you need rules for which windows go where. This requires either explicit tagging (user overhead) or implicit ordering (fragile). Neither is good for interactive use.

- **Spec mutation is hard.** Deeply nested layout specs are hard to construct interactively via keybindings. The user would need "spec editor" commands rather than direct manipulation.

- **Overkill for the use cases.** We want tabs and strips, not arbitrary layout composition. The slots model solves a more general problem than we have.

**What we took from it:** The idea that sublayouts can be implemented as function composition (pass a bounding box to an existing layout function) rather than requiring a new abstraction.

### 3.3 Constraint Groups

**Proposal:** Windows carry spatial constraints (strip, column, row, stacking mode). A solver groups windows by constraints and produces geometry. Layout presets become "constraint templates."

**Why rejected:**

- **Implicit structure is hard to debug.** No single data structure represents "the layout." You have to inspect all windows' constraints together.

- **Solver complexity.** Multi-phase grouping with conflict resolution for edge cases (two windows claiming the same position).

**What we took from it:** The idea that `:strip` can be a window property (like `:column`), making strips emergent from window properties rather than requiring a separate data structure.

### 3.4 First-Class Column Objects

**Proposal:** Make columns explicit objects (tables) stored in `layout-params`. Windows reference columns by ID. Column metadata (mode, active tab, sublayout) lives on the column object.

**Why rejected:**

- **Introduces synchronization between two state sources.** Column objects and window properties must agree. Every operation (consume, expel, swap, close) must update both. This is the exact complexity the emergent-column design avoids.

- **Assign renumbering must remap column-object keys.** The `assign` function renumbers columns each frame. Column objects keyed by index would need remapping every frame. Using stable IDs instead introduces column ordering complexity (insert "between" two columns).

- **Premature for one property.** We're adding `:col-mode` (one new column-level concept). Building column object infrastructure for one property is over-engineering. If we later have 5+ column properties, refactoring to column objects is straightforward with full knowledge of what properties exist.

---

## 4. Chosen Approach: Column-Centric Extension

### Core principle

Columns remain emergent from window properties. New column-level concepts (stacking mode, active tab) are stored as window properties following the exact pattern of `:col-width`. A per-frame normalization pass ensures invariants hold despite the redundant storage.

### Why this works

1. **Zero new data structures.** No column objects, no tree nodes, no slot specs.
2. **Same persistence model.** Window properties are already serialized/restored.
3. **Self-healing.** Normalization runs every frame, so inconsistencies (from consume, expel, swap, close) are corrected within one frame (~16ms). The user never sees them.
4. **Incremental.** Each phase adds window properties and layout logic. No rewrites.

### New window properties

| Property | Type | Default | Purpose | Phase |
|----------|------|---------|---------|-------|
| `:col-mode` | `:split` or `:tabbed` | `:split` | Column stacking mode | 1 |
| `:col-active` | boolean | `true` | Active tab marker in tabbed mode | 1 |
| `:strip` | integer | `0` | Scroll strip assignment | 2 |
| `:col-sublayout` | keyword or nil | `nil` | Sublayout algorithm for column | 3 |

---

## 5. Phase 1: Tabbed Columns

### Data model

Two new window properties:

- **`:col-mode`** -- `:split` (default, current behavior: divide column vertically among all windows) or `:tabbed` (show one window, hide the rest).

- **`:col-active`** -- Boolean. In a tabbed column, the window with `:col-active true` is visible. In `:split` mode, this property is ignored.

All windows in a column share the same `:col-mode` (like `:col-width`). The layout reads from `(first col)`.

### Per-frame normalization

After `group` returns columns, before layout computation:

```janet
(each col cols
  # Normalize col-mode: all windows follow first window
  (def mode (or ((first col) :col-mode) :split))
  (each win col (put win :col-mode mode))

  # Normalize col-active for tabbed columns
  (when (= mode :tabbed)
    (def active-count (count |($ :col-active) col))
    (cond
      # No active window: activate the focused one, or first
      (= active-count 0)
      (let [target (or (find |(= $ focused) col) (first col))]
        (put target :col-active true))

      # Multiple active: keep only the focused one (or first active)
      (> active-count 1)
      (let [keep (or (find |(and ($ :col-active) (= $ focused)) col)
                     (find |($ :col-active) col))]
        (each win col
          (put win :col-active (= win keep)))))))
```

This normalization:
- Fixes `:col-mode` desync after consume/expel/swap
- Fixes `:col-active` after window close (active window dies)
- Fixes `:col-active` after consume (two active windows merge)
- Fixes `:col-active` after expel (new single-window column)
- Costs ~10 lines and runs in O(n) where n = windows in the column

### Layout changes

In the column rendering loop of `scroll/layout`, branch on mode:

```janet
(case (or ((first col) :col-mode) :split)
  :split
  # Existing vertical split logic (heights by col-weight)
  (existing-split-logic ...)

  :tabbed
  # Place only the active window at full column height
  (each win col
    (if (win :col-active)
      (array/push results
        {:window win :x (+ x inner) :y (+ y inner)
         :w (- cw (* 2 inner)) :h (- total-h (* 2 inner))
         :scroll-placed true})
      (array/push results
        {:window win :hidden true :scroll-placed true}))))
```

The active tab gets the entire column height (no splitting). Hidden tabs are marked `:hidden true` and will not be rendered.

### Navigation changes

The `scroll/navigate` function needs mode-awareness:

```janet
# In the :up/:down cases:
:up (let [col (get cols my-col)]
      (if (= ((first col) :col-mode) :tabbed)
        # Tabbed: cycle to previous tab
        (when (> (length col) 1)
          (let [active-idx (or (find-index |($ :col-active) col) 0)
                prev-idx (if (> active-idx 0) (- active-idx 1) (- (length col) 1))]
            # Mark new active tab
            (each win col (put win :col-active false))
            (put (get col prev-idx) :col-active true)
            (index-of (get col prev-idx) tiled)))
        # Split: existing behavior
        (when (> my-row 0)
          (set target (get col (- my-row 1))))))

:down (let [col (get cols my-col)]
        (if (= ((first col) :col-mode) :tabbed)
          # Tabbed: cycle to next tab
          (when (> (length col) 1)
            (let [active-idx (or (find-index |($ :col-active) col) 0)
                  next-idx (if (< active-idx (- (length col) 1)) (+ active-idx 1) 0)]
              (each win col (put win :col-active false))
              (put (get col next-idx) :col-active true)
              (index-of (get col next-idx) tiled)))
          # Split: existing behavior
          (when (< (+ my-row 1) (length col))
            (set target (get col (+ my-row 1))))))
```

**Key design decision**: `focus-up`/`focus-down` reuse for tab cycling (sway's approach). No separate `cycle-tab` action. This preserves muscle memory -- the user always uses the same four directional keys regardless of column mode.

When **focusing into a tabbed column from outside** (left/right navigation), the active tab receives focus:

```janet
:left (when (> my-col 0)
        (def target-col (get cols (- my-col 1)))
        (if (= ((first target-col) :col-mode) :tabbed)
          # Focus the active tab
          (set target (or (find |($ :col-active) target-col)
                          (first target-col)))
          # Split: existing row-clamping
          (set target (get target-col (min my-row (- (length target-col) 1))))))
```

### Actions

**One new action:**

```janet
(defn toggle-column-mode
  "Action: toggle focused column between :split and :tabbed."
  []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (def current (or ((first col) :col-mode) :split))
      (def new-mode (if (= current :tabbed) :split :tabbed))
      (each win col
        (put win :col-mode new-mode)
        # When entering tabbed, make the focused window active
        (when (= new-mode :tabbed)
          (put win :col-active (= win (seat :focused))))))))
```

**Existing actions that work unchanged:**

| Action | Behavior in tabbed column |
|--------|--------------------------|
| `consume-column` | Window enters tabbed column, becomes a new tab. Normalization ensures col-mode sync. |
| `expel-column` | Window leaves tabbed column. Expelled window's `:col-mode` is cleared to `:split` (a single-window tabbed column has confusing border styling). The `expel-column` action should `(put w :col-mode nil)` on the expelled window. |
| `swap` | Swaps window positions. `:col-mode` is normalized from `(first col)` next frame. |
| `resize-column` | Changes column width. Works identically for tabbed and split. |
| `resize-window` | Changes `:col-weight`. No-op visually for tabbed (one window fills column), but preserves weights for when user switches back to split. |
| `equalize-column` | Resets `:col-weight`. Same as resize-window -- preserves for mode switch. |
| `preset-column-width` | Cycles width presets. Works identically. |

**Swap behavior detail**: The `swap` action (actions.janet:117-148) swaps `:column`, `:col-width`, and `:col-weight` between two windows. It should also swap `:col-mode` and `:col-active`:

```janet
# Add to swap action's property exchange:
(def wcm (w :col-mode))
(def tcm (t :col-mode))
(put w :col-mode tcm)
(put t :col-mode wcm)
(def wca (w :col-active))
(def tca (t :col-active))
(put w :col-active tca)
(put t :col-active wca)
```

But even without this, normalization would fix it next frame.

**Swap into/out of tabbed columns:** When swapping between a split column and a tabbed column, the active tab moves to the other column and the incoming window becomes hidden (it lacks `:col-active true`). This is potentially confusing. The `swap` action should additionally set `:col-active true` on the incoming window and `:col-active false` on other windows in the target column, so the swapped-in window is immediately visible. Alternatively, swap could be restricted to only swap within the same column for tabbed mode (swap reorders tabs). Cross-column swap from a tabbed column should probably swap the entire column's position, not a single tab. **This interaction needs user testing to determine the right behavior.**

### Persistence

Add `:col-mode` and `:col-active` to serialization:

```janet
# persist.janet:serialize - add to win-data:
:col-mode (w :col-mode)
:col-active (w :col-active)

# persist.janet:restore-window - add to restoration:
(when (saved :col-mode)
  (put window :col-mode (saved :col-mode)))
(when (saved :col-active)
  (put window :col-active (saved :col-active)))
```

### Tab bar rendering

**V1: No tab bar.** The focused window's title appears in the status bar via IPC. The user knows which tab is active from the window content.

**V1.5: IPC extension.** Add a `:tabs` topic to `ipc/emit-events` that emits per-column tab lists:

```json
{"event": "tabs", "columns": [
  {"col": 0, "mode": "split", "windows": [{"app-id": "foot", "title": "~"}]},
  {"col": 1, "mode": "tabbed", "active": 1, "windows": [
    {"app-id": "firefox", "title": "GitHub"},
    {"app-id": "firefox", "title": "Docs"},
    {"app-id": "firefox", "title": "Mail"}
  ]}
]}
```

External tools (waybar custom modules, eww) can render tab indicators from this data.

**V2: Tab bar surface.** Render a tab bar as a layer-shell surface positioned at the top of each tabbed column. This requires creating Wayland surfaces per tabbed column, managing their lifecycle, and rendering text. Significant effort; defer to after v1 feedback.

### IPC changes

The existing layout IPC topic gains column mode info:

```janet
# ipc.janet:compute-layout -- extend to include column modes
(defn- compute-layout [outputs focused-output]
  @{:outputs (seq [o :in outputs]
      @{:x (o :x) :y (o :y)
        :layout (o :layout)
        :focused (= o focused-output)})})
```

A new `:tabs` topic (optional) provides detailed tab state for status bar integration.

### Visual feedback

Since there's no tab bar in v1, the column must visually indicate tabbed mode. Options:

- **Different border color for tabbed columns.** Add `:border-tabbed` config key, applied to the active tab's window border. Low effort.
- **Column indicator.** A small colored bar at the top of the column. Requires a surface; defer.

Recommendation: use border color. It's one line in `pipeline/compute-borders`:

```janet
(if (and (w :col-mode) (= (w :col-mode) :tabbed) (w :col-active))
  (window/set-borders w :tabbed config)
  ...)
```

### Files changed (Phase 1)

| File | Changes |
|------|---------|
| `src/layout/scroll.janet` | Normalization pass after `group`; tabbed branch in column layout; tabbed awareness in `navigate` and `context` |
| `src/actions.janet` | Add `toggle-column-mode`; add `:col-mode`/`:col-active` to swap |
| `src/persist.janet` | Serialize/restore `:col-mode`, `:col-active` |
| `src/window.janet` | Clear `:col-mode`/`:col-active` in `set-float` |
| `src/pipeline.janet` | Tabbed border color in `compute-borders` |
| `src/state.janet` | Add `:border-tabbed` config default |
| `src/ipc.janet` | Optional `:tabs` IPC topic |
| `test/scroll.janet` | Tests for tabbed layout, normalization, navigation |

Estimated: ~100-150 lines of new code across 6 files.

---

## 6. Phase 2: Scroll Strips

### Overview

Scroll strips extend the scroll layout to support multiple independent horizontal scroll rows stacked vertically. Each strip is its own scroll context with its own columns, scroll offset, and vertical scroll state.

### Data model

Two new window properties:

- **`:strip`** (integer, default `0`) -- Strip assignment. Strips are emergent from window `:strip` values, exactly like columns from `:column`.

- **`:strip-weight`** (float or nil, default `1.0`) -- Height ratio for this strip. All windows in a strip carry the same value (like `:col-width`). Read from `(first (first strip-cols))`.

`:strip` and `:column` are **independent**. Column indices are renumbered **per strip**, not globally. A window with `{:strip 0 :column 1}` and a window with `{:strip 1 :column 1}` are in different columns in different strips.

### Grouping

A new function `group-strips` performs two-level grouping:

```janet
(defn group-strips
  "Group windows into strips, each containing ordered columns.
  Returns array of arrays-of-columns: [[col col ...] [col col ...] ...]"
  [windows focused &opt focus-prev]
  # Assign default strip
  (each win windows (unless (win :strip) (put win :strip 0)))
  # Group by strip
  (def strip-groups @{})
  (each win windows
    (def s (win :strip))
    (unless (strip-groups s) (put strip-groups s @[]))
    (array/push (strip-groups s) win))
  # Normalize strip indices to be contiguous (0, 1, 2...)
  (def strip-indices (sorted (keys strip-groups)))
  (def strip-map @{})
  (for i 0 (length strip-indices)
    (put strip-map (get strip-indices i) i))
  (each win windows (put win :strip (get strip-map (win :strip))))
  # Group each strip's windows into columns using existing group()
  (def focused-strip (if focused (focused :strip) 0))
  (def result @[])
  (for si 0 (length strip-indices)
    (def strip-wins (get strip-groups (get strip-indices si)))
    (def strip-focused (if (= si focused-strip) focused nil))
    (def strip-focus-prev
      (if (and focus-prev (= si focused-strip)) focus-prev nil))
    (array/push result (group strip-wins strip-focused strip-focus-prev)))
  result)
```

### Per-strip scroll offsets in layout-params

Keys are namespaced by strip index to preserve the degenerate case:
- Strip 0: `:scroll-offset` (unchanged from current code)
- Strip N (N > 0): `:scroll-offset-sN`
- Strip 0, Column C: `:scroll-y-C` (unchanged)
- Strip N, Column C: `:scroll-y-sN-C`

Animation keys follow the same pattern with `-anim` suffix. When all windows have `:strip 0`, every key is identical to the pre-strips code.

### Layout algorithm

The current `scroll/layout` is restructured into two layers:

1. **Outer layer** (`scroll/layout`): groups by strip, divides vertical space, iterates strips
2. **Inner layer** (`layout-strip`): the current layout logic, operating on one strip's columns within a given bounding box

```janet
(defn layout [usable windows params config focused &opt now focus-prev]
  (when (empty? windows) (break @[]))
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  (def total-w (max 0 (- (usable :w) (* 2 outer))))
  (def total-h (max 0 (- (usable :h) (* 2 outer))))
  (def strips (group-strips windows focused focus-prev))
  (def num-strips (length strips))
  (def strip-hs (strip-heights strips total-h))

  # Find which strip contains the focused window
  (var focused-strip 0)
  (when focused (set focused-strip (or (focused :strip) 0)))

  (def all-results @[])
  (var y-acc 0)
  (for si 0 num-strips
    (def strip-cols (get strips si))
    (def strip-h (get strip-hs si))
    (def scroll-key (if (= si 0) :scroll-offset
                      (keyword (string "scroll-offset-s" si))))
    (def strip-focused (if (= si focused-strip) focused nil))
    # layout-strip contains the current layout logic, using strip-local bounds
    (def strip-results
      (layout-strip (+ (usable :x) outer) (+ (usable :y) outer y-acc)
                    total-w strip-h
                    strip-cols params config strip-focused now
                    scroll-key si))
    (array/concat all-results strip-results)
    (set y-acc (+ y-acc strip-h)))
  all-results)
```

Strip heights are proportional to `:strip-weight`:

```janet
(defn strip-heights [strips total-h]
  (def weights (map |(or ((first (first $)) :strip-weight) 1.0) strips))
  (def total-weight (reduce + 0 weights))
  (def heights @[])
  (var y-sum 0)
  (for si 0 (length strips)
    (def h (math/round (* total-h (/ (get weights si) total-weight))))
    (def actual-h (if (= si (- (length strips) 1)) (- total-h y-sum) h))
    (array/push heights actual-h)
    (set y-sum (+ y-sum actual-h)))
  heights)
```

Inter-strip gaps come naturally from each strip's internal padding: the last row of strip N has `inner` padding at bottom, first row of strip N+1 has `inner` at top, creating `2 * inner` gap.

**Degenerate case guarantee:** When all windows have `:strip 0`, `group-strips` returns one strip, the outer loop runs once with `si = 0`, all layout-params keys are identical to pre-strips code. Result is byte-for-byte identical.

### Context changes

`scroll/context` auto-scopes to the focused window's strip:

```janet
(defn context [o windows focused &opt focus-prev]
  (def visible (filter |(not (or ($ :float) ($ :fullscreen)))
                       (output/visible o windows)))
  (when (empty? visible) (break nil))
  (def strips (group-strips visible focused focus-prev))
  (def num-strips (length strips))
  (var focused-strip 0)
  (var focused-col 0)
  (var focused-row 0)
  (for si 0 num-strips
    (for ci 0 (length (get strips si))
      (def col (get (get strips si) ci))
      (for ri 0 (length col)
        (when (= (get col ri) focused)
          (set focused-strip si)
          (set focused-col ci)
          (set focused-row ri)))))
  (def cols (get strips focused-strip))
  @{:windows visible
    :strips strips :num-strips num-strips
    :cols cols :num-cols (length cols)
    :focused-win focused :focused-strip focused-strip
    :focused-col focused-col :focused-row focused-row})
```

The `:cols` field returns the focused strip's columns. This means `scroll/focused-column` and all actions that use it (resize-column, equalize, preset-width, etc.) work unchanged -- they are automatically strip-scoped.

### Navigation

The navigation priority chain (covering all three phases) is:

1. **Sublayout navigate** (Phase 3) -- if `:col-sublayout` is set, dispatch to sublayout's navigate function. If it returns a target, done. If nil, fall through.
2. **Tabbed/monocle cycling** (Phase 1/3) -- if `:col-mode :tabbed` or `:col-sublayout :monocle`, cycle tabs/windows (wraps, never falls through).
3. **Split within-column** -- if not at column edge, move within column.
4. **Strip-crossing** (Phase 2) -- if at column edge and adjacent strip exists, cross to it.
5. **Give up** -- return nil.

For left/right: stays within the current strip (no strip-crossing on left/right).

```janet
(defn navigate [n main-count i dir ctx]
  (when-let [col-ctx ctx]
    (def {:strips strips :num-strips num-strips
          :cols cols :num-cols num-cols
          :focused-strip my-strip :focused-col my-col
          :focused-row my-row :windows tiled} col-ctx)
    (var target nil)
    (case dir
      :left
      (when (> my-col 0)
        (def target-col (get cols (- my-col 1)))
        (set target (scroll-enter-column target-col my-row)))

      :right
      (when (< (+ my-col 1) num-cols)
        (def target-col (get cols (+ my-col 1)))
        (set target (scroll-enter-column target-col my-row)))

      :up
      (let [col (get cols my-col)]
        # Priority 1-2: sublayout/tabbed handled by dispatch (see Phase 3)
        # Priority 3: within-column
        (if (> my-row 0)
          (set target (get col (- my-row 1)))
          # Priority 4: strip-crossing
          (when (> my-strip 0)
            (def above-cols (get strips (- my-strip 1)))
            (def above-ci (min my-col (- (length above-cols) 1)))
            (def above-col (get above-cols above-ci))
            (set target (scroll-enter-column above-col (- (length above-col) 1))))))

      :down
      (let [col (get cols my-col)]
        (if (< (+ my-row 1) (length col))
          (set target (get col (+ my-row 1)))
          (when (< (+ my-strip 1) num-strips)
            (def below-cols (get strips (+ my-strip 1)))
            (def below-ci (min my-col (- (length below-cols) 1)))
            (def below-col (get below-cols below-ci))
            (set target (scroll-enter-column below-col 0))))))

    (when target (index-of target tiled))))
```

`scroll-enter-column` handles entering any column type (split, tabbed, sublayout):

```janet
(defn- scroll-enter-column [col row-hint]
  (def mode (or ((first col) :col-mode) :split))
  (def sublayout ((first col) :col-sublayout))
  (if (or (= mode :tabbed) (= sublayout :monocle))
    (or (find |($ :col-active) col) (first col))
    (get col (min row-hint (- (length col) 1)))))
```

### Actions

**New actions:**

```janet
(defn move-to-strip
  "Action: move focused window to an adjacent strip, creating if needed."
  [dir]
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)
               ctx-fn (get layout/context-fns (o :layout))
               ctx (ctx-fn o (state/wm :windows) w (seat :focus-prev))]
      (when (ctx :strips)
          (def my-strip (ctx :focused-strip))
          (def num-strips (ctx :num-strips))
          (def target (case dir :up (- my-strip 1) :down (+ my-strip 1)))
          (cond
            (< target 0)
            (do  # Shift all strips up, insert at 0
              (each win (ctx :windows) (put win :strip (+ (win :strip) 1)))
              (put w :strip 0)
              (put w :column nil))
            (>= target num-strips)
            (do  # Create new strip at end
              (put w :strip num-strips)
              (put w :column nil))
            (do  # Move to existing strip
              (put w :strip target)
              (put w :column nil))))))))

(defn resize-strip
  "Action: resize the focused strip's height by delta."
  [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)
               w (seat :focused)
               ctx-fn (get layout/context-fns (o :layout))
               ctx (ctx-fn o (state/wm :windows) w (seat :focus-prev))]
      (when (ctx :strips)
          (when (> (ctx :num-strips) 1)
            (def my-strip-cols (get (ctx :strips) (ctx :focused-strip)))
            (def current (or ((first (first my-strip-cols)) :strip-weight) 1.0))
            (def new-weight (max 0.1 (+ current delta)))
            (each col my-strip-cols
              (each win col (put win :strip-weight new-weight)))))))))
```

**Existing action changes:**

- `swap`: add `:strip` and `:strip-weight` to the property exchange
- `expel-column`: scope max-col search to current strip's `cols` (not global `tiled`)
- `consume-column` and `expel-column` are automatically strip-scoped because they use `scroll/context` which returns strip-local `:cols`

When `move-to-strip` moves a window, `:column` is reset to nil. The `assign` function places it after the focused column in the target strip on the next frame.

### Edge cases

- **Last window leaves a strip**: Strip disappears. `group-strips` normalization renumbers remaining strips to be contiguous. Orphaned scroll-offset keys (e.g., `:scroll-offset-s2` when strip 2 no longer exists) are cleaned up by pruning keys with strip indices >= num-strips.
- **All windows in one strip**: Degenerate to single strip. Identical to pre-strips.
- **Empty strip between populated strips**: Cannot happen -- `group-strips` normalizes to contiguous.
- **Column assignment on strip move**: Reset to nil, assigned by `assign` on next frame.
- **Tabbed column interaction**: Tab cycling (Phase 1) takes priority over strip-crossing. Focus-up/down in a tabbed column always cycles tabs, never crosses strips.

### Normalization

Strip-weight normalization follows the col-width pattern:

```janet
(each strip-cols strips
  (def weight (or ((first (first strip-cols)) :strip-weight) 1.0))
  (each col strip-cols
    (each win col (put win :strip-weight weight))))
```

### Persistence

Add `:strip` and `:strip-weight` to `persist/serialize` win-data and `persist/restore-window`. Layout-params strip keys are automatically persisted (the existing `filter-anim-keys` already filters `-anim` suffixes).

### Files changed (Phase 2)

| File | Changes |
|------|---------|
| `src/layout/scroll.janet` | Add `group-strips`, `strip-heights`, strip normalization. Refactor `layout` into outer loop + `layout-strip`. Restructure `context` and `navigate` for strips. Add orphaned key cleanup. |
| `src/actions.janet` | Add `move-to-strip` and `resize-strip`. Add `:strip`/`:strip-weight` to swap. Scope `expel-column` max-col to strip. |
| `src/persist.janet` | Serialize/restore `:strip`, `:strip-weight`. |
| `src/window.janet` | Clear `:strip`, `:strip-weight` in `set-float`. |
| `src/ipc.janet` | Extend layout topic with strip count. |
| `test/scroll.janet` | Strip grouping, height allocation, navigation, degenerate case tests. |

Estimated: ~150-200 lines of new/modified code.

### User stories (Phase 2)

**Story 7: Create a second strip**
> I have 4 scroll columns. I focus a terminal in column 2 and press `Mod+Shift+J`. The screen splits horizontally: top strip has 3 columns, bottom strip has 1 column with the terminal. Both scroll independently.

**Story 8: Navigate between strips**
> I'm at the bottom row of a split column in the top strip. I press `Mod+J` (focus-down). Focus jumps to the top of the same column position in the bottom strip.

**Story 9: Resize strip height**
> I have two strips. I press `Mod+Ctrl+J` (resize-strip -0.1). The focused strip shrinks, the other grows.

**Story 10: Strip destruction**
> Bottom strip has one window. I press `Mod+Shift+K` (move-to-strip :up). Window moves to top strip. Bottom strip disappears. Layout returns to single full-height strip.

### Test strategy (Phase 2)

1. `group-strips`: single strip, two strips, normalization of non-contiguous indices
2. `strip-heights`: equal weights, unequal weights, single strip
3. Layout: single strip produces identical output to pre-strips code
4. Layout: two strips, windows positioned in correct vertical regions, no overlap
5. Layout: per-strip scroll independence
6. Navigation: down crosses strip boundary to top of next strip
7. Navigation: up crosses strip boundary to bottom of previous strip
8. Navigation: left/right never cross strips
9. Navigation: tabbed column prevents strip-crossing (cycling takes priority)
10. `move-to-strip`: creates new strip, column reset
11. `move-to-strip`: last window leaves strip, strip disappears
12. Persistence round-trip for `:strip` and `:strip-weight`

---

## 7. Phase 3: Sublayouts

### Overview

A scroll column can delegate its internal window arrangement to any existing layout algorithm. Instead of the default vertical split (or tabbed stacking), the column's windows are arranged by `:dwindle`, `:grid`, `:master-stack`, `:centered-master`, or `:monocle` within the column's bounding rectangle.

### Data model

Two new window properties:

- **`:col-sublayout`** (keyword or nil, default nil) -- Which layout algorithm to use. When set, overrides `:col-mode` for rendering. When nil, `:col-mode` controls rendering as usual.

- **`:col-sublayout-params`** (table or nil) -- Algorithm-specific parameters. Contents depend on the sublayout:
  - `:master-stack` / `:centered-master`: `@{:main-ratio 0.55 :main-count 1}`
  - `:dwindle`: `@{:dwindle-ratio 0.5 :dwindle-ratios @{}}`
  - `:grid` / `:monocle`: `@{}` or nil (no params needed)

Sublayout params are stored as a single table rather than individual properties. This reduces property count and simplifies swap, set-float, expel, and persistence (one property to manage instead of four).

All windows in a column carry the same `:col-sublayout` and `:col-sublayout-params` values, following the `:col-width` pattern. Normalization propagates from `(first col)`.

### Relationship between `:col-mode` and `:col-sublayout`

`:col-sublayout` is **orthogonal** to `:col-mode`. When set, it overrides `:col-mode` for rendering. The `:col-mode` is preserved underneath so that clearing the sublayout restores the prior mode.

- `toggle-column-mode` cycles `:split` / `:tabbed` (unchanged). When a sublayout is active, `toggle-column-mode` first clears the sublayout, then continues cycling from the underlying `:col-mode`.
- `set-column-sublayout :dwindle` sets the sublayout explicitly.
- `set-column-sublayout nil` clears it, reverting to `:col-mode`.

`:monocle` sublayout reuses the tabbed rendering path (one visible window, rest hidden, tracked by `:col-active`). This means `:col-active` normalization must fire when `(= sublayout :monocle)`, not only when `(= mode :tabbed)`.

### Normalization extension

After existing Phase 1 normalization:

```janet
(each col cols
  # ... Phase 1: col-mode, then col-active ...

  # Phase 3: sublayout normalization
  (def sublayout ((first col) :col-sublayout))
  (def sublayout-params ((first col) :col-sublayout-params))
  (each win col
    (put win :col-sublayout sublayout)
    (put win :col-sublayout-params sublayout-params))

  # Extend col-active condition to include monocle sublayout
  (when (or (= mode :tabbed) (= sublayout :monocle))
    # ... existing col-active normalization (ensure exactly one active) ...
    ))
```

**Normalization order across all phases:**
1. Strip-weight (Phase 2) -- independent, can run first
2. col-mode (Phase 1) -- propagate from first window
3. col-sublayout + col-sublayout-params (Phase 3) -- propagate from first window
4. col-active (Phase 1, extended) -- fires when `tabbed` OR `monocle sublayout`

### Layout delegation

In the column rendering loop, check for sublayout before split/tabbed:

```janet
(for ci 0 num-cols
  (def col (get cols ci))
  (def cw (col-width col content-w default-ratio))
  (def x-off (- (+ inner (get col-xs ci)) scroll))
  (def sublayout ((first col) :col-sublayout))

  (if sublayout
    # Sublayout delegation
    (let [col-x (+ (usable :x) outer x-off)
          col-y (+ (usable :y) outer)]
      (if (or (<= (+ col-x cw) clip-left) (>= col-x clip-right))
        # Column off-screen: hide all windows
        (each win col
          (array/push results {:window win :hidden true :scroll-placed true}))
        (if (= sublayout :monocle)
          # Monocle: reuse tabbed rendering (one visible, rest hidden)
          (each win col
            (if (win :col-active)
              (array/push results
                {:window win :x (+ col-x inner) :y (+ col-y inner)
                 :w (- cw (* 2 inner)) :h (- total-h (* 2 inner))
                 :scroll-placed true})
              (array/push results
                {:window win :hidden true :scroll-placed true})))
          # Other sublayouts: delegate to layout function
          (let [sub-fn (get layout/layout-fns sublayout)
                sub-usable {:x col-x :y col-y :w cw :h total-h}
                sub-params (build-sublayout-params col sublayout config)
                sub-config (merge config {:outer-padding 0})]
            (each sr (sub-fn sub-usable col sub-params sub-config focused now)
              (array/push results (merge sr {:scroll-placed true})))))))

    # Existing split/tabbed logic
    (do ...)))
```

The `build-sublayout-params` helper:

```janet
(defn- build-sublayout-params [col sublayout config]
  (def p (or ((first col) :col-sublayout-params) @{}))
  (case sublayout
    :master-stack @{:main-ratio (or (p :main-ratio) (config :main-ratio))
                    :main-count (or (p :main-count) (config :main-count))}
    :centered-master @{:main-ratio (or (p :main-ratio) (config :main-ratio))
                       :main-count (or (p :main-count) (config :main-count))}
    :dwindle @{:dwindle-ratio (or (p :dwindle-ratio) (config :dwindle-ratio))
               :dwindle-ratios (or (p :dwindle-ratios) @{})}
    :grid @{}
    :monocle @{}
    @{}))
```

### Navigation

Sublayout navigation uses a two-tier dispatch: try the sublayout's navigate function first, bubble out on nil. The complete priority chain (documented in Phase 2) applies:

```janet
# In navigate, for :down direction:
(let [col (get cols my-col)
      sublayout ((first col) :col-sublayout)
      mode (or ((first col) :col-mode) :split)]
  (cond
    # Tier 1: sublayout navigate (non-monocle)
    (and sublayout (not= sublayout :monocle))
    (let [nav-fn (get layout/navigate-fns sublayout)
          local-idx my-row
          n-col (length col)
          sub-mc (or (get-in col [0 :col-sublayout-params :main-count]) 1)]
      (if-let [sub-target (if nav-fn
                            (nav-fn n-col sub-mc local-idx dir nil)
                            # No navigate fn (dwindle): use geometry fallback
                            (geometry-navigate-sublayout col sublayout config dir focused))]
        (index-of (get col sub-target) tiled)
        # Bubble out: try strip-crossing
        (strip-cross-down ctx tiled)))

    # Tier 2: tabbed or monocle-sublayout (cycle, wrap, never bubble)
    (or (= mode :tabbed) (= sublayout :monocle))
    (when (> (length col) 1)
      (let [active-idx (or (find-index |($ :col-active) col) 0)
            next-idx (% (+ active-idx 1) (length col))]
        (each win col (put win :col-active false))
        (put (get col next-idx) :col-active true)
        (index-of (get col next-idx) tiled)))

    # Tier 3: split, within-column or strip-crossing
    (if (< (+ my-row 1) (length col))
      (index-of (get col (+ my-row 1)) tiled)
      (strip-cross-down ctx tiled))))
```

Key distinction: **monocle sublayout wraps** (like tabbed), **other sublayouts bubble out** (nil triggers strip-crossing). This matches user expectations: monocle is a "show one at a time" mode like tabs, while master-stack/dwindle/grid are spatial layouts where hitting an edge should let you escape.

For dwindle (which has no navigate function), use geometry-based navigation within the column:

```janet
(defn- geometry-navigate-sublayout [col sublayout config dir focused]
  (let [sub-fn (get layout/layout-fns sublayout)
        # Compute sublayout geometry for current column bounds
        # (requires column rect -- passed from the outer navigate context)
        sub-results (sub-fn sub-usable col sub-params sub-config focused)]
    (when-let [local-i (index-of focused col)]
      (layout/navigate-by-geometry sub-results local-i dir))))
```

### Complete action semantics matrix

| Action | :split | :tabbed | :dwindle | :grid | :master-stack | :centered-master | :monocle |
|--------|--------|---------|----------|-------|---------------|-----------------|----------|
| focus-up/down | move rows | cycle tabs (wrap) | geometry navigate; bubble to strip | grid navigate; bubble to strip | sublayout navigate; bubble to strip | sublayout navigate; bubble to strip | cycle (wrap, like tabbed) |
| focus-left/right | change columns | change columns | geometry navigate; bubble to adjacent column | grid navigate; bubble to adjacent column | sublayout navigate; bubble to adjacent column | sublayout navigate; bubble to adjacent column | change columns (always bubble) |
| resize-window | adjust col-weight | no-op | no-op (use adjust-ratio) | no-op | no-op (use adjust-ratio) | no-op (use adjust-ratio) | no-op |
| adjust-ratio | adjust default col-width | adjust default col-width | adjust col dwindle-ratio | no-op | adjust col main-ratio | adjust col main-ratio | no-op |
| adjust-main-count | (N/A) | (N/A) | no-op | no-op | adjust col main-count | adjust col main-count | no-op |
| equalize | reset col-weights | no-op | reset dwindle ratios | no-op | reset main-ratio to default | reset main-ratio to default | no-op |
| consume | add row | add tab | append to sublayout | append (grid gains cell) | append to stack | append to side stacks | add hidden (like tab) |
| expel | remove row | remove tab | remove from sublayout | remove (grid loses cell) | remove from column | remove from column | remove (like tab) |
| resize-column | change col-width | change col-width | change col-width | change col-width | change col-width | change col-width | change col-width |

### Actions

**New action:**

```janet
(defn set-column-sublayout
  "Action: set the sublayout for the focused scroll column."
  [sublayout-kw]
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (each win col
        (put win :col-sublayout sublayout-kw)
        (when (nil? sublayout-kw)
          (put win :col-sublayout-params nil))
        (when (= sublayout-kw :monocle)
          (put win :col-active (= win (seat :focused))))))))
```

**Modified actions:**

`toggle-column-mode`: when sublayout is active, clears it first:

```janet
(defn toggle-column-mode []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (if ((first col) :col-sublayout)
        # Clear sublayout, revert to underlying col-mode
        (each win col
          (put win :col-sublayout nil)
          (put win :col-sublayout-params nil))
        # Normal toggle
        (let [current (or ((first col) :col-mode) :split)
              new-mode (if (= current :tabbed) :split :tabbed)]
          (each win col
            (put win :col-mode new-mode)
            (when (= new-mode :tabbed)
              (put win :col-active (= win (seat :focused))))))))))
```

`adjust-ratio`: dispatches to sublayout-specific ratio when inside sublayout column:

```janet
(defn adjust-ratio [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (if-let [col (scroll/focused-column seat)
               sublayout ((first col) :col-sublayout)]
        # Sublayout ratio adjustment
        (let [p (or ((first col) :col-sublayout-params) @{})
              new-p (table/clone p)]
          (case sublayout
            :master-stack
            (put new-p :main-ratio (max 0.1 (min 0.9 (+ (or (p :main-ratio) (state/config :main-ratio)) delta))))
            :centered-master
            (put new-p :main-ratio (max 0.1 (min 0.9 (+ (or (p :main-ratio) (state/config :main-ratio)) delta))))
            :dwindle
            (when-let [w (seat :focused)
                       li (index-of w col)]
              (when (< li (- (length col) 1))
                (def ratios (or (new-p :dwindle-ratios) @{}))
                (def new-ratios (table/clone ratios))
                (def current (or (get new-ratios li) (or (p :dwindle-ratio) (state/config :dwindle-ratio))))
                (put new-ratios li (max 0.1 (min 0.9 (+ current delta))))
                (put new-p :dwindle-ratios new-ratios))))
          (each win col (put win :col-sublayout-params new-p)))
        # Not in sublayout: existing behavior
        (do ... existing adjust-ratio logic ...)))))
```

`adjust-main-count`: adjusts sublayout main-count when applicable:

```janet
(defn adjust-main-count [delta]
  (fn [seat binding]
    (when-let [o (seat :focused-output)]
      (if-let [col (scroll/focused-column seat)
               sublayout ((first col) :col-sublayout)]
        (when (or (= sublayout :master-stack) (= sublayout :centered-master))
          (def p (or ((first col) :col-sublayout-params) @{}))
          (def new-p (table/clone p))
          (put new-p :main-count (max 1 (+ (or (p :main-count) (state/config :main-count)) delta)))
          (each win col (put win :col-sublayout-params new-p)))
        (do ... existing adjust-main-count logic ...)))))
```

`resize-window`: no-op for sublayout columns:

```janet
(defn resize-window [delta]
  (fn [seat binding]
    (when-let [w (seat :focused)
               col (scroll/focused-column seat)]
      (unless ((first col) :col-sublayout)
        (when (> (length col) 1)
          (put w :col-weight (max 0.1 (+ (or (w :col-weight) 1.0) delta))))))))
```

`equalize-column`: resets sublayout params to defaults:

```janet
(defn equalize-column []
  (fn [seat binding]
    (when-let [col (scroll/focused-column seat)]
      (if ((first col) :col-sublayout)
        (each win col (put win :col-sublayout-params nil))
        (each win col (put win :col-weight nil))))))
```

`expel-column`: clears sublayout properties on expelled window:

```janet
# In expel-column, after setting new column:
(put w :col-sublayout nil)
(put w :col-sublayout-params nil)
```

### Edge cases

- **Sublayout with 1 window**: All sublayout functions handle n=1 (single window fills area). Visually identical to `:split` with 1 window. Mode preserved for when more windows are added.
- **Changing sublayout type (dwindle→grid)**: Old params in `:col-sublayout-params` are ignored by the new sublayout. If switching back, preserved params take effect again.
- **Consume into sublayout column**: Consumed window gets `:col-sublayout` synced from `(first col)` by normalization. The sublayout re-renders with the additional window.
- **Monocle sublayout + tabbed mode**: `:col-sublayout` overrides `:col-mode`. Monocle rendering shows one window. Clearing sublayout reverts to `:col-mode` (which might be `:tabbed` -- same visual behavior, different border color).
- **Sublayout inside a strip**: Composes naturally. Strip determines column height, sublayout fills it.

### Persistence

Add `:col-sublayout` and `:col-sublayout-params` to serialization/restoration. JDN handles nested tables correctly.

### Files changed (Phase 3)

| File | Changes |
|------|---------|
| `src/layout/scroll.janet` | Sublayout delegation in layout. Extend normalization. Two-tier navigation dispatch with geometry fallback. `build-sublayout-params` helper. Monocle special-case rendering. |
| `src/actions.janet` | Add `set-column-sublayout`. Modify `toggle-column-mode`, `adjust-ratio`, `adjust-main-count`, `resize-window`, `equalize-column`, `expel-column` for sublayout awareness. |
| `src/persist.janet` | Serialize/restore `:col-sublayout`, `:col-sublayout-params`. |
| `src/window.janet` | Clear sublayout properties in `set-float`. |
| `src/pipeline.janet` | Add sublayout param validation in `sanitize`. |
| `src/ipc.janet` | Extend tabs topic with sublayout info per column. |
| `test/scroll.janet` | Sublayout delegation, navigation, bubble-out, monocle, consume/expel tests. |

Estimated: ~200-250 lines of new/modified code.

### User stories (Phase 3)

**Story 11: Master-stack column**
> I have 4 terminals in a column. I press `Mod+Shift+M` (set-column-sublayout :master-stack). The column shows one large terminal on the left, three stacked on the right. I press `Mod+L` (adjust-ratio) to widen the master. Focus-left from the master area exits to the adjacent scroll column.

**Story 12: Dwindle column**
> I have 5 documentation windows. I press `Mod+D` (set-column-sublayout :dwindle). Windows arrange in alternating splits. Focus-down moves to the nearest window below (geometry-based). At the bottom edge, focus-down crosses to the strip below.

**Story 13: Grid for monitoring**
> I have 6 htop windows. I press `Mod+G` (set-column-sublayout :grid). The column shows a 3x2 grid. At the left edge of the grid, focus-left exits to the adjacent scroll column.

**Story 14: Revert sublayout**
> A column has master-stack sublayout. I press `Mod+T` (toggle-column-mode). The sublayout clears. The column returns to its previous `:col-mode` with original weights preserved.

### Test strategy (Phase 3)

1. Sublayout delegation: master-stack in column produces correct geometry
2. Normalization: syncs `:col-sublayout` and `:col-sublayout-params` across column
3. Navigation: sublayout navigate + bubble-out to adjacent column
4. Navigation: sublayout navigate + bubble-out to strip-crossing
5. Navigation: monocle wraps (never bubbles)
6. Navigation: dwindle geometry fallback
7. Monocle shows one window, hides rest (like tabbed)
8. Consume into sublayout column: window gets sublayout synced
9. Expel from sublayout: cleared sublayout properties
10. Changing sublayout type preserves old params
11. Clearing sublayout reverts to col-mode
12. adjust-ratio dispatches to sublayout-specific param

---

## 8. User Stories

### Phase 1: Tabbed Columns

**Story 1: Create a tabbed column**
> I have 3 browser windows in a scroll column. I press `Mod+T` (bound to `toggle-column-mode`). Now I see one browser window filling the column. I press `Mod+J` (focus-down) to cycle to the next tab. I see a different browser window. The column has a different border color indicating tabbed mode.

**Story 2: Add a window to a tabbed column**
> I have a tabbed column on the left and a regular column on the right. I focus a window in the right column and press `Mod+Shift+H` (consume-left). My window joins the tabbed column as a new tab.

**Story 3: Remove a window from a tabbed column**
> I'm focused on a tab. I press `Mod+Shift+E` (expel-column). My window becomes its own column to the right. The tabbed column still has the remaining tabs.

**Story 4: Switch back to split**
> I have a tabbed column showing one window. I press `Mod+T` again. All windows in the column become visible, stacked vertically as rows. Their previous `:col-weight` values are preserved, so the split looks the same as before I tabbed.

**Story 5: Close active tab**
> I'm viewing tab 2 of 4. I close the window. The normalization pass finds zero active windows and activates the first window in the column (tab 1). The column still has 3 tabs. (Note: "activate adjacent tab" would be better UX. The normalization should prefer the window at the closed window's former index, clamped, rather than always `(first col)`. See implementation notes.)

**Story 6: Persist across restart**
> I have a tabbed column. I restart tidepool. My windows are restored to the same column with the same mode. The previously-active tab might not be the same window (if app-id+title match is ambiguous), but the column is still tabbed.

### Phase 2: Strips (when shipped)

**Story 7: Create a second scroll strip**
> I press `Mod+Shift+J` (move-to-strip :down). My focused window moves to a new strip below. The screen splits vertically -- top strip has my remaining columns, bottom strip has one column with the moved window.

**Story 8: Navigate between strips**
> I'm at the bottom row of a column in the top strip. I press `Mod+J` (focus-down). Focus jumps to the top of the same column position in the bottom strip.

---

## 9. Structural Cleanup (Phase 0)

These refactors are prerequisites for the three feature phases. They fix existing abstraction problems that would otherwise compound as new properties and behaviors are added. Each is small, independent, and directly unblocks cleaner feature code.

### 9.1 `layout-props` — single source of truth for layout properties

**Problem:** Layout-relevant window properties (`:column`, `:col-width`, `:col-weight`) are independently listed in 4+ places that must stay in sync: `window/set-float` (clears them), `swap` action (exchanges them), `persist/serialize` (saves them), `persist/restore-window` (restores them), `pipeline/sanitize` (validates them). Adding 6 new properties across 3 phases means touching all these places independently each time.

**Fix:** Define a single array in `layout/init.janet` (not scroll — these are layout-system-level concepts, not scroll-specific):

```janet
(def layout-props
  "Window properties managed by the layout system.
  Used by swap, set-float, persist, and sanitize."
  @[:column :col-width :col-weight])
```

Each phase appends to this array (Phase 1: `:col-mode` `:col-active`, Phase 2: `:strip` `:strip-weight`, Phase 3: `:col-sublayout` `:col-sublayout-params`).

Consumers iterate it:

```janet
# window.janet:set-float — clear all layout props
(each prop layout/layout-props (put window prop nil))

# actions.janet:swap — exchange all layout props
(each prop layout/layout-props
  (def tmp (w prop))
  (put w prop (t prop))
  (put t prop tmp))

# persist.janet:serialize — save all layout props
(each prop layout/layout-props
  (when (w prop) (put win-data prop (w prop))))

# persist.janet:restore-window — restore all layout props
(each prop layout/layout-props
  (when (saved prop) (put window prop (saved prop))))
```

**Impact:** `swap` goes from 18+ lines to 4. Adding a new property is one line in one place.

### 9.2 Simplify navigation — `context-fns` dispatch table + uniform signature

**Problem:** Two related issues:

1. Navigation functions take `(nav-fn n main-count i dir ctx)` where `n`, `main-count`, and `i` are redundant with information available in `ctx`. Scroll ignores all three. The signature exists because master-stack needed them, and every other layout conforms.

2. The `target` function in `actions.janet` has a scroll-specific special case to build context (`when (= lo :scroll) (scroll/context ...)`). This privileges scroll as "the layout that needs context" when really every layout should be able to provide its own context.

**Fix:** Two changes:

**A. Add `context-fns` dispatch table** alongside `layout-fns` and `navigate-fns`:

```janet
(def context-fns
  "Context-building function dispatch table.
  Each returns a context table for navigation, or nil."
  @{:scroll scroll/context-fn})
```

The `target` function becomes layout-agnostic:

```janet
(def ctx-fn (get layout/context-fns lo))
(def nav-ctx
  (if ctx-fn
    (ctx-fn o windows w (seat :focus-prev))
    @{:windows tiled :focused w :focused-idx ti
      :main-count (get-in o [:layout-params :main-count] 1)}))
```

No layout is special-cased by name. Any layout can register a context builder.

**B. Simplify navigate signature to `(nav-fn dir ctx)`**. Each layout extracts what it needs from context:

```janet
# Standard navigation context fields:
# :windows — array of tiled windows in scope
# :focused — focused window
# :focused-idx — index of focused window in :windows
# For scroll, additional fields: :cols, :strips, etc.

# master-stack:
(defn navigate [dir ctx]
  (def {:windows ws :focused-idx i} ctx)
  (def n (length ws))
  (def main-count (or (ctx :main-count) 1))
  ...)

# monocle:
(defn navigate [dir ctx]
  (def {:windows ws :focused-idx i} ctx)
  (def n (length ws))
  ...)

# grid, centered-master: similar extraction
```

**Impact:** Removes the scroll special-case in `target`. Any layout can provide rich context for navigation without being hard-coded. Makes sublayout navigation dispatch (Phase 3) natural — sublayouts receive a context scoped to their column.

### 9.3 `padded-rect` — eliminate layout boilerplate

**Problem:** Every layout function starts with the same 4-line preamble computing `outer`, `inner`, `total-w`, `total-h` from `usable` and `config`. This is repeated in 6 files.

**Fix:** Add a helper to `layout/init.janet`:

```janet
(defn padded-rect
  "Compute the content rectangle with padding applied."
  [usable config]
  (def outer (config :outer-padding))
  (def inner (config :inner-padding))
  {:x (+ (usable :x) outer) :y (+ (usable :y) outer)
   :w (max 0 (- (usable :w) (* 2 outer)))
   :h (max 0 (- (usable :h) (* 2 outer)))
   :inner inner})
```

Each layout calls `(def r (layout/padded-rect usable config))` and uses `(r :x)`, `(r :w)`, `(r :inner)` etc. The sublayout delegation in Phase 3 needs exactly this — it constructs a sub-usable rect for the column bounds and calls `(padded-rect sub-usable sub-config)`.

**Impact:** Removes ~18 lines of duplicated boilerplate across 6 layout files. Required for Phase 3 sublayout delegation anyway.

### 9.4 Column operations by context, not layout check

**Problem:** Six actions in `actions.janet` guard with `(when (= (o :layout) :scroll) ...)`: `consume-column`, `expel-column`, `resize-column`, `resize-window`, `equalize-column`, `preset-column-width`. These are really column-level operations that should work whenever the focused window has column context, not just when the output's top-level layout is `:scroll`.

Additionally, `scroll/focused-column` in `actions.janet` is hard-coded to check `(= (o :layout) :scroll)`. This should use the `context-fns` dispatch table instead.

**Fix:** Generalize `focused-column` to use context dispatch:

```janet
(defn- focused-column [seat]
  (when-let [o (seat :focused-output)
             ctx-fn (get layout/context-fns (o :layout))
             ctx (ctx-fn o (state/wm :windows) (seat :focused) (seat :focus-prev))]
    (get (ctx :cols) (ctx :focused-col))))
```

Then remove all `(when (= (o :layout) :scroll) ...)` guards from column actions — `focused-column` returns nil when the layout doesn't support columns, which is the right behavior.

```janet
# Before (consume-column):
(when (= (o :layout) :scroll)
  (when-let [ctx (scroll/context o ...)] ...))

# After:
(when-let [ctx-fn (get layout/context-fns (o :layout))
           ctx (ctx-fn o ...)] ...)
```

**Impact:** Removes 6 redundant layout-type guards. No action mentions `:scroll` by name. Any future layout that provides columns (by registering a context-fn) gets column operations for free.

### 9.5 Implementation order

Phase 0 cleanup should be done **first**, before Phase 1 features:

1. Add `layout-props` array, refactor `swap`, `set-float`, `persist`, `sanitize` to use it
2. Add `padded-rect`, refactor all 6 layout files to use it
3. Simplify navigation signature across all 5 navigate functions + dispatch
4. Remove layout-type guards from column actions

Each step is independently testable — existing tests should pass after each refactor (behavior unchanged).

---

## 10. Feature Implementation Notes

### Normalization placement

Normalization should happen inside `scroll/layout` (or a helper called by it), NOT in `scroll/group` or `scroll/assign`. Reasoning:

- `group` calls `assign`, which already mutates window `:column` values as a side effect. So `group` is not pure. However, normalization in `group` would fire on every call to `context` (used by navigation and `focused-column` queries), adding unnecessary work.
- Normalization is idempotent, so running it in `layout` (once per frame) is sufficient. Running it in `group` (multiple times per frame via `context` calls) wastes cycles.
- Normalization should happen after `group` returns columns but before layout computation.

### Smarter active-tab recovery on close

The basic normalization activates `(first col)` when no window is active. A better approach: track the closed window's former index and activate the window at that index (clamped to column length). This requires either:
- Storing the active tab's index in a transient variable before the close lifecycle runs, or
- Using the focused window: when a tab closes, the pipeline re-focuses (via `seat/manage`), and the newly-focused window in the column should become active.

The second approach is more robust. After normalization detects `active-count = 0`, check if the globally focused window is in this column (it will be if the pipeline re-focused correctly). If so, activate it. If not, activate the last window in the column (closest to where the closed tab was).

### Vertical scroll key fragility (pre-existing)

The scroll layout uses `(keyword (string "scroll-y-" ci))` for per-column vertical scroll state, keyed by positional column index. When columns are consumed/expelled and indices shift, vertical scroll state for column N applies to a different column. This is a pre-existing issue but becomes more visible with tabbed columns (where consume/expel is a primary workflow). A future fix: key vertical scroll state by a stable identifier rather than positional index. This is not blocking for Phase 1 but should be tracked.

### Animation interaction

Hidden tab windows should NOT get close animations. In `window/manage-start`, check `(w :col-active)` or `(w :layout-hidden)` before starting close animations for windows in tabbed columns.

New tabs should NOT get open animations (they appear instantly when the column mode changes or when cycling). The existing animation trigger in `pipeline/start-animations` checks `(w :new)` -- windows that were already placed won't re-animate.

### Clipping interaction

Hidden tab windows get `{:hidden true :scroll-placed true}` from the layout. The pipeline's `compute-visibility` (pipeline.janet:127-136) already handles `:layout-hidden` -- hidden windows are not shown. The existing scroll clipping logic (`window/clip-to-output`) checks `:scroll-placed` and uses output-edge clipping. Tab windows are either fully visible (active tab, standard scroll clipping) or fully hidden (inactive tab), so no new clipping logic is needed.

### IPC ordering

The tabs IPC topic should emit after layout computation (so column indices are stable for the current frame) but before lifecycle-finish (so window titles are current). Place it in `pipeline/manage` after `layout/apply` and before `lifecycle-finish`, alongside the existing `ipc/emit-events` call.

### Test strategy

New test cases for `test/scroll.janet`:

1. **Tabbed layout**: single column, 3 windows, `:col-mode :tabbed` -- verify 1 visible + 2 hidden
2. **Normalization: mode sync**: windows with mismatched `:col-mode` values -- verify normalization
3. **Normalization: active count**: tabbed column with 0 active windows -- verify one gets activated
4. **Normalization: active count**: tabbed column with 2 active windows -- verify reduced to 1
5. **Navigation: tab cycling**: focus-down in tabbed column -- verify active tab changes
6. **Navigation: enter tabbed from outside**: focus-left into tabbed column -- verify active tab focused
7. **Consume into tabbed**: window consumed into tabbed column -- verify it becomes a tab
8. **Expel from tabbed**: window expelled from tabbed column -- verify new column is split mode

---

## 11. Open Questions

### 10.1 Tab bar rendering priority

Should we invest in tab bar surfaces (Phase 1.5/2) or is IPC-based external rendering sufficient? This depends on user feedback after Phase 1 ships. If users consistently report confusion about which tabs exist, a built-in tab bar is needed. If status bar integration suffices, skip it.

### 10.2 Single-window tabbed columns

If a tabbed column is reduced to one window (via close or expel), should it auto-switch to `:split` mode? Arguments for: `:tabbed` with one window is visually identical to `:split` with one window, and carrying the mode creates no user benefit. Arguments against: the user explicitly chose tabbed mode; auto-switching loses that intent if they're about to add more windows.

Recommendation: keep tabbed mode. The border color indicator tells the user it's still tabbed. If they want split, they toggle.

### 10.3 Column mode and `:col-weight` preservation

When a tabbed column switches to split, should the previously-hidden windows retain their `:col-weight` values? This design says yes -- weights are preserved through mode changes. This means a user can fine-tune row heights, switch to tabbed for space, and switch back with heights preserved.

### 10.4 Stable column identity (future)

If Phase 3 (sublayouts) is pursued, the "column metadata keyed by column index" problem will force a decision: per-frame key remapping, or stable column IDs. This decision is intentionally deferred. The Phase 1 and Phase 2 designs do not require stable column identity.

### 10.5 Strips interaction with tabs

In Phase 2, can a column in one strip be tabbed while the same-index column in another strip is split? Yes -- strip and column mode are independent. Each column's `:col-mode` applies to that specific (strip, column) group of windows.

### 10.6 Multi-select and batch operations

Sway allows selecting multiple windows and grouping them. Should we support "select these 3 windows and make them a tabbed column"? This is a nice-to-have but not part of the core design. The consume/expel workflow achieves the same result through sequential operations.
