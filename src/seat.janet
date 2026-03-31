(import ./dispatch)
(import ./log)
(import xkbcommon)

# --- Focus ---

(defn focus [seat win]
  (unless (= (seat :focused) win)
    (when (seat :focused)
      (put seat :focus-prev (seat :focused)))
    (put seat :focused win)
    (put seat :focus-changed true)))

(defn focus-output [seat o]
  (unless (= (seat :focused-output) o)
    (put seat :focused-output o)
    (put seat :focus-output-changed true)))

# --- Keybindings ---

(defn bind-key [seat keysym mods action-fn registry]
  (def xkb-proxy (get-in registry [:proxies "river_xkb_bindings_v1"]))
  (def obj (:get-xkb-binding xkb-proxy (seat :obj)
                              (xkbcommon/keysym keysym) mods))
  (:set-handler obj
    (fn [event]
      (match event
        [:pressed] (put seat :pending-action action-fn))))
  (:enable obj)
  (array/push (seat :xkb-bindings) @{:obj obj :keysym keysym :mods mods}))

# --- Create ---

(defn create [obj ctx]
  (def registry (ctx :registry))
  (def config (ctx :config))
  (def seat @{:obj obj
              :layer-focus :none
              :xkb-bindings @[]
              :new true})
  (when-let [ls-proxy (get-in registry [:proxies "river_layer_shell_v1"])]
    (def ls (:get-seat ls-proxy obj))
    (put seat :layer-shell ls)
    (:set-handler ls
      (fn [event]
        (match event
          [:focus-exclusive] (put seat :layer-focus :exclusive)
          [:focus-non-exclusive] (put seat :layer-focus :non-exclusive)
          [:focus-none] (put seat :layer-focus :none)))))
  (:set-handler obj
    (fn [event]
      (match event
        [:removed] (put seat :removed true)
        [:pointer-enter w] (put seat :pointer-target (:get-user-data w))
        [:pointer-leave] (put seat :pointer-target nil)
        [:pointer-position x y]
          (do (put seat :pointer-x x) (put seat :pointer-y y)
              (put seat :pointer-moved true))
        [:window-interaction w]
          (put seat :window-interaction (:get-user-data w))
        [:op-delta dx dy]
          (when-let [op (seat :op)] (put op :dx dx) (put op :dy dy))
        [:op-release] (put seat :op-release true))))
  (:set-user-data obj seat)
  (:set-xcursor-theme obj (config :xcursor-theme) (config :xcursor-size))
  seat)

# --- Fx ---

(dispatch/reg-fx :seat/create
  (fn [ctx obj]
    (def s (create obj ctx))
    (array/push (ctx :seats) s)
    (log/debugf "seat created")))
