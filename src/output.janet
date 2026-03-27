(import ./state)

(defn rgb-to-u32-rgba
  "Convert an RGB integer to [R G B A] u32 components."
  [rgb]
  [(* (band 0xff (brushift rgb 16)) (/ 0xffff_ffff 0xff))
   (* (band 0xff (brushift rgb 8)) (/ 0xffff_ffff 0xff))
   (* (band 0xff rgb) (/ 0xffff_ffff 0xff))
   0xffff_ffff])

(defn build-tag-map
  "Build tag->output lookup table."
  [outputs]
  (def m @{})
  (each o outputs (eachk tag (o :tags) (put m tag o)))
  m)

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
                :layer-shell (:get-output (registry "river_layer_shell_v1") obj)
                :new true
                :tags @{}
                :layout (config :default-layout)
                :layout-params (state/default-layout-params)})
  (defn handle-event [event]
    (match event
      [:removed] (put output :removed true)
      [:position x y] (do (put output :x x) (put output :y y))
      [:dimensions w h] (do (put output :w w) (put output :h h))
      [:wl-output global-name]
      (let [wl-out (:bind (registry :obj) global-name "wl_output" 4)]
        (:set-handler wl-out
          (fn [ev]
            (match ev
              [:name n] (put output :name n)))))))
  (defn handle-layer-shell-event [event]
    (match event
      [:non-exclusive-area x y w h] (put output :non-exclusive-area [x y w h])))
  (:set-user-data obj output)
  (:set-handler obj handle-event)
  (:set-handler (output :layer-shell) handle-layer-shell-event)
  output)
