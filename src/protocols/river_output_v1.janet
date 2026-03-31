(import ../dispatch)

(def interface "river_output_v1")

(dispatch/reg-proto interface :removed
  (fn [ctx output]
    (put output :removed true) nil))

(dispatch/reg-proto interface :position
  (fn [ctx x y output]
    (put output :x x) (put output :y y) nil))

(dispatch/reg-proto interface :dimensions
  (fn [ctx w h output]
    (put output :w w) (put output :h h) nil))

(dispatch/reg-proto interface :wl-output
  (fn [ctx global-name output]
    {:wl-output/bind {:output output :global-name global-name}}))
