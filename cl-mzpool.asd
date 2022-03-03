(defsystem "cl-mzpool"
  :version "0.2.0"
  :description "A thread pool ported from Mezzano OS."
  :author "He Xiang-zhi"
  :license "MIT"
  :depends-on (:cl-cpus
               :bordeaux-threads
               :alexandria)
  :serial t
  :components ((:file "thread-pool")
               #+sbcl (:file "thread-pool2")))
