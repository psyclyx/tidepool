(import ./state)
(import ./image)
(import ./pool)

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

# --- Pool tree helpers ---

(defn make-default-tag-pools
  "Create default tag pools for a new output.
  Returns a table mapping tag ID (0-10) to standalone tag pools."
  [config]
  (def default-mode (or (config :default-layout) :scroll))
  (def presets (config :column-presets))
  (def tag-pools @{})
  (for i 0 11
    (put tag-pools i
      (if (= default-mode :scroll)
        (pool/make-pool :scroll
          @[(pool/make-pool :stack-v @[])]
          @{:id i :active-row 0 :presets presets})
        (pool/make-pool default-mode @[] @{:id i}))))
  tag-pools)

(defn sync-output-tags
  "Compute active tag set from :active-tag and :multi-active."
  [output]
  (def tags @{})
  (def active (or (output :active-tag) 1))
  (put tags active true)
  (when-let [ma (output :multi-active)]
    (eachp [id vis] ma
      (when vis (put tags id true))))
  (put output :tags tags))

(defn active-tag-id
  "Get the active tag ID."
  [output]
  (or (output :active-tag) 1))

(defn active-tag-pool
  "Get the active tag pool."
  [output]
  (when-let [tp (output :tag-pools)]
    (get tp (or (output :active-tag) 1))))

(defn visible
  "Filter windows visible on this output's tags."
  [output windows]
  (let [tags (output :tags)]
    (filter |(and (tags ($ :tag)) (not ($ :closing))) windows)))

(defn usable-area
  "Get the output area excluding layer shell exclusive zones, inset by outer padding."
  [output &opt config]
  (def pad (if config (or (config :outer-padding) 0) 0))
  (def [x y w h]
    (if-let [[ex ey ew eh] (output :non-exclusive-area)]
      [ex ey ew eh]
      [(output :x) (output :y) (output :w) (output :h)]))
  {:x (+ x pad) :y (+ y pad)
   :w (- w (* 2 pad)) :h (- h (* 2 pad))})

(defn manage-start
  "Cache state and flag removed outputs for destruction."
  [output]
  (if (output :removed)
    (do
      (when (and (output :x) (output :y))
        (put state/output-pool-cache
             (string (output :x) "," (output :y))
             @{:tag-pools (output :tag-pools)
               :active-tag (output :active-tag)}))
      (put output :pending-destroy true)
      nil)
    output))

(defn manage
  "Initialize new outputs with tag pools."
  [output outputs]
  (when (output :new)
    (def cache-key (when (and (output :x) (output :y))
                     (string (output :x) "," (output :y))))
    (if-let [saved (and cache-key (get state/output-pool-cache cache-key))]
      (do
        (put output :tag-pools (saved :tag-pools))
        (put output :active-tag (saved :active-tag))
        (put state/output-pool-cache cache-key nil))
      # Find a tag not shown by any other output and activate it
      (let [shown @{}]
        (each o outputs
          (when (and (not= o output) (not (o :removed)))
            (put shown (or (o :active-tag) 1) true)))
        (var found false)
        (for i 1 11
          (when (and (not found) (not (shown i)))
            (put output :active-tag i)
            (set found true)))
        (unless found (put output :active-tag 1))))))

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
                :tag-pools (make-default-tag-pools config)
                :active-tag 1
                :tags @{}})
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
