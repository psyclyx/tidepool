# Tests for tag reconciliation (see pipeline.janet:reconcile-tags).

(defn reconcile-tags [outputs focused tag-layouts]
  (when focused
    (for tag 1 10
      (when ((focused :tags) tag)
        (each o outputs
          (when (not= o focused)
            (put (o :tags) tag nil))))))

  (for tag 1 10
    (unless (find |(($ :tags) tag) outputs)
      (when-let [o (find |(empty? ($ :tags)) outputs)]
        (put (o :tags) tag true))))

  (each o outputs
    (def prev (o :primary-tag))
    (def curr (min-of (keys (o :tags))))
    (when (not= prev curr)
      (when prev
        (put tag-layouts prev
             @{:layout (o :layout)
               :params (table/clone (o :layout-params))}))
      (when-let [saved (get tag-layouts curr)]
        (put o :layout (saved :layout))
        (merge-into (o :layout-params) (saved :params)))
      (put o :primary-tag curr))))

(var test-count 0)
(var fail-count 0)

(defmacro test [name & body]
  ~(do
    (++ test-count)
    (try
      (do ,;body)
      ([err fib]
        (++ fail-count)
        (eprintf "FAIL: %s\n  %s" ,name (string err))
        (debug/stacktrace fib err "")))))

(defmacro assert= [a b &opt msg]
  ~(let [va ,a vb ,b]
     (unless (= va vb)
       (error (string (or ,msg "") " expected " (string/format "%q" vb)
                       " got " (string/format "%q" va))))))

(defn make-output [tags &opt layout layout-params primary-tag]
  @{:tags (table ;(mapcat |[$ true] tags))
    :layout (or layout :master-stack)
    :layout-params (or layout-params @{:main-ratio 0.55 :main-count 1})
    :primary-tag primary-tag})

# Uniqueness

(test "uniqueness: focused output steals tags from other outputs"
  (def o1 (make-output [1 2] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [3 4] :master-stack @{:main-ratio 0.55 :main-count 1} 3))
  (put o1 :tags @{3 true})
  (put o1 :primary-tag nil)
  (reconcile-tags [o1 o2] o1 @{})
  (assert ((o1 :tags) 3) "focused output has tag 3")
  (assert (nil? ((o2 :tags) 3)) "other output lost tag 3"))

(test "uniqueness: non-focused output keeps non-conflicting tags"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [2 3] :master-stack @{:main-ratio 0.55 :main-count 1} 2))
  (reconcile-tags [o1 o2] o1 @{})
  (assert ((o2 :tags) 2) "o2 keeps tag 2")
  (assert ((o2 :tags) 3) "o2 keeps tag 3"))

# Fallback

(test "fallback: empty output gets assigned an orphaned tag"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [2] :master-stack @{:main-ratio 0.55 :main-count 1} 2))
  (put (o1 :tags) 2 true)
  (reconcile-tags [o1 o2] o1 @{})
  (assert (not (empty? (o2 :tags))) "o2 has a fallback tag")
  (assert (nil? ((o2 :tags) 1)) "fallback is not tag 1 (owned by o1)")
  (assert (nil? ((o2 :tags) 2)) "fallback is not tag 2 (owned by o1)"))

(test "fallback: assigns lowest available orphan tag"
  (def o1 (make-output [1 2 3] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [] nil nil nil))
  (put o2 :tags @{})
  (put o2 :layout :master-stack)
  (put o2 :layout-params @{:main-ratio 0.55 :main-count 1})
  (reconcile-tags [o1 o2] o1 @{})
  (assert ((o2 :tags) 4) "empty output gets lowest orphan tag (4)"))

# Layout save/restore

(test "layout: primary-tag change saves old layout, restores new"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def tag-layouts @{2 @{:layout :tabbed :params @{:main-ratio 0.6 :main-count 2}}})
  (put o1 :tags @{2 true})
  (reconcile-tags [o1] o1 tag-layouts)
  (assert (get tag-layouts 1) "tag 1 layout saved")
  (assert= ((tag-layouts 1) :layout) :master-stack "saved layout is master-stack")
  (assert= (get-in tag-layouts [1 :params :main-ratio]) 0.55 "saved main-ratio")
  (assert= (o1 :layout) :tabbed "restored layout is monocle")
  (assert= (get-in o1 [:layout-params :main-ratio]) 0.6 "restored main-ratio")
  (assert= (get-in o1 [:layout-params :main-count]) 2 "restored main-count")
  (assert= (o1 :primary-tag) 2 "primary-tag updated"))

(test "layout: no saved layout for new tag keeps current"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def tag-layouts @{})
  (put o1 :tags @{3 true})
  (reconcile-tags [o1] o1 tag-layouts)
  (assert (get tag-layouts 1) "tag 1 layout saved")
  (assert= (o1 :layout) :master-stack "layout unchanged")
  (assert= (o1 :primary-tag) 3 "primary-tag updated"))

# Scratchpad

(test "scratchpad: tag 0 not subject to uniqueness"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [2] :master-stack @{:main-ratio 0.55 :main-count 1} 2))
  (put (o1 :tags) 0 true)
  (put (o2 :tags) 0 true)
  (reconcile-tags [o1 o2] o1 @{})
  (assert ((o1 :tags) 0) "o1 keeps scratchpad")
  (assert ((o2 :tags) 0) "o2 keeps scratchpad"))

# Idempotence

(test "idempotence: second reconcile is a no-op"
  (def o1 (make-output [1 2] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [3 4] :tabbed @{:main-ratio 0.6 :main-count 2} 3))
  (def tag-layouts @{})
  (reconcile-tags [o1 o2] o1 tag-layouts)
  (def o1-tags (table/clone (o1 :tags)))
  (def o2-tags (table/clone (o2 :tags)))
  (def o1-layout (o1 :layout))
  (def o2-layout (o2 :layout))
  (def o1-primary (o1 :primary-tag))
  (def o2-primary (o2 :primary-tag))
  (reconcile-tags [o1 o2] o1 tag-layouts)
  (assert (deep= (o1 :tags) o1-tags) "o1 tags unchanged")
  (assert (deep= (o2 :tags) o2-tags) "o2 tags unchanged")
  (assert= (o1 :layout) o1-layout "o1 layout unchanged")
  (assert= (o2 :layout) o2-layout "o2 layout unchanged")
  (assert= (o1 :primary-tag) o1-primary "o1 primary-tag unchanged")
  (assert= (o2 :primary-tag) o2-primary "o2 primary-tag unchanged"))

# Single monitor

(test "single monitor: tag switch restores per-tag layout"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def tag-layouts @{1 @{:layout :master-stack :params @{:main-ratio 0.55 :main-count 1}}
                     2 @{:layout :tabbed :params @{:main-ratio 0.6 :main-count 2}}})
  (put o1 :tags @{2 true})
  (reconcile-tags [o1] o1 tag-layouts)
  (assert= (o1 :layout) :tabbed "layout restored for tag 2")
  (assert= (o1 :primary-tag) 2 "primary-tag is 2")
  (put o1 :tags @{1 true})
  (reconcile-tags [o1] o1 tag-layouts)
  (assert= (o1 :layout) :master-stack "layout restored for tag 1")
  (assert= (o1 :primary-tag) 1 "primary-tag is 1"))

(test "single monitor: focus-all-tags sets primary-tag to lowest"
  (def o1 (make-output [3] :tabbed @{:main-ratio 0.6 :main-count 2} 3))
  (put o1 :tags (table ;(mapcat |[$ true] (range 1 10))))
  (reconcile-tags [o1] o1 @{})
  (assert= (o1 :primary-tag) 1 "primary-tag is lowest (1)"))

# Multi monitor

(test "multi monitor: focused steals tag, other gets fallback"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [2] :tabbed @{:main-ratio 0.6 :main-count 2} 2))
  (put o1 :tags @{2 true})
  (reconcile-tags [o1 o2] o1 @{})
  (assert ((o1 :tags) 2) "o1 has tag 2")
  (assert (nil? ((o2 :tags) 2)) "o2 lost tag 2")
  (assert (not (empty? (o2 :tags))) "o2 has fallback tag")
  (each tag (keys (o2 :tags))
    (assert (nil? ((o1 :tags) tag))
      (string "o2 fallback tag " tag " doesn't conflict with o1"))))

(test "multi monitor: three outputs, focused steals two tags"
  (def o1 (make-output [1] :master-stack @{:main-ratio 0.55 :main-count 1} 1))
  (def o2 (make-output [2] :master-stack @{:main-ratio 0.55 :main-count 1} 2))
  (def o3 (make-output [3] :master-stack @{:main-ratio 0.55 :main-count 1} 3))
  (put o1 :tags @{2 true 3 true})
  (reconcile-tags [o1 o2 o3] o1 @{})
  (assert ((o1 :tags) 2) "o1 has tag 2")
  (assert ((o1 :tags) 3) "o1 has tag 3")
  (assert (not (empty? (o2 :tags))) "o2 has fallback")
  (assert (not (empty? (o3 :tags))) "o3 has fallback")
  (each tag (keys (o2 :tags))
    (assert (nil? ((o1 :tags) tag)) (string "o2 tag " tag " not on o1"))
    (assert (nil? ((o3 :tags) tag)) (string "o2 tag " tag " not on o3")))
  (each tag (keys (o3 :tags))
    (assert (nil? ((o1 :tags) tag)) (string "o3 tag " tag " not on o1"))
    (assert (nil? ((o2 :tags) tag)) (string "o3 tag " tag " not on o2"))))

(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
