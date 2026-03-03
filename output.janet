# Output lifecycle, usable area, visible windows, background surfaces.

(import ./state)
(import ./animation)
(import ./image)

(defn rgb-to-u32-rgba [rgb]
  [(* (band 0xff (brushift rgb 16)) (/ 0xffff_ffff 0xff))
   (* (band 0xff (brushift rgb 8)) (/ 0xffff_ffff 0xff))
   (* (band 0xff rgb) (/ 0xffff_ffff 0xff))
   0xffff_ffff])

# --- Background Surface ---

(defn bg/create []
  (def surface (:create-surface (state/registry "wl_compositor")))
  (def viewport (:get-viewport (state/registry "wp_viewporter") surface))
  (def shell-surface (:get-shell-surface (state/registry "river_window_manager_v1") surface))
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
    # Image wider than output — crop left/right
    (let [src-h img-h
          src-w (* src-h out-ratio)
          src-x (/ (- img-w src-w) 2)]
      [src-x 0 src-w src-h])
    # Image taller — crop top/bottom
    (let [src-w img-w
          src-h (/ src-w out-ratio)
          src-y (/ (- img-h src-h) 2)]
      [0 src-y src-w src-h])))

(defn bg/manage [bg output]
  (:sync-next-commit (bg :shell-surface))
  (:place-bottom (bg :node))
  (:set-position (bg :node) (output :x) (output :y))
  (def wallpaper (state/config :wallpaper))
  (if (string? wallpaper)
    # Image wallpaper
    (let [img (image/create-buffer wallpaper)
          [sx sy sw sh] (bg/fill-source (img :width) (img :height)
                                        (output :w) (output :h))]
      (:set-source (bg :viewport) sx sy sw sh)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) (img :buffer) 0 0)
      (:damage-buffer (bg :surface) 0 0 (img :width) (img :height))
      (:commit (bg :surface)))
    # Solid color
    (let [[r g b a] (rgb-to-u32-rgba (or (state/config :background) 0))
          buffer (:create-u32-rgba-buffer
                   (state/registry "wp_single_pixel_buffer_manager_v1")
                   r g b a)]
      (:set-source (bg :viewport) -1 -1 -1 -1)
      (:set-destination (bg :viewport) (output :w) (output :h))
      (:attach (bg :surface) buffer 0 0)
      (:damage-buffer (bg :surface) 0 0 0x7fff_ffff 0x7fff_ffff)
      (:commit (bg :surface))
      (:destroy buffer))))

(defn bg/destroy [bg]
  (:destroy (bg :viewport))
  (:destroy (bg :shell-surface))
  (:destroy (bg :surface))
  (:destroy (bg :node)))

# --- Output Management ---

(defn visible [output windows]
  (let [tags (output :tags)]
    (filter |(and (tags ($ :tag)) (not ($ :closing))) windows)))

(defn usable-area [output]
  (if-let [[x y w h] (output :non-exclusive-area)]
    {:x x :y y :w w :h h}
    {:x (output :x) :y (output :y) :w (output :w) :h (output :h)}))

(defn manage-start [output]
  (if (output :removed)
    (do
      # Save state for restoration after VT switch
      (when (and (output :x) (output :y))
        (put state/output-state-cache (string (output :x) "," (output :y))
             @{:tags (table/clone (output :tags))
               :layout (output :layout)
               :layout-params (table/clone (output :layout-params))}))
      (:destroy (output :obj))
      (bg/destroy (output :bg)))
    output))

(defn manage [output]
  (bg/manage (output :bg) output)
  (when (output :new)
    (def cache-key (when (and (output :x) (output :y))
                     (string (output :x) "," (output :y))))
    (if-let [saved (and cache-key (get state/output-state-cache cache-key))]
      (do
        (put output :tags (saved :tags))
        (put output :layout (saved :layout))
        (merge-into (output :layout-params) (saved :layout-params))
        (put state/output-state-cache cache-key nil))
      (let [unused (find (fn [tag] (not (find |(($ :tags) tag) (state/wm :outputs)))) (range 1 10))]
        (put (output :tags) unused true)))))

(defn manage-finish [output]
  (put output :new nil))

(defn create [obj]
  (def output @{:obj obj
                :bg (bg/create)
                :layer-shell (:get-output (state/registry "river_layer_shell_v1") obj)
                :new true
                :tags @{}
                :layout (state/config :default-layout)
                :layout-params @{:main-ratio (state/config :main-ratio)
                                 :main-count (state/config :main-count)
                                 :scroll-offset 0
                                 :column-width (state/config :column-width)
                                 :dwindle-ratio (state/config :dwindle-ratio)}})
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
