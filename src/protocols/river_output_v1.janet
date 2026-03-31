(import ../dispatch)

(def interface "river_output_v1")

(dispatch/reg-proto interface :removed
  (fn [ctx output]
    {:put [output :removed true]}))

(dispatch/reg-proto interface :position
  (fn [ctx x y output]
    {:put-all [output :x x :y y]}))

(dispatch/reg-proto interface :dimensions
  (fn [ctx w h output]
    {:put-all [output :w w :h h]}))

(dispatch/reg-proto interface :wl-output
  (fn [ctx global-name output]
    {:wl-output/bind {:output output :global-name global-name}}))
