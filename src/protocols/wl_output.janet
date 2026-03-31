(import ../dispatch)

(def interface "wl_output")

(dispatch/reg-proto interface :name
  (fn [ctx n output]
    {:put [output :name n]}))
