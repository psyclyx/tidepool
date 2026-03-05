(import ./state)
(import ./image)

(defn rgb-to-u32-rgba
  "Convert an RGB integer to [R G B A] u32 components."
  [rgb]
  [(* (band 0xff (brushift rgb 16)) (/ 0xffff_ffff 0xff))
   (* (band 0xff (brushift rgb 8)) (/ 0xffff_ffff 0xff))
   (* (band 0xff rgb) (/ 0xffff_ffff 0xff))
   0xffff_ffff])

(defn bg/create
  "Create background surface and viewport for an output."
  [registry]
  (def surface (:create-surface (registry "wl_compositor")))
  (def viewport (:get-viewport (registry "wp_viewporter") surface))
  (def shell-surface (:get-shell-surface (registry "river_window_manager_v1") surface))
  @{:surface surface
    :viewport viewport
    :shell-surface shell-surface
    :node (:get-node shell-surface)})

(defn- bg/fill-source
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

(defn bg/manage
  "Render the output background (wallpaper image or solid color).
  Only re-renders when the output dimensions or wallpaper config change."
  [bg output config registry]
  (def wallpaper (config :wallpaper))
  (def bg-color (config :background))
  (def cache-key [(output :w) (output :h) wallpaper bg-color])
  (when (deep= cache-key (bg :last-render))
    (break))
  (put bg :last-render cache-key)
  (:sync-next-commit (bg :shell-surface))
  (:place-bottom (bg :node))
  (:set-position (bg :node) (output :x) (output :y))
  (if (string? wallpaper)
    (let [img (image/create-buffer wallpaper)
          [sx sy sw sh] (bg/fill-source (img :width) (img :height)
                                        (output :w) (output :h))]
      (:set-source (bg :viewport) sx sy sw sh)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) (img :buffer) 0 0)
      (:damage-buffer (bg :surface) 0 0 (img :width) (img :height))
      (:commit (bg :surface)))
    (let [[r g b a] (rgb-to-u32-rgba (or bg-color 0))
          buffer (:create-u32-rgba-buffer
                   (registry "wp_single_pixel_buffer_manager_v1")
                   r g b a)]
      (:set-source (bg :viewport) -1 -1 -1 -1)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) buffer 0 0)
      (:damage-buffer (bg :surface) 0 0 0x7fff_ffff 0x7fff_ffff)
      (:commit (bg :surface))
      (:destroy buffer))))

(defn bg/destroy
  "Destroy background surface resources."
  [bg]
  (:destroy (bg :viewport))
  (:destroy (bg :shell-surface))
  (:destroy (bg :surface))
  (:destroy (bg :node)))

(defn visible
  "Filter windows visible on this output's tags."
  [output windows]
  (let [tags (output :tags)]
    (filter |(and (tags ($ :tag)) (not ($ :closing))) windows)))

(defn usable-area
  "Get the output area excluding layer shell exclusive zones."
  [output]
  (if-let [[x y w h] (output :non-exclusive-area)]
    {:x x :y y :w w :h h}
    {:x (output :x) :y (output :y) :w (output :w) :h (output :h)}))

(defn manage-start
  "Cache state and flag removed outputs for destruction."
  [output]
  (if (output :removed)
    (do
      (when (and (output :x) (output :y))
        (put state/output-state-cache (string (output :x) "," (output :y))
             @{:tags (table/clone (output :tags))
               :layout (output :layout)
               :layout-params (table/clone (output :layout-params))}))
      (put output :pending-destroy true)
      nil)
    output))

(defn manage
  "Assign tags for new outputs (pure data)."
  [output outputs]
  (when (output :new)
    (def cache-key (when (and (output :x) (output :y))
                     (string (output :x) "," (output :y))))
    (if-let [saved (and cache-key (get state/output-state-cache cache-key))]
      (do
        (put output :tags (saved :tags))
        (put output :layout (saved :layout))
        (merge-into (output :layout-params) (saved :layout-params))
        (put state/output-state-cache cache-key nil))
      (let [unused (find (fn [tag] (not (find |(($ :tags) tag) outputs))) (range 1 10))]
        (put (output :tags) unused true)))))

(defn manage-finish
  "Clear per-frame transient state."
  [output]
  (put output :new nil))

(defn create
  "Create an output from a Wayland output object."
  [obj config registry]
  (def output @{:obj obj
                :bg (bg/create registry)
                :layer-shell (:get-output (registry "river_layer_shell_v1") obj)
                :new true
                :tags @{}
                :layout (config :default-layout)
                :layout-params @{:main-ratio (config :main-ratio)
                                 :main-count (config :main-count)
                                 :scroll-offset 0
                                 :column-width (config :column-width)
                                 :dwindle-ratio (config :dwindle-ratio)}})
  (defn handle-event [event]
    (match event
      [:removed] (put output :removed true)
      [:position x y] (do (put output :x x) (put output :y y))
      [:dimensions w h] (do (put output :w w) (put output :h h))))
  (defn handle-layer-shell-event [event]
    (match event
      [:non-exclusive-area x y w h] (put output :non-exclusive-area [x y w h])))
  (:set-user-data obj output)
  (:set-handler obj handle-event)
  (:set-handler (output :layer-shell) handle-layer-shell-event)
  output)
