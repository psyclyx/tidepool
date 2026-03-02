# Output configuration via zwlr_output_manager_v1 protocol.
# Applies declarative output layout (mode, position, scale) on startup.

(import ./state)

(def output-heads @{})
(var output-mgr-serial nil)
(var output-config-applied false)

(defn handle-mode [head mode-obj]
  (def mode @{:obj mode-obj})
  (:set-handler mode-obj
    (fn [event]
      (match event
        [:size w h] (do (put mode :width w) (put mode :height h))
        [:refresh r] (put mode :refresh r)
        [:preferred] (put mode :preferred true))))
  (array/push (head :modes) mode))

(defn handle-head [head-obj]
  (def head @{:obj head-obj :modes @[]})
  (:set-handler head-obj
    (fn [event]
      (match event
        [:name n] (do (put head :name n) (put output-heads n head))
        [:mode mode-obj] (handle-mode head mode-obj)
        [:current-mode mode-obj] (put head :current-mode mode-obj)
        [:enabled e] (put head :enabled (not= e 0))
        [:position x y] (do (put head :x x) (put head :y y))
        [:scale s] (put head :scale s)
        [:finished] (when (head :name) (put output-heads (head :name) nil))))))

(defn find-mode [head w h]
  (find |(and (= ($ :width) w) (= ($ :height) h)) (head :modes)))

(defn apply-config []
  (when output-config-applied (break))
  (when-let [outputs (state/config :outputs)
             mgr (get state/registry "zwlr_output_manager_v1")
             serial output-mgr-serial]
    (def cfg (:create-configuration mgr serial))
    (:set-handler cfg
      (fn [event]
        (match event
          [:succeeded] (do (set output-config-applied true)
                          (print "tidepool: output configuration applied"))
          [:failed] (eprint "tidepool: output configuration failed")
          [:cancelled] (eprint "tidepool: output configuration cancelled"))))
    (eachp [name head] output-heads
      (if-let [target (get outputs name)]
        # Head is in config
        (if (not= false (target :enable))
          (let [cfg-head (:enable-head cfg (head :obj))]
            (when-let [[tw th] (target :mode)
                       mode (find-mode head tw th)]
              (:set-mode cfg-head (mode :obj)))
            (when (target :pos)
              (:set-position cfg-head ;(target :pos)))
            (when (target :scale)
              (:set-scale cfg-head (target :scale))))
          (:disable-head cfg (head :obj)))
        # Head not in config — preserve current state
        (if (head :enabled)
          (let [cfg-head (:enable-head cfg (head :obj))]
            (when (head :current-mode)
              (:set-mode cfg-head (head :current-mode)))
            (:set-position cfg-head (or (head :x) 0) (or (head :y) 0))
            (:set-scale cfg-head (or (head :scale) 1.0)))
          (:disable-head cfg (head :obj)))))
    (:apply cfg)))

(defn handle-event [event]
  (match event
    [:head head-obj] (handle-head head-obj)
    [:done serial] (do (set output-mgr-serial serial)
                       (apply-config))))
