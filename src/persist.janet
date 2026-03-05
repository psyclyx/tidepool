(import ./state)

(def- saved-windows @[])

(defn- state-path []
  (string (os/getenv "XDG_RUNTIME_DIR") "/tidepool-"
          (os/getenv "WAYLAND_DISPLAY") "-state.jdn"))

(defn- filter-anim-keys [params]
  (def out @{})
  (eachp [k v] params
    (unless (string/has-suffix? "-anim" (string k))
      (put out k v)))
  out)

(defn save []
  (def windows @[])
  (each w (state/wm :windows)
    (when (and (w :app-id) (not (w :closing)) (not (w :closed)))
      (array/push windows
        @{:app-id (w :app-id)
          :title (w :title)
          :tag (w :tag)
          :column (w :column)
          :col-width (w :col-width)
          :col-weight (w :col-weight)
          :float (w :float)})))

  (def outputs @[])
  (each o (state/wm :outputs)
    (when (and (o :x) (o :y))
      (array/push outputs
        @{:position (string (o :x) "," (o :y))
          :tags (table/clone (o :tags))
          :layout (o :layout)
          :layout-params (filter-anim-keys (o :layout-params))})))

  (def tag-layouts @{})
  (eachp [tag saved] state/tag-layouts
    (put tag-layouts tag
         @{:layout (saved :layout)
           :params (filter-anim-keys (saved :params))}))

  (def data @{:windows windows :outputs outputs :tag-layouts tag-layouts})
  (spit (state-path) (string/format "%j" data)))

(defn load []
  (def path (state-path))
  (unless (os/stat path)
    (break))

  (def data (try (parse (slurp path))
              ([err] (eprintf "tidepool: persist/load parse error: %s" err)
                     (break))))
  (unless (dictionary? data)
    (break))

  (when-let [outputs (data :outputs)]
    (each o outputs
      (when (o :position)
        (put state/output-state-cache (o :position)
             @{:tags (or (o :tags) @{})
               :layout (or (o :layout) (state/config :default-layout))
               :layout-params (or (o :layout-params) @{})}))))

  (when-let [tl (data :tag-layouts)]
    (eachp [tag saved] tl
      (put state/tag-layouts tag saved)))

  (array/clear saved-windows)
  (when-let [windows (data :windows)]
    (array/concat saved-windows windows)))

(defn restore-window [window]
  (when (window :new)
    (var idx nil)
    (for i 0 (length saved-windows)
      (def saved (saved-windows i))
      (when (and (= (saved :app-id) (window :app-id))
                 (= (saved :title) (window :title)))
        (set idx i)
        (break)))
    (when idx
      (def saved (saved-windows idx))
      (array/remove saved-windows idx)
      (when (saved :tag)
        (put window :tag (saved :tag)))
      (when (saved :float)
        (put window :float true))
      (when (saved :column)
        (put window :column (saved :column)))
      (when (saved :col-width)
        (put window :col-width (saved :col-width)))
      (when (saved :col-weight)
        (put window :col-weight (saved :col-weight))))))
