(import ./output)
(import ./window)
(import ./seat)

(defn- tiled-on-output [ctx o]
  (filter |(and (not ($ :float)) (not ($ :closed)))
          (output/visible o (ctx :windows))))

(defn close-focused
  "Close the focused window."
  [ctx s]
  (when-let [w (s :focused)]
    (:close (w :obj))))

(defn focus-next
  "Focus the next tiled window."
  [ctx s]
  (when-let [o (s :focused-output)]
    (def tiled (tiled-on-output ctx o))
    (when (> (length tiled) 0)
      (def idx (or (find-index |(= $ (s :focused)) tiled) -1))
      (seat/focus s (tiled (% (+ idx 1) (length tiled)))))))

(defn focus-prev
  "Focus the previous tiled window."
  [ctx s]
  (when-let [o (s :focused-output)]
    (def tiled (tiled-on-output ctx o))
    (when (> (length tiled) 0)
      (def idx (or (find-index |(= $ (s :focused)) tiled) 0))
      (seat/focus s (tiled (% (+ idx (- (length tiled) 1))
                              (length tiled)))))))

(defn swap-next
  "Swap the focused window with the next in layout order."
  [ctx s]
  (when-let [o (s :focused-output)]
    (def tiled (tiled-on-output ctx o))
    (when (> (length tiled) 1)
      (when-let [idx (find-index |(= $ (s :focused)) tiled)]
        (def next-idx (% (+ idx 1) (length tiled)))
        (window/swap ctx (tiled idx) (tiled next-idx))))))

(defn swap-prev
  "Swap the focused window with the previous in layout order."
  [ctx s]
  (when-let [o (s :focused-output)]
    (def tiled (tiled-on-output ctx o))
    (when (> (length tiled) 1)
      (when-let [idx (find-index |(= $ (s :focused)) tiled)]
        (def prev-idx (% (+ idx (- (length tiled) 1)) (length tiled)))
        (window/swap ctx (tiled idx) (tiled prev-idx))))))

(defn focus-tag
  "Return an action that switches the focused output to a tag."
  [tag]
  (fn [ctx s]
    (when-let [o (s :focused-output)]
      (output/set-tags o {tag true}))))

(defn send-to-tag
  "Return an action that moves the focused window to a tag."
  [tag]
  (fn [ctx s]
    (when-let [w (s :focused)]
      (put w :tag tag))))

(defn spawn
  "Return an action that spawns a command."
  [& cmd]
  (fn [ctx s]
    (os/spawn [;cmd] :p)))
