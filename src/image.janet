(import image-native :prefix "" :export true)

(def- WL_SHM_FORMAT_XRGB8888 :xrgb8888)

(def- buffer-cache
  "Cache of path → {:buffer wl_buffer :width int :height int}"
  @{})

(defn create-buffer [path registry]
  "Decode image at path and create a wl_shm buffer.
   Returns {:buffer <proxy> :width <int> :height <int>}.
   Caches result — repeated calls with the same path return the same buffer."
  (if-let [cached (get buffer-cache path)]
    cached
    (do
      (def img (load path))
      (def pool (:create-pool (registry "wl_shm")
                              (img :fd) (img :size)))
      (def buffer (:create-buffer pool 0
                                  (img :width) (img :height)
                                  (img :stride) WL_SHM_FORMAT_XRGB8888))
      (:destroy pool)
      (close-fd (img :fd))
      (def result {:buffer buffer :width (img :width) :height (img :height)})
      (put buffer-cache path result)
      result)))
