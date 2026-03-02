# tidepool

**Work in progress.** APIs, config format, and behavior will change.

Window manager for [River](https://codeberg.org/river/river) (0.4+), written in [Janet](https://janet-lang.org/). Inspired by [rijan](https://codeberg.org/ifreund/rijan).

Handles layout, focus, keybindings, borders, backgrounds, and output configuration via River's window management protocol. Configured with a Janet init script.

## Building

Requires Zig 0.15+ and system libraries: `wayland`, `libxkbcommon`, `libffi`, `libxml2`, `expat`.

```sh
zig build
```

### Nix

```nix
# overlay.nix provides a package overlay
# package.nix can be called directly with callPackage
nix build
```

## Usage

tidepool connects to a running River compositor and takes over window management. It looks for a config file at `$XDG_CONFIG_HOME/tidepool/init.janet` (or pass a path as the first argument).

```sh
tidepool [init-path]
```

A netrepl server is created at `$XDG_RUNTIME_DIR/tidepool-$WAYLAND_DISPLAY` for live interaction.

## Configuration

The init script runs in the tidepool environment with `config` and `wm` tables available. Set values on `config` and push bindings onto `(config :xkb-bindings)` and `(config :pointer-bindings)`.

### Config keys

| Key | Default | Description |
|-----|---------|-------------|
| `:default-layout` | `:master-stack` | Initial layout for new outputs |
| `:layouts` | all six | Layout cycle order |
| `:border-width` | `4` | Border thickness in pixels |
| `:outer-padding` | `4` | Gap between windows and output edge |
| `:inner-padding` | `8` | Gap between windows |
| `:main-ratio` | `0.55` | Master area ratio (master-stack, centered-master) |
| `:main-count` | `1` | Number of master windows |
| `:dwindle-ratio` | `0.5` | Split ratio for dwindle layout |
| `:column-width` | `0.5` | Default column width as fraction (scroll layout) |
| `:column-presets` | `[0.333 0.5 0.667 1.0]` | Preset widths cycled by `preset-column-width` |
| `:column-row-height` | `0` | Row height ratio for scroll layout (0 = fill) |
| `:struts` | `{:left 0 :right 0 ...}` | Pixels of neighbor visibility at edges (scroll layout) |
| `:animate` | `true` | Enable open/close/move animations |
| `:animation-duration` | `0.2` | Animation duration in seconds |
| `:background` | `0x000000` | Background color (RGB hex) |
| `:border-focused` | `0xffffff` | Focused border color |
| `:border-normal` | `0x646464` | Unfocused border color |
| `:border-urgent` | `0xff0000` | Urgent border color |
| `:warp-pointer` | `false` | Warp pointer to focused window |
| `:xcursor-theme` | `"Adwaita"` | Cursor theme name |
| `:xcursor-size` | `24` | Cursor size |
| `:rules` | `@[]` | Window match rules (see below) |
| `:outputs` | — | Output configuration map (connector to mode/pos/scale) |

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

### Output configuration

```janet
(put config :outputs
  @{"DP-1" @{:mode [2560 1440] :pos [0 0] :scale 1}
    "HDMI-A-1" @{:mode [1920 1080] :pos [2560 0] :scale 1}
    "eDP-1" @{:enable false}})
```

Applied via `zwlr_output_manager_v1` on startup.

## Layouts

- **master-stack** — main area left, stack right
- **monocle** — one window fullscreen, cycle through
- **grid** — automatic grid arrangement
- **centered-master** — center column with side stacks
- **dwindle** — recursive spiral splits
- **scroll** — horizontally scrollable columns with per-column vertical stacking, variable column widths, and strut-based neighbor peeking

## Actions

All actions are functions that return closures, suitable for use in keybindings.

**Window**: `spawn`, `close`, `zoom`, `float`, `fullscreen`

**Focus/navigation**: `focus`, `swap`, `focus-output`, `send-to-output`

**Tags**: `focus-tag`, `set-tag`, `toggle-tag`, `focus-all-tags`, `toggle-scratchpad`, `send-to-scratchpad`

**Layout**: `cycle-layout`, `set-layout`, `adjust-ratio`, `adjust-main-count`

**Scroll layout**: `adjust-column-width`, `resize-column`, `resize-window`, `preset-column-width`, `equalize-column`, `consume-column`, `expel-column`

**Input**: `pointer-move`, `pointer-resize`, `passthrough`

**Session**: `restart`, `exit`

## State persistence

Window tags, column assignments, output layouts, and tag-layout associations are saved to `$XDG_RUNTIME_DIR/tidepool-$WAYLAND_DISPLAY-state.jdn` on every manage cycle. On restart (within the same login session), windows are matched by `(app-id, title)` and restored to their previous tags and column positions.

## Included protocols

The `protocol/` directory contains Wayland protocol XML files used at build time:

| Protocol | Version | License | Copyright |
|----------|---------|---------|-----------|
| `river-window-management-v1` | v3 | MIT | Isaac Freund |
| `river-layer-shell-v1` | v1 | MIT | Isaac Freund |
| `river-xkb-bindings-v1` | v1 | MIT | Isaac Freund |
| `wlr-output-management-unstable-v1` | v1 | MIT/X11 | Purism SPC |

System protocols from [wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols) (`viewporter`, `single-pixel-buffer-v1`) are referenced at build time but not vendored.

## License

MIT. See [LICENSE](LICENSE).
