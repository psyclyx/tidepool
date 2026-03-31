(import ../dispatch)

(def interface "river_seat_v1")

(dispatch/reg-proto interface :removed
  (fn [_ctx seat]
    (put seat :removed true) nil))

(dispatch/reg-proto interface :pointer-enter
  (fn [_ctx w seat]
    (put seat :pointer-target (:get-user-data w)) nil))

(dispatch/reg-proto interface :pointer-leave
  (fn [_ctx seat]
    (put seat :pointer-target nil) nil))

(dispatch/reg-proto interface :pointer-position
  (fn [_ctx x y seat]
    (put seat :pointer-x x) (put seat :pointer-y y)
    (put seat :pointer-moved true) nil))

(dispatch/reg-proto interface :window-interaction
  (fn [_ctx w seat]
    (put seat :window-interaction (:get-user-data w)) nil))

(dispatch/reg-proto interface :op-delta
  (fn [_ctx dx dy seat]
    (when-let [op (seat :op)]
      (put op :dx dx) (put op :dy dy)) nil))

(dispatch/reg-proto interface :op-release
  (fn [_ctx seat]
    (put seat :op-release true) nil))
