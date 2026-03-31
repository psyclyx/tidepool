(import ../dispatch)

(def interface "river_window_manager_v1")

(dispatch/reg-proto interface :unavailable
  (fn [_ctx]
    {:exit/error "tidepool: another window manager is already running"}))

(dispatch/reg-proto interface :finished
  (fn [_ctx]
    {:exit/success true}))

(dispatch/reg-proto interface :manage-start
  (fn [ctx]
    {:dispatch [:manage]}))

(dispatch/reg-proto interface :render-start
  (fn [ctx]
    {:dispatch [:render]}))

(dispatch/reg-proto interface :output
  (fn [_ctx obj]
    {:output/create obj}))

(dispatch/reg-proto interface :seat
  (fn [_ctx obj]
    {:seat/create obj}))

(dispatch/reg-proto interface :window
  (fn [_ctx obj]
    {:window/create obj}))
