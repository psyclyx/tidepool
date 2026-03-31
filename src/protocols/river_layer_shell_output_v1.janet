(import ../dispatch)

(def interface "river_layer_shell_output_v1")

(dispatch/reg-proto interface :non-exclusive-area
  (fn [ctx x y w h output]
    (put output :non-exclusive-area [x y w h]) nil))
