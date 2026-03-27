# tidepool

**Work in progress.** APIs, config format, and behavior will change.

Window manager for [River](https://codeberg.org/river/river) (0.4+), written in
[Janet](https://janet-lang.org/). Handles layout, focus, keybindings, borders,
and output configuration via River's window management protocol. Configured with
a Janet init script.

## Building

Requires Zig 0.15+ and system libraries: `wayland`, `libxkbcommon`, `libffi`,
`libxml2`, `expat`.

```sh
zig build
```

### Nix

```sh
# overlay.nix provides a package overlay
# package.nix can be called directly with callPackage
nix build
```

## Usage

tidepool connects to a running River compositor and takes over window
management. Config is read from `$XDG_CONFIG_HOME/tidepool/init.janet` (or pass
a path as the first argument).

```sh
tidepool [init-path]
```

A netrepl server is created at `$XDG_RUNTIME_DIR/tidepool-$WAYLAND_DISPLAY` for
live interaction.

### tidepoolmsg

CLI client for the netrepl socket.

```sh
tidepoolmsg repl                         # interactive REPL
tidepoolmsg eval '<expression>'          # evaluate Janet expression
tidepoolmsg action focus left            # execute a named action
tidepoolmsg bindings                     # list all keybindings as JSON
tidepoolmsg watch tags layout title      # stream updates as JSON lines
tidepoolmsg save > layout.jdn            # serialize state to stdout
tidepoolmsg load < layout.jdn            # restore state from stdin
tidepoolmsg completions bash             # output shell completions (bash/zsh/fish)
```

## Layouts

Each output has an active layout that determines how tiled windows are arranged.
Layouts are switched per-output with `cycle-layout` or `set-layout`.

| Layout         | Arrangement                                            |
| -------------- | ------------------------------------------------------ |
| `master-stack` | One primary window + vertical stack                    |
| `grid`         | Equal-sized grid                                       |
| `dwindle`      | Recursive alternating splits                           |
| `scroll`       | Horizontally scrollable columns with vertical stacking |
| `tabbed`       | One window visible at a time                           |

### Scroll layout

The default layout. Windows are arranged in columns that scroll horizontally.
Each column can contain multiple windows stacked vertically (adjusted with
`consume-column`/`expel-column`). Column widths are individually adjustable.

Scroll supports multiple rows — independent horizontal scroll strips stacked
vertically. Only one row is visible at a time. Focusing up/down past column
edges crosses between rows. Swapping a window past the last row creates a new
one; empty rows are automatically pruned.

### Tags

Each output has a set of active tags (1-9). Windows are assigned to a tag and
are visible when their tag is active on an output. Tag 0 is the scratchpad.
Per-tag layout and parameters are saved/restored when switching tags.

## Configuration

The init script runs in the tidepool environment with `config` and `wm` tables
available. Set values on `config` and push bindings onto
`(config :xkb-bindings)` and `(config :pointer-bindings)`.

### Config keys

| Key                    | Default                 | Description                                   |
| ---------------------- | ----------------------- | --------------------------------------------- |
| `:default-layout`      | `:scroll`               | Layout for new tags                           |
| `:column-width`        | `0.5`                   | Default scroll column width as fraction       |
| `:column-presets`      | `[0.333 0.5 0.667 1.0]` | Preset widths for scroll columns              |
| `:border-width`        | `4`                     | Border thickness in pixels                    |
| `:outer-padding`       | `4`                     | Gap between windows and output edge           |
| `:inner-padding`       | `8`                     | Gap between windows                           |
| `:border-focused`      | `0xffffff`              | Focused border color                          |
| `:border-normal`       | `0x646464`              | Unfocused border color                        |
| `:border-urgent`       | `0xff0000`              | Urgent border color                           |
| `:border-tabbed`       | `0x88aaff`              | Tabbed group border color                     |
| `:border-sibling`      | `0x88aaff`              | Sibling window border color                   |
| `:animate`             | `true`                  | Enable animations                             |
| `:animation-duration`  | `0.2`                   | Animation duration in seconds                 |
| `:warp-pointer`        | `false`                 | Warp pointer to focused window                |
| `:focus-follows-mouse` | `false`                 | Focus window under pointer                    |
| `:xcursor-theme`       | `"Adwaita"`             | Cursor theme name                             |
| `:xcursor-size`        | `24`                    | Cursor size                                   |
| `:debug`               | `false`                 | Frame profiling and verbose logging to stderr |
| `:rules`               | `@[]`                   | Window match rules                            |
| `:outputs`             | --                      | Output configuration map                      |

### Keybindings

```janet
(array/push (config :xkb-bindings)
  [:Return {:mod4 true} (action/spawn ["foot"])]
  [:h {:mod4 true} (action/focus :left)]
  [:l {:mod4 true} (action/focus :right)]
  [:q {:mod4 true :shift true} (action/close)])
```

Format: `[keysym modifiers action-fn]`. Modifiers: `:mod4`, `:shift`, `:ctrl`,
`:mod1` (alt).

### Window rules

```janet
(array/push (config :rules)
  {:app-id "firefox" :title "Library" :float true}
  {:app-id "mpv" :tag 5})
```

Windows with fixed min/max size constraints are automatically floated.

### Output configuration

```janet
(put config :outputs
  @{"DP-1" @{:mode [2560 1440] :pos [0 0] :scale 1}
    "HDMI-A-1" @{:mode [1920 1080] :pos [2560 0] :scale 1}
    "eDP-1" @{:enable false}})
```

Applied via `zwlr_output_manager_v1` on startup.

## Actions

All actions return tagged tables (`@{:fn <closure> :name :desc :args}`) for use
in keybindings and IPC introspection. Actions can be fired via IPC:
`tidepoolmsg action focus left`. Use `tidepoolmsg bindings` to list all
keybindings with action metadata as JSON.

**Window**: `spawn`, `close`, `zoom`, `float`, `fullscreen`

**Focus/navigation**: `focus`, `swap`, `focus-output`, `send-to-output`,
`focus-last`

**Tags**: `focus-tag`, `set-tag`, `toggle-tag`, `focus-all-tags`,
`toggle-scratchpad`, `send-to-scratchpad`

**Layout**: `cycle-layout`, `set-layout`

**Scroll columns**: `consume-column`, `expel-column`, `resize-column`,
`resize-window`, `preset-column-width`, `equalize-column`, `adjust-column-width`

**Marks**: `mark-set`, `mark-clear`, `summon`, `send-to`

**Ratio/count**: `adjust-ratio`, `adjust-main-count`

**Float**: `float-move`, `float-resize`, `float-center`

**Input**: `pointer-move`, `pointer-resize`, `passthrough`

**Session**: `restart`, `exit`, `signal`

## State persistence

State is serialized and restored on demand via `tidepoolmsg save`/`load`. Window
layout state (tag, column, row, float) is saved as JDN. Windows are matched by
`(app-id, title)` on restore.

## IPC

The netrepl server supports topic-based event streaming via `tidepoolmsg watch`.
Available topics: `tags`, `layout`, `title`, `windows`, `signal`. Events are
JSON lines, emitted only when state changes.

## Project structure

```
src/
  tidepool.janet          entry point: protocol setup, config, event dispatch
  tidepoolmsg.janet       CLI client for netrepl socket
  state.janet             shared mutable state tables
  pipeline.janet          per-frame manage/render lifecycle
  output.janet            output lifecycle and tag assignment
  output-config.janet     output mode/position/scale configuration
  window.janet            window lifecycle, positioning, borders
  seat.janet              seat, focus, pointer, XKB bindings
  actions.janet           keybinding action functions
  animation.janet         animation system (ease-out-cubic)
  ipc.janet               netrepl IPC, JSON event streaming
  persist.janet           state serialization for save/load
  indicator.janet         status file writing
  layout/
    init.janet              layout dispatch, geometry, navigation fallback
    scroll.janet            horizontally scrollable columns
    master-stack.janet      master + stack layout
    grid.janet              equal-sized grid
    dwindle.janet           recursive alternating splits
    tabbed.janet            fullscreen stacking
build/                  build-time scripts
protocol/               Wayland protocol XML
test/                   tests
docs/                   design documents
nix/                    Nix integration (home-manager module)
```

## Included protocols

| Protocol                            | Version | License | Copyright    |
| ----------------------------------- | ------- | ------- | ------------ |
| `river-window-management-v1`        | v3      | MIT     | Isaac Freund |
| `river-layer-shell-v1`              | v1      | MIT     | Isaac Freund |
| `river-xkb-bindings-v1`             | v1      | MIT     | Isaac Freund |
| `wlr-output-management-unstable-v1` | v1      | MIT/X11 | Purism SPC   |

System protocols from
[wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols)
(`viewporter`, `single-pixel-buffer-v1`, `wl_shm`) are referenced at build time
but not vendored.

## License

MIT. See [LICENSE](LICENSE).
