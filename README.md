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

A pool is a recursive container with a mode that determines how its children are arranged. Four modes enable arbitrary composition:

| Mode | Arrangement |
|------|-------------|
| `stack-h` | Children side by side horizontally |
| `stack-v` | Children stacked vertically |
| `tabbed` | One child visible at a time, cycle through |
| `scroll` | Rows of columns, one row visible, horizontal scroll within |

Tags are pools. Columns are pools. Tabbed groups are pools. Any pool can contain any pool. Traditional layouts emerge from pool composition (e.g., master-stack = `stack-h` with a window and a `stack-v` group).

Each output has a root `tabbed` pool whose children are tag pools (0-10). Tag 0 is the scratchpad. Switching tags activates a different child of the root. Tags are per-output.

Navigation uses bubble-up traversal: try moving within the current pool, bubble to parent at boundaries, descend into the adjacent child.

See `docs/design-pools.md` for the full architecture.

## Configuration

The init script runs in the tidepool environment with `config` and `wm` tables available. Set values on `config` and push bindings onto `(config :xkb-bindings)` and `(config :pointer-bindings)`.

### Config keys

| Key | Default | Description |
|-----|---------|-------------|
| `:default-layout` | `:scroll` | Mode for new tag pools (`scroll`, `stack-h`, `stack-v`, `tabbed`) |
| `:column-width` | `0.5` | Default scroll column width as fraction |
| `:column-presets` | `[0.333 0.5 0.667 1.0]` | Preset widths for scroll columns |
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

All actions return tagged tables (`@{:fn <closure> :name :desc :args}`) for use in keybindings and IPC introspection. Actions can be fired via IPC: `tidepoolmsg action focus left`. Use `tidepoolmsg bindings` to list all keybindings with action metadata as JSON.

**Window**: `spawn`, `close`, `zoom`, `float`, `fullscreen`

**Focus/navigation**: `focus`, `swap`, `focus-output`, `send-to-output`, `focus-last`

**Tags**: `focus-tag`, `set-tag`, `toggle-tag`, `focus-all-tags`, `toggle-scratchpad`, `send-to-scratchpad`

**Layout**: `cycle-layout`, `set-layout`, `cycle-mode`, `set-mode`

**Pool manipulation**: `consume`, `expel`, `resize`, `equalize`, `cycle-width`

**Input**: `pointer-move`, `pointer-resize`, `passthrough`

**Session**: `restart`, `exit`

`consume` absorbs a neighbor into a group, `expel` moves a window out. `cycle-mode`/`set-mode` change the focused group's mode (stack-v, stack-h, tabbed, scroll). `resize` is context-sensitive (ratio, weight, or scroll column width). Swapping past the edge of a scroll row auto-creates/prunes rows.

## State persistence

State is serialized and restored on demand via `tidepoolmsg save`/`load`. The full pool tree is serialized as pretty-printed JDN. Windows are matched by `(app-id, title)` on restore.

Tag/layout indicator status is written to `$XDG_RUNTIME_DIR/tidepool-tags` and `$XDG_RUNTIME_DIR/tidepool-layout` each manage cycle when `:indicator-file` is enabled.

## Project structure

```
src/
  tidepool.janet          entry point: protocol setup, config, event dispatch
  tidepoolmsg.janet       CLI client for netrepl socket
  state.janet             shared mutable state tables
  pipeline.janet          per-frame manage/render lifecycle
  output.janet            output lifecycle, pool tree init, backgrounds
  output-config.janet     output mode/position/scale configuration
  window.janet            window lifecycle, positioning, borders
  seat.janet              seat, focus, pointer, XKB bindings
  actions.janet           keybinding action functions (delegates to pool modules)
  animation.janet         animation system (ease-out-cubic)
  ipc.janet               netrepl IPC, JSON event streaming
  persist.janet           state serialization for save/load
  indicator.janet         waybar status file writing
  image.janet             image decoding into wl_shm buffers
  pool.janet              pool tree primitives (make, insert, remove, walk, find)
  pool/
    render.janet            recursive pool rendering (stack, tabbed, scroll)
    navigate.janet          structural navigation with bubble-up traversal
    actions.janet           pool tree manipulation (consume, expel, swap, etc.)
    persist.janet           pool tree serialization as JDN
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
