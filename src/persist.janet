(import ./state)
(import ./pool)
(import ./pool/persist :as pool-persist)

(defn serialize
  "Serialize current state to a JDN string and print to stdout."
  []
  (def outputs (state/wm :outputs))
  (def wrapped-outputs
    (filter truthy? (seq [o :in outputs]
      (when (and (o :x) (o :y) (o :tag-pools))
        @{:connector (string (o :x) "," (o :y))
          :tag-pools (o :tag-pools)
          :active-tag (or (o :active-tag) 1)}))))
  (print (pool-persist/serialize wrapped-outputs))
  (flush))

(defn apply-state
  "Apply parsed state data to restore pool trees."
  [data]
  (unless (dictionary? data)
    (break))
  (def windows (state/wm :windows))
  (def outputs (state/wm :outputs))
  # Collect all live, non-floating tiled windows
  (def live-windows
    (filter |(and (not ($ :closed)) (not ($ :closing)) (not ($ :float)))
            windows))
  # Detach all live windows from current pool trees
  (each w live-windows
    (when-let [parent (w :parent)]
      (when (parent :children)
        (def idx (pool/child-index parent w))
        (when idx (pool/remove-child parent idx)))))
  # Restore pool trees
  (def result (pool-persist/restore data live-windows))
  # Match restored outputs to actual outputs by position
  (each restored (result :outputs)
    (when-let [actual (find |(= (string ($ :x) "," ($ :y))
                                (restored :connector))
                            outputs)]
      (put actual :tag-pools (restored :tag-pools))
      (when (restored :active-tag)
        (put actual :active-tag (restored :active-tag))))))
