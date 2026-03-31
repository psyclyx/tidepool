# Wayland client registry: track globals, bind interfaces, swap handlers.
#
# Three plain tables:
#   globals  @{global-name {:interface iface :version v}}  — filled by registry events
#   specs    {"iface" {:min-version n :handler factory}}   — declared by caller
#   bindings @{global-name @{:proxy wl-obj :handler fn :interface iface}}
#
# Handler factory: (fn [global-name global] handler-or-nil)
# Hot-swap at the REPL: (put (bindings global-name) :handler new-fn)
#   or: (client/rebind registry "iface" new-spec)

(import ./log)
(import ./perf)

(defn- make-dispatch
  [binding]
  (fn [event]
    (when-let [handler (binding :handler)]
      (log/tracef "event %s %q" (binding :interface) event)
      (handler event))))

(defn bind
  [wl-registry bindings proxies global-name global spec]
  (let [iface (global :interface)
        proxy (:bind wl-registry global-name iface (global :version))
        handler (when-let [factory (spec :handler)] (factory global-name global))
        binding @{:proxy proxy :handler handler :interface iface}]
    (:set-handler proxy (make-dispatch binding))
    (put bindings global-name binding)
    (put proxies iface proxy)
    (log/debugf "bound %s (global %d) v%d" iface global-name (global :version))))

(defn unbind
  [bindings proxies global-name]
  (when-let [binding (get bindings global-name)]
    (:destroy (binding :proxy))
    (put proxies (binding :interface) nil)
    (put bindings global-name nil)))

(defn rebind
  [registry interface spec]
  (let [{:obj wl-registry :globals globals :bindings bindings
         :proxies proxies :specs specs} registry]
    (put specs interface spec)
    (eachp [global-name global] globals
      (when (and global (= interface (global :interface)))
        (unbind bindings proxies global-name)
        (when (and spec (>= (global :version) (spec :min-version)))
          (bind wl-registry bindings proxies global-name global spec))))))

(defn- registry-handler
  [wl-registry globals specs bindings proxies]
  (fn [event]
    (match event
      [:global global-name interface version]
      (do
        (log/tracef "global %d %s v%d" global-name interface version)
        (def global {:interface interface :version version})
        (put globals global-name global)
        (when-let [spec (get specs interface)]
          (if (>= version (spec :min-version))
            (bind wl-registry bindings proxies global-name global spec)
            (if (spec :optional)
              (log/warnf "%s v%d too old (need v%d), skipping"
                         interface version (spec :min-version))
              (errorf "%s v%d too old (need v%d)"
                      interface version (spec :min-version))))))
      [:global-remove global-name]
      (do
        (log/debugf "global_remove %d" global-name)
        (put globals global-name nil)
        (unbind bindings proxies global-name)))))


(defn create
  "Create a registry and set up the global handler. Call connect to roundtrip."
  [display specs]
  (let [wl-registry (:get-registry display)
        globals @{}
        bindings @{}
        proxies @{}]
    (:set-handler wl-registry (registry-handler wl-registry globals specs bindings proxies))
    @{:obj wl-registry
      :globals globals
      :specs specs
      :bindings bindings
      :proxies proxies}))

(defn connect
  "Initial roundtrip: bind globals, verify required interfaces."
  [display registry]
  (perf/time :debug "client/connect"
    (:roundtrip display)
    (eachp [interface spec] (registry :specs)
      (unless (spec :optional)
        (unless ((registry :proxies) interface)
          (errorf "required interface %s not available from compositor" interface))))
    (log/infof "registry: %d globals, %d bound"
               (length (registry :globals)) (length (registry :bindings)))))
