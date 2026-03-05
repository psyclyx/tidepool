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

(defn- connect []
  (def path (socket-path))
  (def stream (net/connect :unix path))
  (msg-send stream (string/format "\xFF%j" {:name "tidepoolmsg" :auto-flush true}))
  (recv-skip-output stream)
  stream)

(defn- send-eval [stream expr]
  (msg-send stream (string expr "\n"))
  (forever
    (def msg (msg-recv stream))
    (unless msg (break))
    (cond
      (and (> (length msg) 0) (= (msg 0) 0xFF))
      (do (prin (string/slice msg 1)) (flush))

      (and (> (length msg) 0) (= (msg 0) 0xFE))
      (do)

      (break))))

(defn- stream-output [stream]
  "Read and print all output messages until disconnect."
  (forever
    (def msg (msg-recv stream))
    (unless msg (break))
    (when (and (> (length msg) 0) (= (msg 0) 0xFF))
      (prin (string/slice msg 1))
      (flush))))

(defn- cmd-eval [stream args]
  (def expr (string/join args " "))
  (when (= (length expr) 0)
    (eprint "usage: tidepoolmsg eval <expression>")
    (os/exit 1))
  (send-eval stream expr))

(defn- cmd-repl [stream]
  (if (os/isatty)
    # Interactive REPL
    (do
      (prin "tidepoolmsg> ")
      (flush)
      (while (def line (getline))
        (def trimmed (string/trim line))
        (when (> (length trimmed) 0)
          (send-eval stream trimmed))
        (prin "tidepoolmsg> ")
        (flush)))
    # Pipe mode: read lines and eval each
    (while (def line (file/read stdin :line))
      (def trimmed (string/trim line))
      (when (> (length trimmed) 0)
        (send-eval stream trimmed)))))

(defn- cmd-watch [stream topics]
  (when (= (length topics) 0)
    (eprint "usage: tidepoolmsg watch <topic> [topic...]")
    (eprint "topics: tags, layout, title")
    (os/exit 1))
  (def topic-keywords (map keyword topics))
  (def expr (string/format "(ipc/watch-json %j)" topic-keywords))
  (msg-send stream (string expr "\n"))
  (stream-output stream))

(defn- cmd-save [stream]
  (msg-send stream "(ipc/serialize-state)\n")
  (stream-output stream))

(defn- cmd-load [stream]
  (def data (string/trim (or (file/read stdin :all) "")))
  (when (= (length data) 0)
    (eprint "tidepoolmsg load: no data on stdin")
    (os/exit 1))
  (def expr (string "(ipc/apply-state (parse ``" data "``))"))
  (send-eval stream expr))

(defn main [& args]
  (def subcmd (get args 1))

  (with [stream (connect)]
    (match subcmd
      nil (cmd-repl stream)
      "repl" (cmd-repl stream)
      "eval" (cmd-eval stream (slice args 2))
      "watch" (cmd-watch stream (slice args 2))
      "save" (cmd-save stream)
      "load" (cmd-load stream)
      # Default: treat first arg as an expression (backwards compat)
      (cmd-eval stream (slice args 1)))))
