(defpackage #:utils
  (:use #:cl)
  (:export #:*default-worker-num*
           #:*default-keepalive-time*
           #:unwind-protect-unwind-only)
  #+:sbcl(:export #:peek-queue
                  #:queue-flush))

(defpackage #:cl-mzpool
  (:use #:cl #:utils)
  (:nicknames #:mpool)
  (:export #:*default-keepalive-time*
           #:thread-pool
           #:work-item
           #:make-thread-pool
           #:make-work-item
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
  (:use #:cl #:utils)
  (:nicknames #:mpool2)
  (:export #:*default-keepalive-time*
           #:*default-thread-pool*
           #:thread-pool
           #:work-item
           #:make-thread-pool
           #:make-work-item
           #:inspect-pool
           #:inspect-work
           #:thread-pool-peek-backlog
           #:thread-pool-add
           #:thread-pool-add-many
           #:add-work
           #:add-works
           #:get-result
           #:get-status
           #:thread-pool-cancel-item
           #:thread-pool-flush
           #:thread-pool-shutdown
           #:thread-pool-restart
           #:terminate-work))
