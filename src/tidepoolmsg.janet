(import spork/netrepl)
(import spork/msg)
(import spork/json)

# --- Socket paths ---

(defn- runtime-dir []
  (assert (os/getenv "XDG_RUNTIME_DIR") "XDG_RUNTIME_DIR not set"))

(defn- wayland-display []
  (assert (os/getenv "WAYLAND_DISPLAY") "WAYLAND_DISPLAY not set"))

(defn- repl-path []
  (string/format "%s/tidepool-%s" (runtime-dir) (wayland-display)))

(defn- ipc-path []
  (string/format "%s/tidepool-ipc-%s" (runtime-dir) (wayland-display)))

# --- REPL commands ---

(defn- cmd-repl []
  (netrepl/client :unix (repl-path) "tidepoolmsg"))

(defn- cmd-exec [expr]
  (with [stream (net/connect :unix (repl-path))]
    (def send (msg/make-send stream))
    (def recvraw (msg/make-recv stream))
    (defn recv []
      (def x (recvraw))
      (case (get x 0)
        0xFF (do (prin (string/slice x 1)) (flush) (recv))
        0xFE (string/slice x 1)
        x))
    # Handshake
    (send (string/format "\xFF%j" {:auto-flush true :name "tidepoolmsg"}))
    # Read initial prompt
    (recv)
    # Send expression
    (send expr)
    # Read until next prompt (auto-flush prints output along the way)
    (recv)))

# --- IPC commands ---

(defn- ipc-connect []
  (net/connect :unix (ipc-path)))

(defn- ipc-send [stream msg]
  (ev/write stream (string (json/encode msg) "\n")))

(defn- ipc-recv [stream]
  (def buf @"")
  (forever
    (def chunk (ev/read stream 4096))
    (unless chunk (break))
    (buffer/push buf chunk)
    (when-let [idx (string/find "\n" buf)]
      (def line (string/slice buf 0 idx))
      (def rest (buffer/slice buf (+ idx 1)))
      (buffer/clear buf)
      (buffer/push buf rest)
      (break (json/decode line))))
  nil)

(defn- cmd-dispatch [action & args]
  (with [stream (ipc-connect)]
    (def params @{"name" action})
    (when (not (empty? args))
      (def parsed (map |(let [n (scan-number $)] (if n n $)) args))
      (put params "args" parsed))
    (ipc-send stream {"jsonrpc" "2.0" "id" 1
                       "method" "action" "params" params})
    (def resp (ipc-recv stream))
    (if (get resp "error")
      (do (eprintf "error: %s" (get-in resp ["error" "message"]))
          (os/exit 1))
      (print (json/encode (get resp "result"))))))

(defn- cmd-watch [& event-types]
  (with [stream (ipc-connect)]
    (def params (when (not (empty? event-types))
                  {"events" (array ;event-types)}))
    (ipc-send stream {"jsonrpc" "2.0" "id" 1
                       "method" "watch" "params" params})
    # Read watch confirmation
    (ipc-recv stream)
    # Stream events
    (def buf @"")
    (forever
      (def chunk (ev/read stream 4096))
      (unless chunk (break))
      (buffer/push buf chunk)
      (while (def idx (string/find "\n" buf))
        (def line (string/slice buf 0 idx))
        (def rest (buffer/slice buf (+ idx 1)))
        (buffer/clear buf)
        (buffer/push buf rest)
        (when (> (length line) 0)
          (print line)
          (flush))))))

# --- Shell completions ---

(def- actions
  ["close-focused" "focus-next" "focus-prev" "swap-next" "swap-prev"
   "focus-tag" "send-to-tag" "spawn"])

(def- event-types
  ["window:new" "window:closed" "focus:changed"])

(defn- completions-bash []
  (print ```
_tidepoolmsg() {
    local cur prev commands actions events
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="repl exec dispatch watch completions"
    actions="``` (string/join actions " ") ```"
    events="``` (string/join event-types " ") ```"

    case "$prev" in
        tidepoolmsg)
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            ;;
        dispatch)
            COMPREPLY=( $(compgen -W "$actions" -- "$cur") )
            ;;
        watch)
            COMPREPLY=( $(compgen -W "$events" -- "$cur") )
            ;;
    esac
}
complete -F _tidepoolmsg tidepoolmsg
```))

(defn- completions-zsh []
  (print (string ```
#compdef tidepoolmsg

_tidepoolmsg() {
    local -a commands actions events
    commands=(
        'repl:Interactive REPL session'
        'exec:Evaluate expression and print result'
        'dispatch:Call an IPC action'
        'watch:Subscribe to IPC events'
        'completions:Generate shell completions'
    )
    actions=(``` (string/join (map |(string "'" $ "'") actions) " ") ```)
    events=(``` (string/join (map |(string "'" $ "'") event-types) " ") ```)

    _arguments '1:command:->cmd' '*:arg:->args'

    case "$state" in
        cmd)
            _describe 'command' commands
            ;;
        args)
            case "${words[2]}" in
                dispatch) _describe 'action' actions ;;
                watch) _describe 'event' events ;;
            esac
            ;;
    esac
}

_tidepoolmsg
```)))

(defn- completions-fish []
  (print (string
    "complete -c tidepoolmsg -f\n"
    "complete -c tidepoolmsg -n '__fish_use_subcommand' -a 'repl' -d 'Interactive REPL session'\n"
    "complete -c tidepoolmsg -n '__fish_use_subcommand' -a 'exec' -d 'Evaluate expression and print result'\n"
    "complete -c tidepoolmsg -n '__fish_use_subcommand' -a 'dispatch' -d 'Call an IPC action'\n"
    "complete -c tidepoolmsg -n '__fish_use_subcommand' -a 'watch' -d 'Subscribe to IPC events'\n"
    "complete -c tidepoolmsg -n '__fish_use_subcommand' -a 'completions' -d 'Generate shell completions'\n"
    (string/join (map |(string "complete -c tidepoolmsg -n '__fish_seen_subcommand_from dispatch' -a '" $ "'\n") actions))
    (string/join (map |(string "complete -c tidepoolmsg -n '__fish_seen_subcommand_from watch' -a '" $ "'\n") event-types)))))

# --- Usage ---

(defn- usage []
  (eprint `Usage: tidepoolmsg <command> [args...]

Commands:
  repl                   Interactive REPL session
  exec <expr>            Evaluate expression, print result, exit
  dispatch <action> [args...]  Call an IPC action
  watch [event-types...] Subscribe to IPC events
  completions <shell>    Generate shell completions (bash, zsh, fish)`))

(defn main [& args]
  (def cmd (get args 1))
  (case cmd
    "repl" (cmd-repl)
    "exec" (if-let [expr (get args 2)]
             (cmd-exec expr)
             (do (eprint "error: exec requires an expression") (os/exit 1)))
    "dispatch" (if-let [action (get args 2)]
                 (cmd-dispatch action ;(slice args 3))
                 (do (eprint "error: dispatch requires an action name") (os/exit 1)))
    "watch" (cmd-watch ;(slice args 2))
    "completions" (case (get args 2)
                    "bash" (completions-bash)
                    "zsh" (completions-zsh)
                    "fish" (completions-fish)
                    (do (eprint "error: specify bash, zsh, or fish") (os/exit 1)))
    (do (usage) (os/exit (if cmd 1 0)))))
