(defpackage #:cl-mzpool
  (:use #:cl)
  (:nicknames #:mpool)
  (:export #:*default-keepalive-time*
           #:thread-pool
           #:work-item
           #:make-thread-pool
           #:inspect-pool
           #:inspect-work
           #:thread-pool-peek-backlog
           #:thread-pool-add
           #:thread-pool-add-many
           #:thread-pool-cancel-item
           #:thread-pool-flush
           #:thread-pool-shutdown
           #:thread-pool-restart
           ;; Catch tag that can be used as a throw target to
           ;; leave the current task.
           #:terminate-work))

(defpackage #:cl-mzpool2
  (:use #:cl)
  (:nicknames #:mpool2)
  (:export #:*default-keepalive-time*
           #:thread-pool
           #:work-item
           #:make-thread-pool
           #:inspect-pool
           #:inspect-work
           #:thread-pool-peek-backlog
           #:thread-pool-add
           #:thread-pool-add-many
           #:thread-pool-cancel-item
           #:thread-pool-flush
           #:thread-pool-shutdown
           #:thread-pool-restart
           #:terminate-work))
