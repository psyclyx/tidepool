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

(defn create [ctx obj]
  (def w @{:obj obj :node (:get-node obj)
           :new true :tag 1 :wid (++ next-wid)})
  (:set-handler obj (dispatch/proxy-handler ctx "river_window_v1" w))
  (:set-user-data obj w)
  w)

(defn swap [ctx a b]
  (def wins (ctx :windows))
  (def ai (find-index |(= $ a) wins))
  (def bi (find-index |(= $ b) wins))
  (when (and ai bi)
    (put wins ai b)
    (put wins bi a)))

(defn add [ctx obj]
  (def w (create ctx obj))
  (array/push (ctx :windows) w)
  (array/push (ctx :render-order) w)
  (log/debugf "window created wid=%d" (w :wid)))
