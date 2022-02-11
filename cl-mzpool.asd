(defsystem "cl-mzpool"
  :version "0.1.0"
  :description "A thread pool ported from Mezzano OS."
  :author "He Xiang-zhi"
  :license "MIT"
  :depends-on (:cl-cpus
               :bordeaux-threads)
  :serial t
  :components ((:file "thread-pool")))
