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
  "Serialize outputs' tag pools to a pretty-printed JDN string."
  [outputs]
  (def data
    @{:outputs
      (seq [o :in outputs]
        (def tp-data @{})
        (eachp [id tp] (o :tag-pools)
          (put tp-data id (serialize-node tp)))
        @{:connector (o :connector)
          :active-tag (o :active-tag)
          :tag-pools tp-data})})
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
  "Restore tag pools from saved data, matching windows by (app-id, title).
  Returns {:outputs [{:connector :tag-pools :active-tag} ...]}."
  [data windows]
  (def available (array ;windows))
  (def outputs
    (seq [saved-out :in (or (data :outputs) @[])]
      (def tag-pools @{})
      (if (saved-out :tag-pools)
        # New format: tag-pools table
        (eachp [id saved-tp] (saved-out :tag-pools)
          (def p (restore-node saved-tp available))
          (when p (put tag-pools id p)))
        # Legacy format: single root pool with tag children
        (when-let [root-data (saved-out :pool)]
          (def root (restore-node root-data available))
          (when root
            (for i 0 (length (root :children))
              (def child (get (root :children) i))
              (put child :parent nil)
              (put tag-pools (or (child :id) i) child)))))
      @{:connector (saved-out :connector)
        :tag-pools tag-pools
        :active-tag (or (saved-out :active-tag) 1)}))
  # Append unmatched windows to the first output's active tag pool
  (when (and (> (length available) 0) (> (length outputs) 0))
    (def first-out (get outputs 0))
    (def active (or (first-out :active-tag) 1))
    (when-let [tp (or (get (first-out :tag-pools) active)
                      # Fallback: first available tag pool
                      (do (var found nil)
                        (eachp [_ p] (first-out :tag-pools)
                          (when (not found) (set found p)))
                        found))]
      # Find a leaf-level pool to append to
      (var target tp)
      (while (and (target :children) (> (length (target :children)) 0))
        (def first-child (get (target :children) 0))
        (if (and (table? first-child) (first-child :children))
          (set target first-child)
          (break)))
      (each w available
        (array/push (target :children) w)
        (put w :parent target))))
  @{:outputs outputs})
