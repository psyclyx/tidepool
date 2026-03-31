(import ../dispatch)

(def interface "river_layer_shell_seat_v1")

(dispatch/reg-proto interface :focus-exclusive
  (fn [_ctx seat]
    (put seat :layer-focus :exclusive) nil))

(dispatch/reg-proto interface :focus-non-exclusive
  (fn [_ctx seat]
    (put seat :layer-focus :non-exclusive) nil))

(dispatch/reg-proto interface :focus-none
  (fn [_ctx seat]
    (put seat :layer-focus :none) nil))
