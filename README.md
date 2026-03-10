# tidepool

**Work in progress.** APIs, config format, and behavior will change.

Window manager for [River](https://codeberg.org/river/river) (0.4+), written in [Janet](https://janet-lang.org/). Handles layout, focus, keybindings, borders, backgrounds, wallpaper, and output configuration via River's window management protocol. Configured with a Janet init script.

## Building

Requires Zig 0.15+ and system libraries: `wayland`, `libxkbcommon`, `libffi`, `libxml2`, `expat`.

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

tidepool connects to a running River compositor and takes over window management. Config is read from `$XDG_CONFIG_HOME/tidepool/init.janet` (or pass a path as the first argument).

```sh
tidepool [init-path]
```

A netrepl server is created at `$XDG_RUNTIME_DIR/tidepool-$WAYLAND_DISPLAY` for live interaction.

### tidepoolmsg

CLI client for the netrepl socket.

```sh
tidepoolmsg repl                         # interactive REPL
tidepoolmsg eval '<expression>'          # evaluate Janet expression
tidepoolmsg watch tags layout title      # stream updates as JSON lines
tidepoolmsg save > layout.jdn            # serialize state to stdout
tidepoolmsg load < layout.jdn            # restore state from stdin
tidepoolmsg completions bash             # output shell completions (bash/zsh/fish)
```

## Layout model

tidepool is transitioning from named layout algorithms to a recursive pool architecture. Both systems currently coexist.

### Named layouts (current)

Six layout algorithms, selected per-output:

- **master-stack** -- main area left, stack right
- **monocle** -- single window, cycle through
- **grid** -- automatic grid
- **centered-master** -- center column with side stacks
- **dwindle** -- recursive spiral splits
- **scroll** -- horizontally scrollable columns with variable widths and neighbor peeking

### Pools (in progress)

A pool is a recursive container with a mode that determines how its children are arranged. Four modes replace all named layouts and enable arbitrary composition:

| Mode | Arrangement |
|------|-------------|
| `stack-h` | Children side by side horizontally |
| `stack-v` | Children stacked vertically |
| `tabbed` | One child visible at a time, cycle through |
| `scroll` | 2D grid of rows x columns, one row visible, horizontal scroll within |

Tags are pools. Columns are pools. Tabbed groups are pools. Any pool can contain any pool. Named layouts like master-stack emerge from pool composition (e.g., `stack-h` with a window and a `stack-v` group).

See `docs/design-pools.md` for the full architecture.

## Configuration

The init script runs in the tidepool environment with `config` and `wm` tables available. Set values on `config` and push bindings onto `(config :xkb-bindings)` and `(config :pointer-bindings)`.

### Config keys

| Key | Default | Description |
|-----|---------|-------------|
| `:default-layout` | `:master-stack` | Initial layout for new outputs |
| `:layouts` | all six | Layout cycle order |
| `:main-ratio` | `0.55` | Master area ratio (master-stack, centered-master) |
| `:main-count` | `1` | Number of master windows |
| `:dwindle-ratio` | `0.5` | Split ratio for dwindle |
| `:column-width` | `0.5` | Default scroll column width as fraction |
| `:column-presets` | `[0.333 0.5 0.667 1.0]` | Preset widths for scroll columns |
| `:column-row-height` | `0` | Scroll row height ratio (0 = fill) |
| `:border-width` | `4` | Border thickness in pixels |
| `:outer-padding` | `4` | Gap between windows and output edge |
| `:inner-padding` | `8` | Gap between windows |
| `:border-focused` | `0xffffff` | Focused border color |
| `:border-normal` | `0x646464` | Unfocused border color |
| `:border-urgent` | `0xff0000` | Urgent border color |
| `:border-tabbed` | `0x88aaff` | Tabbed group border color |
| `:background` | `0x000000` | Background color (RGB hex) |
| `:wallpaper` | `nil` | File path for image, `true` for transparent (external daemon), `nil` for solid color |
| `:animate` | `true` | Enable animations |
| `:animation-duration` | `0.2` | Animation duration in seconds |
| `:warp-pointer` | `false` | Warp pointer to focused window |
| `:xcursor-theme` | `"Adwaita"` | Cursor theme name |
| `:xcursor-size` | `24` | Cursor size |
| `:indicator-file` | `true` | Write tag/layout status to `$XDG_RUNTIME_DIR/tidepool-*` files |
| `:indicator-notify` | `true` | Send layout change notifications via `notify-send` |
| `:debug` | `false` | Frame profiling and verbose logging to stderr |
| `:rules` | `@[]` | Window match rules |
| `:outputs` | -- | Output configuration map |

### Keybindings

```janet
(array/push (config :xkb-bindings)
  [:Return {:mod4 true} (action/spawn ["foot"])]
  [:h {:mod4 true} (action/focus :left)]
  [:l {:mod4 true} (action/focus :right)]
  [:q {:mod4 true :shift true} (action/close)])
```

Format: `[keysym modifiers action-fn]`. Modifiers: `:mod4`, `:shift`, `:ctrl`, `:mod1` (alt).

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

All actions return closures for use in keybindings.

**Window**: `spawn`, `close`, `zoom`, `float`, `fullscreen`

**Focus/navigation**: `focus`, `swap`, `focus-output`, `send-to-output`, `focus-last`

**Tags**: `focus-tag`, `set-tag`, `toggle-tag`, `focus-all-tags`, `toggle-scratchpad`, `send-to-scratchpad`

**Layout**: `cycle-layout`, `set-layout`, `adjust-ratio`, `adjust-main-count`

**Scroll**: `adjust-column-width`, `resize-column`, `resize-window`, `preset-column-width`, `equalize-column`, `consume-column`, `expel-column`, `toggle-column-mode`, `set-column-sublayout`, `move-to-strip`, `resize-strip`

**Input**: `pointer-move`, `pointer-resize`, `passthrough`

**Session**: `restart`, `exit`

### Pool actions (in progress)

The pool system consolidates the above into 13 actions that work uniformly across all pool modes:

`focus`, `swap`, `consume`, `expel`, `resize`, `set-mode`, `cycle-preset`, `zoom`, `focus-pool`, `send-to-pool`, `toggle-pool`, `focus-last`, `float`

## State persistence

State is serialized and restored on demand via `tidepoolmsg save`/`load`. Windows are matched by `(app-id, title)` and placed back into their previous positions. The pool system serializes the full tree as pretty-printed JDN.

Tag/layout indicator status is written to `$XDG_RUNTIME_DIR/tidepool-tags` and `$XDG_RUNTIME_DIR/tidepool-layout` each manage cycle when `:indicator-file` is enabled.

## Project structure

```
src/
  tidepool.janet          entry point: protocol setup, config, event dispatch
  tidepoolmsg.janet       CLI client for netrepl socket
  state.janet             shared mutable state tables
  pipeline.janet          per-frame manage/render lifecycle
  output.janet            output lifecycle, backgrounds, wallpaper
  output-config.janet     output mode/position/scale configuration
  window.janet            window lifecycle, positioning, borders
  seat.janet              seat, focus, pointer, XKB bindings
  actions.janet           keybinding action functions
  animation.janet         animation system (ease-out-cubic)
  ipc.janet               netrepl IPC, JSON event streaming
  persist.janet           state serialization for save/load
  indicator.janet         waybar status file writing
  image.janet             image decoding into wl_shm buffers
  pool.janet              pool tree primitives (make, insert, remove, walk, find)
  pool/
    render.janet            recursive pool rendering
    navigate.janet          structural navigation with bubble-up traversal
    actions.janet           pool tree manipulation (consume, expel, swap, etc.)
    persist.janet           pool tree serialization as JDN
  layout/
    init.janet              layout registry and dispatch
    util.janet              shared layout helpers
    master-stack.janet      main + stack
    monocle.janet           fullscreen cycle
    grid.janet              automatic grid
    centered-master.janet   center column with side stacks
    dwindle.janet           recursive spiral
    scroll.janet            scrollable columns
  native/
    image-native.c          stb_image wrapper for wl_shm buffers
    stb_image.h             vendored stb_image v2.30
build/                  build-time scripts
protocol/               Wayland protocol XML
test/                   tests
docs/                   design documents
nix/                    Nix integration (home-manager module)
```

## Included protocols

| Protocol | Version | License | Copyright |
|----------|---------|---------|-----------|
| `river-window-management-v1` | v3 | MIT | Isaac Freund |
| `river-layer-shell-v1` | v1 | MIT | Isaac Freund |
| `river-xkb-bindings-v1` | v1 | MIT | Isaac Freund |
| `wlr-output-management-unstable-v1` | v1 | MIT/X11 | Purism SPC |

System protocols from [wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols) (`viewporter`, `single-pixel-buffer-v1`, `wl_shm`) are referenced at build time but not vendored.

## License

MIT. See [LICENSE](LICENSE).
