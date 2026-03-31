(import ../dispatch)

(def interface "river_window_v1")

(dispatch/reg-proto interface :closed
  (fn [_ctx window]
    (put window :closed true) nil))

(dispatch/reg-proto interface :dimensions
  (fn [_ctx width height window]
    (put window :w width)
    (put window :h height) nil))

(dispatch/reg-proto interface :dimensions-hint
  (fn [_ctx min-w min-h max-w max-h window]
    (put window :min-w min-w) (put window :min-h min-h)
    (put window :max-w max-w) (put window :max-h max-h) nil))

(dispatch/reg-proto interface :app-id
  (fn [_ctx id window]
    (put window :app-id id) nil))

(dispatch/reg-proto interface :title
  (fn [_ctx t window]
    (put window :title t) nil))

(dispatch/reg-proto interface :parent
  (fn [_ctx p window]
    (put window :wl-parent (when p (:get-user-data p))) nil))

(dispatch/reg-proto interface :decoration-hint
  (fn [_ctx _ _window] nil))

(dispatch/reg-proto interface :pointer-move-requested
  (fn [_ctx s window]
    (put window :pointer-move-requested (:get-user-data s)) nil))

(dispatch/reg-proto interface :pointer-resize-requested
  (fn [_ctx s edges window]
    (put window :pointer-resize-requested @{:seat (:get-user-data s) :edges edges}) nil))

(dispatch/reg-proto interface :fullscreen-requested
  (fn [_ctx output window]
    (put window :fullscreen-requested [:enter (when output (:get-user-data output))]) nil))

(dispatch/reg-proto interface :exit-fullscreen-requested
  (fn [_ctx window]
    (put window :fullscreen-requested [:exit]) nil))
