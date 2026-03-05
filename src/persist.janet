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

(defn save
  "Serialize window, output, and tag-layout state to disk."
  [windows outputs tag-layouts]
  (def win-data @[])
  (each w windows
    (when (and (w :app-id) (not (w :closing)) (not (w :closed)))
      (array/push win-data
        @{:app-id (w :app-id)
          :title (w :title)
          :tag (w :tag)
          :column (w :column)
          :col-width (w :col-width)
          :col-weight (w :col-weight)
          :float (w :float)})))

  (def out-data @[])
  (each o outputs
    (when (and (o :x) (o :y))
      (array/push out-data
        @{:position (string (o :x) "," (o :y))
          :tags (table/clone (o :tags))
          :layout (o :layout)
          :layout-params (filter-anim-keys (o :layout-params))})))

  (def tl-data @{})
  (eachp [tag saved] tag-layouts
    (put tl-data tag
         @{:layout (saved :layout)
           :params (filter-anim-keys (saved :params))}))

  (def data @{:windows win-data :outputs out-data :tag-layouts tl-data})
  (spit (state-path) (string/format "%j" data)))

(defn load
  "Restore persisted state on startup."
  []
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

(defn restore-window
  "Apply saved attributes (tag, float, column) to a new window."
  [window]
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
