(import ./log)

# Per-label stats: @{label @{:count n :total ms :min ms :max ms :last ms}}
(var- stats @{})

(defn- record [label elapsed-ms]
  (if-let [s (stats label)]
    (do
      (+= (s :count) 1)
      (+= (s :total) elapsed-ms)
      (when (< elapsed-ms (s :min)) (put s :min elapsed-ms))
      (when (> elapsed-ms (s :max)) (put s :max elapsed-ms))
      (put s :last elapsed-ms))
    (put stats label @{:count 1 :total elapsed-ms
                        :min elapsed-ms :max elapsed-ms
                        :last elapsed-ms})))

(defn sample
  ``Record a duration manually (ms). Use when you have your own timing.``
  [label elapsed-ms]
  (record label elapsed-ms))

(defmacro time
  ``Time body, log at lvl, accumulate stats under label.
  Returns body's value. Skips clock calls when lvl is inactive.``
  [lvl label & body]
  (with-syms [$start $result $ms]
    ~(if (,log/active? ,lvl)
       (let [,$start (os/clock :monotonic)
             ,$result (do ,;body)
             ,$ms (* 1000 (- (os/clock :monotonic) ,$start))]
         (,log/emit ,lvl (,string/format "%s %.2fms" ,label ,$ms))
         (,record ,label ,$ms)
         ,$result)
       (do ,;body))))

(defmacro time-quiet
  ``Time body, accumulate stats under label, don't log.
  Skips clock calls when trace is inactive.``
  [label & body]
  (with-syms [$start $result $ms]
    ~(if (,log/active? :trace)
       (let [,$start (os/clock :monotonic)
             ,$result (do ,;body)
             ,$ms (* 1000 (- (os/clock :monotonic) ,$start))]
         (,record ,label ,$ms)
         ,$result)
       (do ,;body))))

(defn get-stats
  ``Get stats table for a label, or all stats if no label.``
  [&opt label]
  (if label (get stats label) stats))

(defn report
  ``Print summary of accumulated stats.``
  []
  (each label (sorted (keys stats))
    (let [s (stats label)
          avg (/ (s :total) (s :count))]
      (printf "  %-24s n=%-6d avg=%.2fms min=%.2fms max=%.2fms last=%.2fms"
              label (s :count) avg (s :min) (s :max) (s :last)))))

(defn reset
  ``Clear all accumulated stats.``
  []
  (table/clear stats))
