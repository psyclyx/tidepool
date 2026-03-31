(import ./log)
(import ./dispatch)

# --- Pure helpers ---

(defn usable-area
  "Get the output area excluding layer shell exclusive zones."
  [output]
  (if-let [[x y w h] (output :non-exclusive-area)]
    {:x x :y y :w w :h h}
    {:x (output :x) :y (output :y) :w (output :w) :h (output :h)}))

(defn visible
  "Filter windows visible on this output's tags."
  [output windows]
  (let [tags (output :tags)]
    (filter |(and (tags ($ :tag)) (not ($ :closing))) windows)))

(defn build-tag-map
  "Build tag->output lookup table."
  [outputs]
  (def m @{})
  (each o outputs (eachk tag (o :tags) (put m tag o)))
  m)

(defn rgb-to-u32-rgba
  "Convert an RGB integer to [R G B A] u32 components."
  [rgb]
  [(* (band 0xff (brushift rgb 16)) (/ 0xffff_ffff 0xff))
   (* (band 0xff (brushift rgb 8)) (/ 0xffff_ffff 0xff))
   (* (band 0xff rgb) (/ 0xffff_ffff 0xff))
   0xffff_ffff])

# --- Fx ---

(dispatch/reg-fx :output/create
  (fn [ctx obj]
    (def config (ctx :config))
    (def registry (ctx :registry))
    (def output @{:obj obj
                  :new true
                  :tags @{}
                  :layout (config :default-layout)
                  :layout-params @{:main-ratio (config :main-ratio)
                                   :main-count (config :main-count)
                                   :scroll-offset 0
                                   :column-width (config :column-width)
                                   :dwindle-ratio (config :dwindle-ratio)}})
    (:set-handler obj (dispatch/proxy-handler ctx "river_output_v1" output))
    (when-let [ls (get-in registry [:proxies "river_layer_shell_v1"])]
      (def ls-output (:get-output ls obj))
      (put output :layer-shell ls-output)
      (:set-handler ls-output (dispatch/proxy-handler ctx "river_layer_shell_output_v1" output)))
    (array/push (ctx :outputs) output)
    (log/debugf "output created")))

(defn set-tags [output tags]
  (table/clear (output :tags))
  (merge-into (output :tags) tags))

(dispatch/reg-fx :wl-output/bind
  (fn [ctx {:output output :global-name global-name}]
    (def registry (ctx :registry))
    (def wl-out (:bind (registry :obj) global-name "wl_output" 4))
    (:set-handler wl-out (dispatch/proxy-handler ctx "wl_output" output))))
