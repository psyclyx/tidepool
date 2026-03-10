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
    (if (and (> (length msg) 0) (= (msg 0) 0xFF))
      (do (prin (string/slice msg 1)) (flush))
      (break))))

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
  (def topic-keywords @[;(map keyword topics)])
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

(defn- cmd-action [stream args]
  (when (= (length args) 0)
    (eprint "usage: tidepoolmsg action <name> [args...]")
    (os/exit 1))
  (def name (get args 0))
  (def action-args (slice args 1))
  (def quoted-args (string/join (map |(string/format "%q" $) action-args) " "))
  (def expr (string "(ipc/dispatch " (string/format "%q" name)
                     (if (> (length action-args) 0)
                       (string " " quoted-args)
                       "")
                     ")"))
  (send-eval stream expr))

(defn- cmd-bindings [stream]
  (send-eval stream "(print (json/encode (ipc/list-bindings)))"))

(defn- usage []
  (eprint ```
usage: tidepoolmsg <command> [args...]

commands:
  repl               interactive REPL (default)
  eval <expr>        evaluate a Janet expression
  action <name> [a]  execute a named action
  bindings           list all keybindings as JSON
  watch <topic...>   stream topic updates as JSON lines
  save               serialize current state to stdout
  load               apply state from stdin

watch topics: tags, layout, title
```)
  (os/exit 1))

(defn- cmd-completions [shell]
  (case shell
    "bash" (print ```
_tidepoolmsg() {
    local cur prev commands topics actions
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="repl eval action bindings watch save load help completions"
    topics="tags layout title"
    actions="spawn close zoom float fullscreen focus swap focus-output focus-last send-to-output focus-tag set-tag toggle-tag focus-all-tags toggle-scratchpad send-to-scratchpad cycle-layout set-layout resize cycle-width equalize consume expel cycle-mode set-mode passthrough restart exit"

    case "$prev" in
        tidepoolmsg)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
        watch)
            COMPREPLY=($(compgen -W "$topics" -- "$cur"))
            ;;
        action)
            COMPREPLY=($(compgen -W "$actions" -- "$cur"))
            ;;
    esac

    if [[ ${COMP_WORDS[1]} == "watch" && $COMP_CWORD -ge 2 ]]; then
        COMPREPLY=($(compgen -W "$topics" -- "$cur"))
    fi
}
complete -F _tidepoolmsg tidepoolmsg
```)
    "zsh" (print ```
#compdef tidepoolmsg

_tidepoolmsg() {
    local -a commands topics actions
    commands=(
        'repl:interactive REPL'
        'eval:evaluate a Janet expression'
        'action:execute a named action'
        'bindings:list all keybindings as JSON'
        'watch:stream topic updates as JSON lines'
        'save:serialize current state to stdout'
        'load:apply state from stdin'
        'help:show usage information'
        'completions:output shell completions'
    )
    topics=(tags layout title)
    actions=(spawn close zoom float fullscreen focus swap focus-output focus-last send-to-output focus-tag set-tag toggle-tag focus-all-tags toggle-scratchpad send-to-scratchpad cycle-layout set-layout resize cycle-width equalize consume expel cycle-mode set-mode passthrough restart exit)

    if (( CURRENT == 2 )); then
        _describe 'command' commands
    else
        case "$words[2]" in
            watch)
                _values 'topic' $topics
                ;;
            action)
                _values 'action' $actions
                ;;
            eval)
                _message 'expression'
                ;;
            completions)
                _values 'shell' bash zsh fish
                ;;
        esac
    fi
}

_tidepoolmsg "$@"
```)
    "fish" (print ```
complete -c tidepoolmsg -f
complete -c tidepoolmsg -n '__fish_use_subcommand' -a repl -d 'interactive REPL'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a eval -d 'evaluate a Janet expression'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a action -d 'execute a named action'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a bindings -d 'list all keybindings as JSON'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a watch -d 'stream topic updates as JSON lines'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a save -d 'serialize current state to stdout'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a load -d 'apply state from stdin'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a help -d 'show usage information'
complete -c tidepoolmsg -n '__fish_use_subcommand' -a completions -d 'output shell completions'
complete -c tidepoolmsg -n '__fish_seen_subcommand_from action' -a 'spawn close zoom float fullscreen focus swap focus-output focus-last send-to-output focus-tag set-tag toggle-tag focus-all-tags toggle-scratchpad send-to-scratchpad cycle-layout set-layout resize cycle-width equalize consume expel cycle-mode set-mode passthrough restart exit'
complete -c tidepoolmsg -n '__fish_seen_subcommand_from watch' -a 'tags layout title'
complete -c tidepoolmsg -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'
```)
    (do
      (eprint "usage: tidepoolmsg completions <bash|zsh|fish>")
      (os/exit 1))))

(defn main [& args]
  (def subcmd (get args 1))

  (when (or (= subcmd "-h") (= subcmd "--help") (= subcmd "help"))
    (usage))

  (when (= subcmd "completions")
    (cmd-completions (get args 2))
    (os/exit 0))

  (with [stream (connect)]
    (match subcmd
      nil (cmd-repl stream)
      "repl" (cmd-repl stream)
      "eval" (cmd-eval stream (slice args 2))
      "action" (cmd-action stream (slice args 2))
      "bindings" (cmd-bindings stream)
      "watch" (cmd-watch stream (slice args 2))
      "save" (cmd-save stream)
      "load" (cmd-load stream)
      # Default: treat first arg as an expression (backwards compat)
      (cmd-eval stream (slice args 1)))))
