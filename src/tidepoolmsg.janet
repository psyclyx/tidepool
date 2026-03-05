(defn- socket-path []
  (string (assert (os/getenv "XDG_RUNTIME_DIR") "XDG_RUNTIME_DIR not set")
          "/tidepool-"
          (assert (os/getenv "WAYLAND_DISPLAY") "WAYLAND_DISPLAY not set")))

(defn- msg-send [stream msg]
  (def buf @"")
  (def n (length msg))
  (buffer/push-byte buf (band n 0xFF))
  (buffer/push-byte buf (band (brushift n 8) 0xFF))
  (buffer/push-byte buf (band (brushift n 16) 0xFF))
  (buffer/push-byte buf (band (brushift n 24) 0xFF))
  (buffer/push-string buf msg)
  (:write stream buf))

(defn- msg-recv [stream]
  (def hdr @"")
  (unless (:chunk stream 4 hdr) (break nil))
  (def len (+ (hdr 0) (* (hdr 1) 0x100) (* (hdr 2) 0x10000) (* (hdr 3) 0x1000000)))
  (when (= len 0) (break @""))
  (def payload @"")
  (unless (:chunk stream len payload) (break nil))
  payload)

(defn- recv-skip-output [stream]
  (forever
    (def msg (msg-recv stream))
    (unless msg (break nil))
    (cond
      (and (> (length msg) 0) (= (msg 0) 0xFF))
      (do (prin (string/slice msg 1)) (flush))

      (and (> (length msg) 0) (= (msg 0) 0xFE))
      (break (buffer/slice msg 1))

      (break msg))))

(defn main [& args]
  (def expr (get args 1))
  (unless expr
    (eprint "usage: tidepoolmsg <janet-expression>")
    (os/exit 1))

  (def path (socket-path))
  (with [stream (net/connect :unix path)]
    (msg-send stream (string/format "\xFF%j" {:name "tidepoolmsg" :auto-flush true}))
    (recv-skip-output stream)
    (msg-send stream (string expr "\n"))
    (forever
      (def msg (msg-recv stream))
      (unless msg (break))
      (cond
        (and (> (length msg) 0) (= (msg 0) 0xFF))
        (do (prin (string/slice msg 1)) (flush))

        (and (> (length msg) 0) (= (msg 0) 0xFE))
        (do)

        (break)))))
