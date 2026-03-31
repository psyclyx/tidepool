(import ./dispatch)
(import ./log)

(var- next-wid 0)

# --- Pure helpers ---

(defn set-position [w x y]
  (put w :x x)
  (put w :y y))

(defn propose-dimensions [w width height config]
  (def bw (config :border-width))
  (put w :proposed-w (max 1 (- width (* 2 bw))))
  (put w :proposed-h (max 1 (- height (* 2 bw)))))

(defn fixed-size? [w]
  (let [{:min-w mw :max-w xw :min-h mh :max-h xh} w]
    (and mw (> mw 0) xw (> xw 0)
         mh (> mh 0) xh (> xh 0)
         (= mw xw) (= mh xh))))

(defn tag-output [w outputs]
  (find |(($ :tags) (w :tag)) outputs))

(defn set-float [w float]
  (put w :float float)
  (put w :float-changed true))

(defn set-borders [w status config]
  (put w :border-rgb
    (case status
      :focused (config :border-focused)
      :normal (config :border-normal)
      :urgent (config :border-urgent)
      (config :border-normal)))
  (put w :border-width (config :border-width)))

(defn compute-visibility [outputs windows]
  (def all-tags @{})
  (each o outputs (merge-into all-tags (o :tags)))
  (each w windows
    (put w :visible
      (if (and (all-tags (w :tag))
               (not (w :closed))
               (not (w :layout-hidden)))
        true false))))

# --- Create ---

(defn create [obj]
  (def w @{:obj obj :node (:get-node obj)
           :new true :tag 1 :wid (++ next-wid)})
  (:set-handler obj
    (fn [event]
      (match event
        [:closed] (put w :closed true)
        [:dimensions width height]
          (do (put w :w width) (put w :h height))
        [:dimensions-hint min-w min-h max-w max-h]
          (do (put w :min-w min-w) (put w :min-h min-h)
              (put w :max-w max-w) (put w :max-h max-h))
        [:app-id id] (put w :app-id id)
        [:title t] (put w :title t)
        [:parent p] (put w :wl-parent (when p (:get-user-data p)))
        [:decoration-hint _] nil
        [:pointer-move-requested s]
          (put w :pointer-move-requested (:get-user-data s))
        [:pointer-resize-requested s edges]
          (put w :pointer-resize-requested @{:seat (:get-user-data s) :edges edges})
        [:fullscreen-requested output]
          (put w :fullscreen-requested [:enter (when output (:get-user-data output))])
        [:exit-fullscreen-requested]
          (put w :fullscreen-requested [:exit]))))
  (:set-user-data obj w)
  w)

# --- Fx ---

(dispatch/reg-fx :window/create
  (fn [ctx obj]
    (def w (create obj))
    (array/push (ctx :windows) w)
    (array/push (ctx :render-order) w)
    (log/debugf "window created wid=%d" (w :wid))))
