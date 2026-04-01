# Test helper — assertions and mock factories.

# Add src/ to module search path so tests can import source modules.
(array/insert module/paths 0 ["../src/:all:.janet" :source])
(array/insert module/paths 0 ["../src/:all:/init.janet" :source])


(var- pass-count 0)
(var- fail-count 0)
(var- current-test "")

(defn test-start [name]
  (set current-test name))

(defn assert-eq [actual expected &opt msg]
  (if (deep= actual expected)
    (++ pass-count)
    (do
      (++ fail-count)
      (eprintf "  FAIL [%s] %s\n    expected: %q\n    got:      %q"
               current-test (or msg "") expected actual))))

(defn assert-is [actual expected &opt msg]
  (if (= actual expected)
    (++ pass-count)
    (do
      (++ fail-count)
      (eprintf "  FAIL [%s] %s\n    expected: %q\n    got:      %q"
               current-test (or msg "") expected actual))))

(defn assert-truthy [val &opt msg]
  (if val
    (++ pass-count)
    (do
      (++ fail-count)
      (eprintf "  FAIL [%s] %s — expected truthy, got %q"
               current-test (or msg "") val))))

(defn assert-falsey [val &opt msg]
  (if (not val)
    (++ pass-count)
    (do
      (++ fail-count)
      (eprintf "  FAIL [%s] %s — expected falsey, got %q"
               current-test (or msg "") val))))

(defn report []
  (printf "%d passed, %d failed" pass-count fail-count)
  (if (> fail-count 0) (os/exit 1) (os/exit 0)))

# --- Mock factories ---

(defn make-config [&opt overrides]
  (def c @{:border-width 4
            :outer-padding 4
            :inner-padding 8
            :outer-gap 4
            :inner-gap 8
            :peek-width 8
            :default-column-width 1.0
            :width-presets @[0.33 0.5 0.66 0.8 1.0]
            :main-ratio 0.55
            :main-count 1
            :default-layout :master-stack
            :column-width 0.5
            :dwindle-ratio 0.5
            :border-focused 0xffffff
            :border-normal 0x646464
            :border-urgent 0xff0000
            :border-insert 0x00ff88
            :xkb-bindings @[]
            :pointer-bindings @[]
            :rules @[]
            :output-order @[]})
  (when overrides (merge-into c overrides))
  c)

(defn make-output [&opt overrides]
  (def o @{:x 0 :y 0 :w 1920 :h 1080
            :tags @{1 true}
            :new nil
            :removed nil
            :pending-destroy nil
            :layout :master-stack
            :layout-params @{:main-ratio 0.55 :main-count 1
                             :scroll-offset 0 :column-width 0.5
                             :dwindle-ratio 0.5}})
  (when overrides (merge-into o overrides))
  o)

(defn make-window [wid &opt overrides]
  (def w @{:wid wid :tag 1 :float false :closed false
            :closing false :pending-destroy nil
            :layout-hidden nil :visible nil
            :x nil :y nil :w nil :h nil
            :proposed-w nil :proposed-h nil
            :min-w 0 :max-w 0 :min-h 0 :max-h 0
            :border-rgb nil :border-width nil
            :border-applied-rgb nil :border-applied-width nil
            :app-id nil :title nil :decoration-hint nil
            :float-changed nil :needs-ssd nil :new nil})
  (when overrides (merge-into w overrides))
  w)

(defn make-seat [&opt overrides]
  (def s @{:focused nil :focused-output nil
            :focus-prev nil :focus-changed nil
            :focus-output-changed nil
            :xkb-bindings @[]
            :pending-actions @[]
            :window-interaction nil
            :pointer-moved nil
            :new nil :removed nil :pending-destroy nil})
  (when overrides (merge-into s overrides))
  s)

(defn make-ctx [&opt overrides]
  (def ctx @{:config (make-config)
              :outputs @[]
              :windows @[]
              :seats @[]
              :render-order @[]
              :tag-layouts @{}
              :tag-focus @{}
              :tags @{}})
  (when overrides (merge-into ctx overrides))
  ctx)
