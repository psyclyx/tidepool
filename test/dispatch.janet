(import ./helper :as t)
(import dispatch)

# ============================================================
# reg-event / dispatch
# ============================================================

(t/test-start "dispatch: registered event handler is called")
(var called false)
(dispatch/reg-event :test-event (fn [ctx] (set called true)))
(dispatch/dispatch @{} :test-event)
(t/assert-truthy called)

(t/test-start "dispatch: handler receives ctx")
(var received nil)
(dispatch/reg-event :test-ctx (fn [ctx] (set received ctx)))
(def ctx @{:foo 42})
(dispatch/dispatch ctx :test-ctx)
(t/assert-eq (received :foo) 42)

(t/test-start "dispatch: unregistered event doesn't crash")
# Should log a warning but not error
(dispatch/dispatch @{} :nonexistent-event)
(t/assert-truthy true "no crash")

# ============================================================
# reg-proto / dispatch-proto
# ============================================================

(t/test-start "dispatch-proto: registered handler is called")
(var proto-args nil)
(dispatch/reg-proto "test_iface" :some-event
  (fn [ctx & args] (set proto-args args)))
(dispatch/dispatch-proto @{} "test_iface" [:some-event "arg1" 42])
(t/assert-eq (length proto-args) 2)
(t/assert-eq (proto-args 0) "arg1")
(t/assert-eq (proto-args 1) 42)

(t/test-start "dispatch-proto: unregistered is silent")
(dispatch/dispatch-proto @{} "unknown_iface" [:unknown-event])
(t/assert-truthy true "no crash")

# ============================================================
# proxy-handler
# ============================================================

(t/test-start "proxy-handler: appends extra args to event")
(var received-args nil)
(dispatch/reg-proto "proxy_test" :configure
  (fn [ctx & args] (set received-args args)))
(def handler (dispatch/proxy-handler @{} "proxy_test" "extra1" "extra2"))
(handler [:configure 100 200])
(t/assert-eq (length received-args) 4)
(t/assert-eq (received-args 0) 100)
(t/assert-eq (received-args 1) 200)
(t/assert-eq (received-args 2) "extra1")
(t/assert-eq (received-args 3) "extra2")

(t/report)
