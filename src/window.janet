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
    (and mw (> mw 0) mh (> mh 0)
         (or (and xw (> xw 0) xh (> xh 0) (= mw xw) (= mh xh))
             (and (w :w) (w :h) (= mw (w :w)) (= mh (w :h)))))))

(defn tag-output [w outputs]
  (find |(($ :tags) (w :tag)) outputs))

(defn set-float [w float]
  (put w :float float)
  (put w :float-changed true))

(defn should-float?
  "Determine if a window should be floating. Checks user rules first,
   then falls back to heuristics (parent, fixed-size, constrained max)."
  [w rules]
  # Check user rules first — :float can be false (force-tiled)
  (var rule-result nil)
  (each rule rules
    (when ((rule :match) w)
      (set rule-result (rule :float))
      (break)))
  (when (not (nil? rule-result)) (break rule-result))
  # Parent windows always float
  (when (and (w :wl-parent) (not ((w :wl-parent) :closed)))
    (break true))
  # Fixed-size windows float
  (when (fixed-size? w)
    (break true))
  # Constrained max dimensions suggest a dialog
  (when (and (w :max-w) (> (w :max-w) 0)
             (w :max-h) (> (w :max-h) 0)
             (< (w :max-w) 1200)
             (< (w :max-h) 900))
    (break true))
  false)

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
               (not (w :layout-hidden))
               (w :w) (w :h))
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
