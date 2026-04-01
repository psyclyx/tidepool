(import spork/netrepl)

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
      "-c" (do (++ i) (set init-path (assert (get args i) "-c requires a path")))
      "--config" (do (++ i) (set init-path (assert (get args i) "--config requires a path"))))
    (++ i))
  {:init-path init-path})

(defn exec-path
  [path env]
  (when (os/stat path)
    (dofile path :env (table/setproto @{} env))))

(defn repl-server-create
  "Start a REPL server on a Unix socket."
  [env]
  (def path (string/format "%s/tidepool-%s"
                           (assert (os/getenv "XDG_RUNTIME_DIR"))
                           (assert (os/getenv "WAYLAND_DISPLAY"))))
  (protect (os/rm path))
  (netrepl/server :unix path
                  (fn [name stream]
                    (table/setproto @{:netrepl-stream stream} env))))
