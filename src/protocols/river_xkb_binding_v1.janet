(import ../dispatch)

(def interface "river_xkb_binding_v1")

(dispatch/reg-proto interface :pressed
  (fn [_ctx seat binding]
    (put seat :pending-action (binding :action)) nil))
