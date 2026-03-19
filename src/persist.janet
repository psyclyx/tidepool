(import ./state)

(def- saved-windows @[])

(defn serialize
  "Serialize window, output, and tag-layout state to a JDN string."
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
          :row (w :row)
          :float (w :float)})))

  (def out-data @[])
  (each o outputs
    (when (and (o :x) (o :y))
      (array/push out-data
        @{:position (string (o :x) "," (o :y))
          :tags (table/clone (o :tags))
          :layout (o :layout)
          :layout-params (state/clone-layout-params (o :layout-params))})))

  (def tl-data @{})
  (eachp [tag saved] tag-layouts
    (put tl-data tag
         @{:layout (saved :layout)
           :params (state/clone-layout-params (saved :params))}))

  (def data @{:windows win-data :outputs out-data :tag-layouts tl-data})
  (string/format "%j" data))

(defn- apply-saved
  "Apply saved attributes from a matched entry to a window."
  [window saved]
  (when (saved :tag)
    (put window :tag (saved :tag)))
  (when (saved :float)
    (put window :float true))
  (when (saved :column)
    (put window :column (saved :column)))
  (when (saved :col-width)
    (put window :col-width (saved :col-width)))
  (when (saved :col-weight)
    (put window :col-weight (saved :col-weight)))
  (when (saved :row)
    (put window :row (saved :row))))

(defn- match-saved
  "Find and remove a matching saved-window entry. Returns the entry or nil."
  [window]
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
    saved))

(defn restore-window
  "Apply saved attributes (tag, float, column) to a new window."
  [window]
  (when (window :new)
    (when-let [saved (match-saved window)]
      (apply-saved window saved))))

(defn apply-state
  "Apply parsed state data to outputs, tag-layouts, and windows.
  Handles both pre-startup (cache for later) and post-startup (patch live) cases."
  [data]
  (unless (dictionary? data)
    (break))

  (when-let [outputs (data :outputs)]
    (each o outputs
      (when (o :position)
        (def saved @{:tags (or (o :tags) @{})
                     :layout (or (o :layout) (state/config :default-layout))
                     :layout-params (or (o :layout-params) @{})})
        # Try to patch a live output at this position
        (var matched false)
        (each live (state/wm :outputs)
          (when (and (live :x) (live :y)
                     (= (o :position) (string (live :x) "," (live :y))))
            (put live :tags (saved :tags))
            (put live :layout (saved :layout))
            (merge-into (live :layout-params) (saved :layout-params))
            (set matched true)
            (break)))
        # Fall back to cache for outputs that haven't appeared yet
        (unless matched
          (put state/output-state-cache (o :position) saved)))))

  (when-let [tl (data :tag-layouts)]
    (eachp [tag saved] tl
      (put state/tag-layouts tag saved)))

  (array/clear saved-windows)
  (when-let [windows (data :windows)]
    (array/concat saved-windows windows)
    # Apply to any already-existing windows
    (each w (state/wm :windows)
      (when (and (not (w :closing)) (not (w :closed)))
        (when-let [s (match-saved w)]
          (apply-saved w s))))))
