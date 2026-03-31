(import ../dispatch)
(import ../window)
(import ../seat)
(import ../output)
(import ../log)

(def interface "river_window_manager_v1")

(dispatch/reg-proto interface :unavailable
  (fn [_ctx]
    (log/error "tidepool: another window manager is already running")
    (os/exit 1)))

(dispatch/reg-proto interface :finished
  (fn [_ctx]
    (os/exit 0)))

(dispatch/reg-proto interface :manage-start
  (fn [ctx]
    (dispatch/dispatch ctx :manage) nil))

(dispatch/reg-proto interface :render-start
  (fn [ctx]
    (dispatch/dispatch ctx :render) nil))

(dispatch/reg-proto interface :output
  (fn [ctx obj]
    (output/add ctx obj) nil))

(dispatch/reg-proto interface :seat
  (fn [ctx obj]
    (seat/add ctx obj) nil))

(dispatch/reg-proto interface :window
  (fn [ctx obj]
    (window/add ctx obj) nil))
