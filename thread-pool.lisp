;;;; The related lisp files in Mezzano are:
;;;; Mezzano/system/thread-pool.lisp
;;;; Mezzano/system/basic-macros.lisp
;;;; Mezzano/system/sync.lisp
;;;; Mezzano/supervisor/sync.lisp

(defpackage #:cl-mzpool
  (:use #:cl)
  (:nicknames #:mzpool)
  (:export #:*default-keepalive-time*
           #:thread-pool
           #:work-item
           #:make-thread-pool
           #:inspect-pool
           #:inspect-work
           #:thread-pool-peek-pending
           #:thread-pool-add
           #:thread-pool-add-many
           #:thread-pool-cancel-item
           #:thread-pool-flush
           #:thread-pool-shutdown
           #:thread-pool-restart
           ;; Catch tag that can be used as a throw target to
           ;; leave the current task.
           #:terminate-work))


(in-package :cl-mzpool)

(defvar *worker-num* (max 4 (cpus:get-number-of-processors)))

(defparameter *default-keepalive-time* 60
  "Default value for the idle worker thread keepalive time. Note that it's cpu time, not real time.")

;; Mezzano/system/basic-macros.lisp
(defmacro unwind-protect-unwind-only (protected-form &body cleanup-forms)
  "Like UNWIND-PROTECT, but CLEANUP-FORMS are not executed if a normal return occurs."
  (let ((abnormal-return (gensym "ABNORMAL-RETURN")))
    `(let ((,abnormal-return t))
       (unwind-protect
            (multiple-value-prog1
                ,protected-form
              (setf ,abnormal-return nil))
         (when ,abnormal-return
           ,@cleanup-forms)))))

;; Mezzano/system/thread-pool.lisp
(defclass thread-pool ()
  ((%name             :initarg :name :type string :initform "Thread Pool" :reader thread-pool-name)
   (%initial-bindings :initarg :initial-bindings :reader thread-pool-initial-bindings)
   (%lock :reader thread-pool-lock)
   (%cvar :reader thread-pool-cvar)
   (%pending           :initform '() :accessor thread-pool-pending)
   (%working-threads   :initform '() :accessor thread-pool-working-threads)
   (%idle-threads      :initform '() :accessor thread-pool-idle-threads)
   (%n-total-threads   :initform 0   :accessor thread-pool-n-total-threads)
   (%n-blocked-threads :initform 0   :accessor thread-pool-n-blocked-threads)
   (%shutdown          :initform nil :accessor thread-pool-shutdown-p)
   (%keepalive-time :initarg :keepalive-time :accessor thread-pool-keepalive-time))
  (:default-initargs :name nil :initial-bindings '()))

(defmethod initialize-instance :after ((instance thread-pool) &key)
  (setf (slot-value instance '%lock) (bt:make-lock (thread-pool-name instance))
        (slot-value instance '%cvar) (bt:make-condition-variable :name (thread-pool-name instance))))

(defun inspect-pool (pool &optional (inspect-work-p nil))
  (format nil "name: ~d, pending works: ~d, total threads: ~d, working threads: ~d, idle threads: ~d, blocked threads: ~d, shutdownp: ~d~@[, pending works: ~%~{~d~^~&~}~]"
          (thread-pool-name pool)
          (length (thread-pool-pending pool))
          (thread-pool-n-total-threads pool)
          (length (thread-pool-working-threads pool))
          (length (thread-pool-idle-threads pool))
          (thread-pool-n-blocked-threads pool)
          (thread-pool-shutdown-p pool)
          (when inspect-work-p
            (mapcar #'(lambda(work) (inspect-work work t))
                    (thread-pool-pending pool)))))

(defmethod print-object ((pool thread-pool) stream)
  (print-unreadable-object (pool stream :type t)
    (format stream (inspect-pool pool))))

(defclass work-item ()
  ((%name        :initarg :name        :reader work-item-name)
   (%function    :initarg :function    :reader work-item-function)
   (%thread-pool :initarg :thread-pool :reader work-item-thread-pool)
   (%desc        :initarg :desc        :reader work-item-desc)))

(defun inspect-work (work &optional (simple-mode nil))
  (format nil (format nil "name: ~d, desc: ~d~@[, pool: ~d~]"
                      (work-item-name work)
                      (work-item-desc work)
                      (unless simple-mode
                        (thread-pool-name (work-item-thread-pool work))))))

(defmethod print-object ((work work-item) stream)
  (print-unreadable-object (work stream :type t)
    (format stream (inspect-work work))))

(defun thread-pool-peek-pending (pool)
  "Return the top pending work of the pool."
  (first (thread-pool-pending pool)))

(defun make-thread-pool (&key name initial-bindings (keepalive-time *default-keepalive-time*))
  "Create a new thread-pool."
  (check-type keepalive-time (integer 0)) ; if set to 0, the thread will be terminated after finishing a work
  (make-instance 'thread-pool
                 :name name
                 :initial-bindings initial-bindings
                 :keepalive-time keepalive-time))

(defun thread-pool-n-concurrent-threads (thread-pool)
  "Return the number of threads in the pool are not blocked."
  (- (thread-pool-n-total-threads thread-pool)
     (thread-pool-n-blocked-threads thread-pool)))

(defun thread-pool-main (thread-pool)
  (let* ((self (bt:current-thread)))
    (loop  ; an infinite loop to let a thread ready to pick up a work item
     (let ((work nil))
       (bt:with-lock-held ((thread-pool-lock thread-pool))
         ;; Move current thread from working to idle.
         (setf (thread-pool-working-threads thread-pool)
               (remove self (thread-pool-working-threads thread-pool)))
         (push self (thread-pool-idle-threads thread-pool))
         ;;(setf (third thread-name) nil) ; the thread name in Mezzano can be a list.
         #+sbcl (setf (sb-thread:thread-name self) "Thread pool idle worker")
         (let ((start-idle-time (get-internal-run-time)))
           (flet ((exit-while-idle ()     ; return-from thread-pool-main, so that the thread will be returned
                    (setf (thread-pool-idle-threads thread-pool)
                          (remove self (thread-pool-idle-threads thread-pool)))
                    (decf (thread-pool-n-total-threads thread-pool))
                    (return-from thread-pool-main)))
             (loop                                                      ; pick up a work item in an infinite loop
                   (when (thread-pool-shutdown-p thread-pool)
                     (exit-while-idle))
                   (when (not (endp (thread-pool-pending thread-pool))) ; pick up a work-item from the pending queue
                     (setf work (pop (thread-pool-pending thread-pool)))
                     ;;(setf (third thread-name) work)
                     #+sbcl (setf (sb-thread:thread-name self)
                                  (concatenate 'string "Thread pool worker: " (work-item-name work)))
                     ;; Back to active from idle.
                     (setf (thread-pool-idle-threads thread-pool)
                           (remove self (thread-pool-idle-threads thread-pool)))
                     (push self (thread-pool-working-threads thread-pool))
                     (return))
                   ;; If there is no work available and there are more
                   ;; unblocked threads than cores, then terminate this thread.
                   (when (> (thread-pool-n-concurrent-threads thread-pool) *worker-num*)
                     (exit-while-idle))
                   (let* ((end-idle-time (+ start-idle-time
                                            (* (thread-pool-keepalive-time thread-pool) internal-time-units-per-second)))
                          (idle-time-remaining (- end-idle-time (get-internal-run-time))))
                     (when (minusp idle-time-remaining) ; exit when idle time exceeds the limit
                       (exit-while-idle))
                     (bt:condition-wait (thread-pool-cvar thread-pool)
                                        (thread-pool-lock thread-pool)
                                        :timeout (/ idle-time-remaining internal-time-units-per-second)))))))
       ;;(setf (sup:thread-thread-pool self) thread-pool) ; not portable
       (unwind-protect-unwind-only
        (catch 'terminate-work
          (funcall (work-item-function work)))                      ; deal with the work
        ;; Getting here means an unwind occured in the work item and
        ;; this thread is terminating in the active state. Clean up.
        (setf (thread-pool-working-threads thread-pool)
              (remove self (thread-pool-working-threads thread-pool)))
        (decf (thread-pool-n-total-threads thread-pool)))
       ;;(setf (sup:thread-thread-pool self) nil) ; not portable
       ))))

(defun thread-pool-add (function thread-pool &key name priority bindings desc)
  "Add a work item to the thread-pool.
Functions are called concurrently and in FIFO order.
A work item is returned, which can be passed to THREAD-POOL-CANCEL-ITEM
to attempt cancel the work.
BINDINGS is a list which specify special bindings
that should be active when FUNCTION is called. These override the
thread pool's initial-bindings.
NOTE that in Mezzano, bindings is a list of (SYMBOL VALUE) pairs,
but in bordeaux-thread, bindings is a list of (SYMBOL . FORM) cons,
so in this ported lib, bindings should be an alist of (SYMBOL . VALUE) such as '((k1 . v1) (k2 . v2))"
  (declare (ignore priority)) ; TODO
  (check-type function function)
  (let ((work (make-instance 'work-item ;
                             :function (if bindings
                                           ;;(let ((vars (mapcar #'first bindings))
                                           ;;      (vals (mapcar #'second bindings)))
                                           (let ((vars (mapcar #'car bindings))
                                                 (vals (mapcar #'cdr bindings)))
                                             (lambda ()
                                               (progv vars vals
                                                 (funcall function))))
                                           function)
                             :name name
                             :thread-pool thread-pool
                             :desc desc)))
    ;;(sup:with-mutex ((thread-pool-lock thread-pool) :resignal-errors t)
    (bt:with-lock-held ((thread-pool-lock thread-pool))
      (when (thread-pool-shutdown-p thread-pool)
        (error "Attempted to add work item to shut down thread pool ~S" thread-pool))
      (setf (thread-pool-pending thread-pool) (append (thread-pool-pending thread-pool) (list work))) ; add new work to pending
      (when (and (endp (thread-pool-idle-threads thread-pool))
                 (< (thread-pool-n-concurrent-threads thread-pool)
                    *worker-num*))
        ;; There are no idle threads and there are more logical cores than
        ;; currently running threads. Create a new thread for this work item.
        ;; Push it on the active list to make the logic in T-P-MAIN work out.
        (push (bt:make-thread (lambda () (thread-pool-main thread-pool))      ; create a new worker thread
                              ;;:name `(thread-pool-worker ,thread-pool nil)  ; list type of name was not applicable in sbcl
                              :name "Idle Worker"
                              :initial-bindings (thread-pool-initial-bindings thread-pool))
              (thread-pool-working-threads thread-pool))
        (incf (thread-pool-n-total-threads thread-pool)))
      (bt:condition-notify (thread-pool-cvar thread-pool)))
    work))

(defun thread-pool-add-many (function values thread-pool &key name priority bindings)
  "Add many work items to the pool.
A work item is created for each element of VALUES and FUNCTION is called
in the pool with that element.
Returns a list of the work items added."
  ;; like parallel map but return a list of work objects
  (loop
    for value in values
    collect (thread-pool-add
             (let ((value value))
               (lambda () (funcall function value)))
             thread-pool
             :name name
             :priority priority
             :bindings bindings)))

(defun thread-pool-cancel-item (item)
  "Cancel a work item, removing it from its thread-pool.
Returns true if the item was successfully cancelled,
false if the item had finished or is currently running on a worker thread."
  (let ((thread-pool (work-item-thread-pool item)))
    (bt:with-lock-held ((thread-pool-lock thread-pool))
      (cond ((find item (thread-pool-pending thread-pool))
             (setf (thread-pool-pending thread-pool) (remove item (thread-pool-pending thread-pool)))
             t)
            (t
             nil)))))

(defun thread-pool-flush (thread-pool)
  "Cancel all outstanding work on THREAD-POOL.
Returns a list of all cancelled items.
Does not cancel work in progress."
  (bt:with-lock-held ((thread-pool-lock thread-pool))
    (prog1
        (thread-pool-pending thread-pool)
      (setf (thread-pool-pending thread-pool) '()))))

(defun thread-pool-shutdown (thread-pool &key abort)
  "Shutdown THREAD-POOL.
This cancels all outstanding work on THREAD-POOL
and notifies the worker threads that they should
exit once their active work is complete.
Once a thread pool has been shut down, no further work
can be added.
If ABORT is true then worker threads will be terminated
via TERMINATE-THREAD."
  (bt:with-lock-held ((thread-pool-lock thread-pool))
    (setf (thread-pool-shutdown-p thread-pool) t)
    (setf (thread-pool-pending thread-pool) '())
    (when abort
      (dolist (thread (thread-pool-working-threads thread-pool))
        (bt:destroy-thread thread))
      (dolist (thread (thread-pool-idle-threads thread-pool))
        (bt:destroy-thread thread)))
    (bt:condition-notify (thread-pool-cvar thread-pool)))
  (values))

(defun thread-pool-restart (thread-pool)
  "Calling thread-pool-shutdown will not destroy the pool object, but set the slot %shutdown t.
This function set the slot %shutdown nil so that the pool will be used then.
Return t if the pool has been shutdown, and return nil if the pool was active"
  (bt:with-lock-held ((thread-pool-lock thread-pool))
    (if (thread-pool-shutdown-p thread-pool)
        (progn (setf (thread-pool-shutdown-p thread-pool) nil)
               t)
        nil)))


;;;; thread pool blocking

;;; Thread pool support for hijacking blocking functions.
;;; When the current thread's thread-pool slot is non-nil, the blocking
;;; functions will call THREAD-POOL-BLOCK with the thread pool, the name
;;; of the function and supplied arguments instead of actually blocking.
;;; The thread's thread-pool slot will be set to NIL for the duration
;;; of the call to THREAD-POOL-BLOCK.

;; Mezzano/system/sync.lisp
(defgeneric thread-pool-block (thread-pool blocking-function &rest arguments)
  (:documentation "Called when the current thread's thread-pool slot
is non-NIL and the thread is about to block. The thread-pool slot
is bound to NIL for the duration of the call."))

(defmethod thread-pool-block ((thread-pool thread-pool) blocking-function &rest arguments)
  (declare (dynamic-extent arguments))
  (when (and (eql blocking-function 'bt:acquire-lock)
             (eql (first arguments) (thread-pool-lock thread-pool)))
    ;; Don't suspend when acquiring the thread-pool lock, this causes
    ;; recursive locking on it.
    (return-from thread-pool-block
      (apply blocking-function arguments)))
  (unwind-protect
       (progn
         (bt:with-lock-held ((thread-pool-lock thread-pool))
           (incf (thread-pool-n-blocked-threads thread-pool)))
         (apply blocking-function arguments))
    (bt:with-lock-held ((thread-pool-lock thread-pool))
      (decf (thread-pool-n-blocked-threads thread-pool)))))

;;;; Mezzano/supervisor/sync.lisp
(defmacro thread-pool-blocking-hijack (function-name &rest arguments)
  (let ((self (gensym "SELF"))
        (pool (gensym "POOL")))
    `(let* ((,self (current-thread))
            (,pool (thread-thread-pool ,self)))
       (when ,pool
         (unwind-protect
              (progn
                (setf (thread-thread-pool ,self) nil) ; make sure it will not been call repeatly
                (return-from ,function-name
                  (thread-pool-block ,pool ',function-name ,@arguments)))
           (setf (thread-thread-pool ,self) ,pool))))))

(defmacro thread-pool-blocking-hijack-apply (function-name &rest arguments)
  ;; used when all the parameters are enclosed in a list
  (let ((self (gensym "SELF"))
        (pool (gensym "POOL")))
    `(let* ((,self (current-thread))
            (,pool (thread-thread-pool ,self)))
       (when ,pool
         (unwind-protect
              (progn
                (setf (thread-thread-pool ,self) nil)
                (return-from ,function-name
                  (apply #'thread-pool-block ,pool ',function-name ,@arguments)))
           (setf (thread-thread-pool ,self) ,pool))))))

(defmacro inhibit-thread-pool-blocking-hijack (&body body)
  "Run body with the thread's thread-pool unset."
  (let ((self (gensym "SELF"))
        (pool (gensym "POOL")))
    `(let* ((,self (current-thread))
            (,pool (thread-thread-pool ,self)))
       (unwind-protect
            (progn
              (setf (thread-thread-pool ,self) nil)
              ,@body)
         (setf (thread-thread-pool ,self) ,pool)))))
