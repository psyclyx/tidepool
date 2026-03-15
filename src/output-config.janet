(import ./state)

(def output-heads @{})
(var output-mgr-serial nil)
(var output-config-applied false)

(defn handle-mode "Track an output mode's dimensions and refresh rate." [head mode-obj]
  (def mode @{:obj mode-obj})
  (:set-handler mode-obj
    (fn [event]
      (match event
        [:size w h] (do (put mode :width w) (put mode :height h))
        [:refresh r] (put mode :refresh r)
        [:preferred] (put mode :preferred true))))
  (array/push (head :modes) mode))

(defn handle-head "Track an output head with its modes and properties." [head-obj]
  (def head @{:obj head-obj :modes @[]})
  (:set-handler head-obj
    (fn [event]
      (match event
        [:name n] (do (put head :name n) (put output-heads n head))
        [:description d] (put head :description d)
        [:mode mode-obj] (handle-mode head mode-obj)
        [:current-mode mode-obj] (put head :current-mode mode-obj)
        [:enabled e] (put head :enabled (not= e 0))
        [:position x y] (do (put head :x x) (put head :y y))
        [:scale s] (put head :scale s)
        [:finished] (when (head :name) (put output-heads (head :name) nil))))))

(defn find-mode "Find a mode matching the given width and height." [head w h]
  (find |(and (= ($ :width) w) (= ($ :height) h)) (head :modes)))

(defn- find-output-config
  "Find config entry for a head, matching by connector name first, then by description."
  [outputs name description]
  (or (get outputs name)
      (when description
        (var found nil)
        (eachp [key target] outputs
          (when (and (not found)
                     (not= key name)
                     (string/find key description))
            (set found target)))
        found)))

(defn apply-config "Apply user output configuration (mode, position, scale)." []
  (when output-config-applied (break))
  (when-let [outputs (state/config :outputs)
             mgr (get state/registry "zwlr_output_manager_v1")
             serial output-mgr-serial]
    (def cfg (:create-configuration mgr serial))
    (:set-handler cfg
      (fn [event]
        (match event
          [:succeeded] (do (set output-config-applied true)
                          (when (state/config :debug)
                            (print "tidepool: output configuration applied")))
          [:failed] (eprint "tidepool: output configuration failed")
          [:cancelled] (eprint "tidepool: output configuration cancelled"))))
    (eachp [name head] output-heads
      (if-let [target (find-output-config outputs name (head :description))]
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
        (if (head :enabled)
          (let [cfg-head (:enable-head cfg (head :obj))]
            (when (head :current-mode)
              (:set-mode cfg-head (head :current-mode)))
            (:set-position cfg-head (or (head :x) 0) (or (head :y) 0))
            (:set-scale cfg-head (or (head :scale) 1.0)))
          (:disable-head cfg (head :obj)))))
    (:apply cfg)))

(defn handle-event "Dispatch output manager events." [event]
  (match event
    [:head head-obj] (handle-head head-obj)
    [:done serial] (do (set output-mgr-serial serial)
                       (apply-config))))
