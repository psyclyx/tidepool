# Regression tests for pipeline bugs.

(import ../src/state)

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

# --- remove-destroyed regression ---

(def remove-destroyed state/remove-destroyed)

(test "remove-destroyed: removes flagged elements in place"
  (def arr @[@{:name "a"} @{:name "b" :pending-destroy true} @{:name "c"}])
  (def original-id (describe arr))
  (remove-destroyed arr)
  (assert= (length arr) 2)
  (assert= ((arr 0) :name) "a")
  (assert= ((arr 1) :name) "c")
  (assert= (describe arr) original-id "should modify array in place"))

(test "remove-destroyed: handles empty array"
  (def arr @[])
  (remove-destroyed arr)
  (assert= (length arr) 0))

(test "remove-destroyed: handles all destroyed"
  (def arr @[@{:pending-destroy true} @{:pending-destroy true}])
  (remove-destroyed arr)
  (assert= (length arr) 0))

(test "remove-destroyed: handles none destroyed"
  (def arr @[@{:name "a"} @{:name "b"}])
  (remove-destroyed arr)
  (assert= (length arr) 2))

(test "remove-destroyed: consecutive destroyed elements"
  (def arr @[@{:name "a"} @{:pending-destroy true} @{:pending-destroy true} @{:name "d"}])
  (remove-destroyed arr)
  (assert= (length arr) 2)
  (assert= ((arr 0) :name) "a")
  (assert= ((arr 1) :name) "d"))

(test "remove-destroyed: local reference sees updated array"
  (def state @{:windows @[@{:name "w1"} @{:name "w2" :pending-destroy true} @{:name "w3"}]})
  (def windows (state :windows))
  (remove-destroyed (state :windows))
  (assert= (length windows) 2 "local ref updated")
  (assert= ((windows 0) :name) "w1")
  (assert= ((windows 1) :name) "w3"))


(printf "\n%d tests, %d failures" test-count fail-count)
(when (> fail-count 0) (os/exit 1))
