(import spork/netrepl)

(var repl-env nil)

(defn init
  "Capture the calling environment as the REPL environment."
  []
  (set repl-env (curenv)))

(defn config-dir
  []
  (when-let [base-config-dir (or (os/getenv "XDG_CONFIG_HOME")
                                 (string (os/getenv "HOME") "/.config"))]
    (string base-config-dir "/tidepool")))

(defn default-init-path
  []
  (when-let [dir (config-dir)]
    (string dir "/init.janet")))

(defn parse-opts
  [args]
  (var init-path (default-init-path))
  (var i 1)
  (while (< i (length args))
    (case (args i)
      "-c" (do (++ i) (set init-path (get args i)))
      "--config" (do (++ i) (set init-path (get args i))))
    (++ i))
  {:init-path init-path})

(defn exec-path
  [path &opt bindings]
  (when (os/stat path)
    (def env (table/setproto @{} repl-env))
    (when bindings
      (eachp [k v] bindings
        (put env k @{:value v})))
    (dofile path :env env)))

(defn repl-server-create "Start a REPL server on a Unix socket." []
  (def path (string/format "%s/tidepool-%s"
                           (assert (os/getenv "XDG_RUNTIME_DIR"))
                           (assert (os/getenv "WAYLAND_DISPLAY"))))
  (protect (os/rm path))
  (netrepl/server :unix path
                  (fn [name stream]
                    (table/setproto @{:netrepl-stream stream} repl-env))))
