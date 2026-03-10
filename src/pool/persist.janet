# Pool persistence: serialize/restore pool trees as JDN.

(import ../pool)

# Properties to save on pools
(def- pool-keys [:mode :id :active :active-row :ratio :weights :width :presets])

# --- Pretty-print JDN ---

(defn pp-jdn
  "Pretty-print a JDN value with indentation."
  [val &opt indent]
  (default indent 0)
  (def pad (string/repeat "  " indent))
  (def pad1 (string/repeat "  " (+ indent 1)))
  (cond
    (nil? val) "nil"
    (boolean? val) (string val)
    (number? val) (string/format "%g" val)
    (keyword? val) (string ":" val)
    (string? val) (string/format "%q" val)
    (symbol? val) (string val)
    (tuple? val)
    (if (= (length val) 0)
      "[]"
      (do
        (def parts @["["])
        (each item val
          (array/push parts (string pad1 (pp-jdn item (+ indent 1))))
          (array/push parts "\n"))
        # Remove trailing newline, close bracket
        (when (> (length parts) 1) (array/pop parts))
        (string (string/join parts) "]")))
    (array? val)
    (if (= (length val) 0)
      "@[]"
      (do
        (def buf @"@[\n")
        (for i 0 (length val)
          (buffer/push buf pad1 (pp-jdn (get val i) (+ indent 1)))
          (when (< i (- (length val) 1))
            (buffer/push buf "\n")))
        (buffer/push buf "]")
        (string buf)))
    (table? val)
    (if (= (length val) 0)
      "@{}"
      (do
        (def buf @"@{")
        (def ks (sorted (keys val)))
        (each k ks
          (buffer/push buf "\n" pad1
                       (pp-jdn k (+ indent 1)) " "
                       (pp-jdn (get val k) (+ indent 1))))
        (buffer/push buf "}")
        (string buf)))
    (struct? val)
    (if (= (length val) 0)
      "{}"
      (do
        (def buf @"{")
        (def ks (sorted (keys val)))
        (each k ks
          (buffer/push buf "\n" pad1
                       (pp-jdn k (+ indent 1)) " "
                       (pp-jdn (get val k) (+ indent 1))))
        (buffer/push buf "}")
        (string buf)))
    (string/format "%q" val)))

# --- Serialize ---

(defn- serialize-node
  "Recursively serialize a pool/window node for persistence."
  [node]
  (if (pool/window? node)
    # Window leaf → match key
    @{:app-id (node :app-id) :title (node :title)}
    # Pool → serialize structure
    (do
      (def result @{})
      (each k pool-keys
        (when-let [v (node k)]
          (put result k
            (cond
              # Zero out scroll offsets
              (= k :scroll-offset-x) @{}
              # Copy weights table
              (and (= k :weights) (table? v)) (table ;(kvs v))
              v))))
      (put result :children
        (seq [child :in (node :children)]
          (serialize-node child)))
      result)))

(defn serialize
  "Serialize outputs' pool trees to a pretty-printed JDN string."
  [outputs]
  (def data
    @{:outputs
      (seq [o :in outputs]
        @{:connector (o :connector)
          :pool (serialize-node (o :pool))})})
  (pp-jdn data))

# --- Restore ---

(defn- match-window
  "Find and consume a window from the available set matching app-id + title."
  [leaf available]
  (def target-app (leaf :app-id))
  (def target-title (leaf :title))
  (var result nil)
  (for i 0 (length available)
    (def w (get available i))
    (when (and (= (w :app-id) target-app)
               (= (w :title) target-title))
      (set result w)
      (array/remove available i)
      (break)))
  result)

(defn- is-leaf?
  "True if this saved node is a window leaf (has :app-id, no :children)."
  [node]
  (and (node :app-id) (not (node :children))))

(defn- restore-node
  "Recursively restore a pool tree node, matching window leaves."
  [node available]
  (if (is-leaf? node)
    (match-window node available)
    # Pool node
    (do
      (def restored-children @[])
      (each child (or (node :children) @[])
        (def restored (restore-node child available))
        (when restored
          (array/push restored-children restored)))
      # Build pool
      (def p @{:children restored-children})
      (each k pool-keys
        (when-let [v (node k)]
          (put p k v)))
      # Set parent pointers
      (each child restored-children
        (put child :parent p))
      p)))

(defn restore
  "Restore pool trees from saved data, matching windows by (app-id, title).
  Returns {:outputs [{:connector :pool} ...]}."
  [data windows]
  (def available (array ;windows))
  (def outputs
    (seq [saved-out :in (or (data :outputs) @[])]
      (def p (restore-node (saved-out :pool) available))
      @{:connector (saved-out :connector)
        :pool p}))
  # Append unmatched windows to the first output's first pool
  (when (and (> (length available) 0) (> (length outputs) 0))
    (def first-pool (get (get outputs 0) :pool))
    (when first-pool
      # Find a leaf-level pool to append to
      (var target first-pool)
      (while (and (target :children) (> (length (target :children)) 0))
        (def first-child (get (target :children) 0))
        (if (and (table? first-child) (first-child :children))
          (set target first-child)
          (break)))
      (each w available
        (array/push (target :children) w)
        (put w :parent target))))
  @{:outputs outputs})
