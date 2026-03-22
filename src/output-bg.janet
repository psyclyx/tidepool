# Output background rendering (wallpaper image or solid color).
# Separated from output.janet to avoid pulling image-native into
# modules that only need pure output operations.

(import ./image)
(import ./output)

(defn create
  "Create background surface and viewport for an output."
  [registry]
  (def surface (:create-surface (registry "wl_compositor")))
  (def viewport (:get-viewport (registry "wp_viewporter") surface))
  (def shell-surface (:get-shell-surface (registry "river_window_manager_v1") surface))
  @{:surface surface
    :viewport viewport
    :shell-surface shell-surface
    :node (:get-node shell-surface)})

(defn- fill-source
  "Compute viewport source rect for fill mode (cover output, crop excess)."
  [img-w img-h out-w out-h]
  (def img-ratio (/ img-w img-h))
  (def out-ratio (/ out-w out-h))
  (if (> img-ratio out-ratio)
    (let [src-h img-h
          src-w (* src-h out-ratio)
          src-x (/ (- img-w src-w) 2)]
      [src-x 0 src-w src-h])
    (let [src-w img-w
          src-h (/ src-w out-ratio)
          src-y (/ (- img-h src-h) 2)]
      [0 src-y src-w src-h])))

(defn manage
  "Render the output background (wallpaper image or solid color)."
  [bg output config registry]
  (def wallpaper (config :wallpaper))
  (def bg-color (config :background))
  (def cache-key [(output :x) (output :y) (output :w) (output :h) wallpaper bg-color])
  (when (deep= cache-key (bg :last-render))
    (break))
  (unless (and (output :x) (output :y) (output :w) (output :h))
    (break))
  (put bg :last-render cache-key)
  (:sync-next-commit (bg :shell-surface))
  (:place-bottom (bg :node))
  (:set-position (bg :node) (output :x) (output :y))
  (if (string? wallpaper)
    (let [img (image/create-buffer wallpaper registry)
          [sx sy sw sh] (fill-source (img :width) (img :height)
                                      (output :w) (output :h))]
      (:set-source (bg :viewport) sx sy sw sh)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) (img :buffer) 0 0)
      (:damage-buffer (bg :surface) 0 0 (img :width) (img :height))
      (:commit (bg :surface)))
    (let [[r g b a] (output/rgb-to-u32-rgba (or bg-color 0))
          buffer (:create-u32-rgba-buffer
                   (registry "wp_single_pixel_buffer_manager_v1")
                   r g b a)]
      (:set-source (bg :viewport) -1 -1 -1 -1)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) buffer 0 0)
      (:damage-buffer (bg :surface) 0 0 0x7fff_ffff 0x7fff_ffff)
      (:commit (bg :surface))
      (:destroy buffer))))

(defn destroy
  "Destroy background surface resources."
  [bg]
  (:destroy (bg :viewport))
  (:destroy (bg :shell-surface))
  (:destroy (bg :surface))
  (:destroy (bg :node)))
