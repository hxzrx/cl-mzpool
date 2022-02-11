(in-package :cl-mzpool)

(defparameter %pool (make-thread-pool :name "A thread pool"
                                      :initial-bindings '((a . 1) (b . 2)) ; This should be an alist
                                      :keepalive-time 0)) ; set to 0, so that the thread will return after finishing a work

(defun %print-num-ins (n)
  (print n)
  (force-output))

(defun %print-num-lmt (n)
  (dotimes (i 6)
    (print n)
    (force-output)
    (sleep 5)))

(defun %print-num-inf (n)
  (loop (print n)
        (force-output)
        (sleep 5)))

(defun %add-ins-work (&optional (n 0))
  (thread-pool-add #'(lambda () (%print-num-ins n))
                   %pool
                   :name (concatenate 'string "ins-work-" (write-to-string n))))

(defun %add-lmt-work (&optional (n 0))
  "Add a work to the pool, this work will print a number every 5 seconds."
  (thread-pool-add #'(lambda () (%print-num-lmt n))
                   %pool
                   :name (concatenate 'string "lmt-work-" (write-to-string n))
                   :desc (concatenate 'string "limited printing " (write-to-string n))))

(defun %add-inf-work (&optional (n 0))
  "Add a work to the pool, this work will print a number every 5 seconds."
  (thread-pool-add #'(lambda () (%print-num-inf n))
                   %pool
                   :name (concatenate 'string "inf-work-" (write-to-string n))
                   :desc (concatenate 'string "endlessly printing " (write-to-string n))))

(defun %add-lmt-works (&optional (n 5))
  "Add n works to the pool"
  (dotimes (i n)
    (thread-pool-add #'(lambda () (%print-num-lmt i))
                     %pool
                     :name (concatenate 'string "lmt-work-" (write-to-string i))
                     :desc (concatenate 'string "limited printing " (write-to-string i)))
    (sleep 0.1)))

(defun %add-inf-works (&optional (n 5))
  "Add n works to the pool"
  (dotimes (i n)
    (thread-pool-add #'(lambda () (%print-num-inf i))
                     %pool
                     :name (concatenate 'string "inf-work-" (write-to-string i))
                     :desc (concatenate 'string "endlessly printing " (write-to-string i)))
    (sleep 0.1)))

(defun %add-parallel-works (&optional (n 100))
  (thread-pool-add-many #'%add-ins-work
                        (loop for i below n collect i)
                        %pool))

(defun %cancel-work ()
  (let* ((pending-works (thread-pool-pending %pool))
         (work (first pending-works)))
  (thread-pool-cancel-item work)))

(defun %clear-pending ()
  (thread-pool-flush %pool))

(defun %shutdown-pool ()
  (thread-pool-shutdown %pool :abort t))

(defun %restart-pool ()
  (thread-pool-restart %pool))


;; (inspect-pool %pool)

;; add a work to the pool
;; (%add-ins-work)
;; (inspect-pool %pool)

;; add 10 works which will return shortly
;; (%add-lmt-works 10)
;; (inspect-pool %pool)
;; (inspect-pool %pool t)

;; add 10 works which will not return
;; (%add-inf-works 10)
;; (inspect-pool %pool)
;; (inspect-pool %pool t)
;; (thread-pool-peek-pending %pool)

;; simulate parallel call with thread-pool-add-many
;; (%add-parallel-works)

;; calcel the pending work in the top
;; (%cancel-work)
;; (inspect-pool %pool)

;; shutdown the pool and terminate the inf threads, then restart the pool
;; (%shutdown-pool)
;; (%restart-pool)
;; (inspect-pool %pool)

;; (%add-inf-works 10)
;; (%clear-pending)
