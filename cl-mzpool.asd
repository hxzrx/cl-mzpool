(defsystem "cl-mzpool"
  :version "0.2.0"
  :description "A thread pool ported from Mezzano OS."
  :author "He Xiang-zhi"
  :license "MIT"
  :depends-on (:cl-cpus
               :bordeaux-threads
               :alexandria)
  :serial t
  :in-order-to ((test-op (test-op "cl-mzpool/tests")))
  :components ((:file "packages")
               (:file "utils")
               (:file "thread-pool")
               #+sbcl (:file "thread-pool2")))

(defsystem "cl-mzpool/tests"
  :version "0.2.0"
  :author "He Xiang-zhi"
  :license "MIT"
  :serial t
  :depends-on (:cl-mzpool
               :parachute)
  :components ((:file "tests"))
  :perform (test-op (o s) (uiop:symbol-call :parachute :test :cl-mzpool-tests)))
