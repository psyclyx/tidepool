(import ../dispatch)
(import ../output)

(def interface "river_output_v1")

(dispatch/reg-proto interface :removed
  (fn [ctx o]
    (put o :removed true) nil))

(dispatch/reg-proto interface :position
  (fn [ctx x y o]
    (put o :x x) (put o :y y) nil))

(dispatch/reg-proto interface :dimensions
  (fn [ctx w h o]
    (put o :w w) (put o :h h) nil))

(dispatch/reg-proto interface :wl-output
  (fn [ctx global-name output]
    (output/bind-wl-output ctx output global-name) nil))
