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

# --- Pool tree helpers ---

(defn make-default-pool
  "Create the default pool tree for a new output.
  Root is tabbed with tag pools 0-10 as children."
  [config]
  (def default-mode (or (config :default-layout) :scroll))
  (def presets (config :column-presets))
  (def tags @[])
  (for i 0 11
    (def tag-pool
      (if (= default-mode :scroll)
        (pool/make-pool :scroll
          @[(pool/make-pool :stack-v @[])]
          @{:id i :active-row 0 :presets presets})
        (pool/make-pool default-mode @[] @{:id i})))
    (array/push tags tag-pool))
  (pool/make-pool :tabbed tags @{:active 1}))

(defn sync-output-tags
  "Derive active tag set from pool tree and write to (output :tags)."
  [output]
  (def root (output :pool))
  (when (nil? root) (break))
  (def tags @{})
  (def active (or (root :active) 0))
  (when (< active (length (root :children)))
    (def tag (get (root :children) active))
    (when (tag :id) (put tags (tag :id) true)))
  (when-let [ma (root :multi-active)]
    (eachp [idx vis] ma
      (when (and vis (< idx (length (root :children))))
        (def tag (get (root :children) idx))
        (when (tag :id) (put tags (tag :id) true)))))
  (put output :tags tags))

(defn active-tag-id
  "Get the active tag pool's :id from the pool tree."
  [output]
  (when-let [root (output :pool)]
    (def active (or (root :active) 0))
    (when-let [tag (get (root :children) active)]
      (tag :id))))

(defn active-tag-pool
  "Get the active tag pool from the output's pool tree."
  [output]
  (when-let [root (output :pool)]
    (def active (or (root :active) 0))
    (get (root :children) active)))

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
        (put state/output-pool-cache
             (string (output :x) "," (output :y))
             (output :pool)))
      (put output :pending-destroy true)
      nil)
    output))

(defn manage
  "Initialize new outputs with pool tree."
  [output outputs]
  (when (output :new)
    (def cache-key (when (and (output :x) (output :y))
                     (string (output :x) "," (output :y))))
    (if-let [saved (and cache-key (get state/output-pool-cache cache-key))]
      (do
        (put output :pool saved)
        (put state/output-pool-cache cache-key nil))
      # Find a tag not shown by any other output and activate it
      (let [root (output :pool)
            shown @{}]
        (each o outputs
          (when (and (not= o output) (not (o :removed)))
            (when-let [r (o :pool)]
              (def a (or (r :active) 0))
              (when-let [tag (get (r :children) a)]
                (put shown (tag :id) true)))))
        (var found false)
        (for i 0 (length (root :children))
          (when (and (not found)
                     (not (shown ((get (root :children) i) :id))))
            (put root :active i)
            (set found true)))
        (unless found (put root :active 1))))))

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
                :pool (make-default-pool config)
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
