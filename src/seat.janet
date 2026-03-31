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

(defn bind-key [ctx seat keysym mods action-fn]
  (def xkb-proxy (get-in (ctx :registry) [:proxies "river_xkb_bindings_v1"]))
  (def obj (:get-xkb-binding xkb-proxy (seat :obj)
                              (xkbcommon/keysym keysym) mods))
  (def binding @{:obj obj :keysym keysym :mods mods :action action-fn})
  (:set-handler obj (dispatch/proxy-handler ctx "river_xkb_binding_v1" seat binding))
  (:enable obj)
  (array/push (seat :xkb-bindings) binding))

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
    (:set-handler ls (dispatch/proxy-handler ctx "river_layer_shell_seat_v1" seat)))
  (:set-handler obj (dispatch/proxy-handler ctx "river_seat_v1" seat))
  (:set-user-data obj seat)
  (:set-xcursor-theme obj (config :xcursor-theme) (config :xcursor-size))
  seat)

(defn add [ctx obj]
  (def s (create obj ctx))
  (array/push (ctx :seats) s)
  (log/debugf "seat created"))
