(import ../dispatch)

(def interface "river_xkb_binding_v1")

(dispatch/reg-proto interface :pressed
  (fn [_ctx seat binding]
    (array/push (seat :pending-actions) (binding :action)) nil))
