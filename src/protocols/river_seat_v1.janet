(import ../dispatch)

(def interface "river_seat_v1")

(dispatch/reg-proto interface :removed
  (fn [_ctx seat]
    {:put [seat :removed true]}))

(dispatch/reg-proto interface :pointer-enter
  (fn [_ctx w seat]
    {:put [seat :pointer-target (:get-user-data w)]}))

(dispatch/reg-proto interface :pointer-leave
  (fn [_ctx seat]
    {:put [seat :pointer-target nil]}))

(dispatch/reg-proto interface :pointer-position
  (fn [_ctx x y seat]
    {:put-all [seat :pointer-x x :pointer-y y :pointer-moved true]}))

(dispatch/reg-proto interface :window-interaction
  (fn [_ctx w seat]
    {:put [seat :window-interaction (:get-user-data w)]}))

(dispatch/reg-proto interface :op-delta
  (fn [_ctx dx dy seat]
    (when-let [op (seat :op)]
      {:put-all [op :dx dx :dy dy]})))

(dispatch/reg-proto interface :op-release
  (fn [_ctx seat]
    {:put [seat :op-release true]}))
