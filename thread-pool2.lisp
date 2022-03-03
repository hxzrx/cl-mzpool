;;;; Experimentally implemente mzpool with atomic operations in the pool worker threads' infinite loop.


(in-package :cl-mzpool2)

(defvar *worker-num* (max 4 (cpus:get-number-of-processors)))

(defparameter *default-keepalive-time* (the (unsigned-byte 64) 60) ; 那些无限循环的大型任务不能放到线程池
  "Default value for the idle worker thread keepalive time. Note that it's cpu time, not real time.")

(defun peek-queue (queue)
  (cadr (sb-concurrency::queue-head queue)))

(defun queue-flush (queue)
  "Flush the queue to an empty queue."
  (declare (optimize speed))
  (loop (let* ((head (sb-concurrency::queue-head queue))
               (tail (sb-concurrency::queue-tail queue))
               (next (cdr head)))
          (typecase next
            (null (return nil))
            (cons (when (and (eq head (sb-ext:compare-and-swap (sb-concurrency::queue-head queue)
                                                               head head))
                             (eq nil (sb-ext:compare-and-swap (cdr (sb-concurrency::queue-tail queue))
                                                              nil nil)))
                    (setf (car tail) sb-concurrency::+dummy+
                          (sb-concurrency::queue-head queue) (sb-concurrency::queue-tail queue))
                    (return t)))))))

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


(defstruct (thread-pool (:constructor make-thread-pool (&key name initial-bindings keepalive-time))
                        (:copier nil)
                        (:predicate thread-pool-p))
  (name              (concatenate 'string "THREAD-POOL-" (string (gensym))) :type string)
  (initial-bindings  nil            :type list)
  (lock              (bt:make-lock "THREAD-POOL-LOCK"))
  (cvar              (bt:make-condition-variable :name "THREAD-POOL-CVAR"))
  (backlog          (sb-concurrency:make-queue :name "THREAD POOL PENDING WORK-ITEM QUEUE"))
  (thread-list       nil            :type list)               ; 线程对象列表
  (working-threads   0              :type (unsigned-byte 64)) ; 正在工作的线程数量
  (idle-threads      0              :type (unsigned-byte 64)) ; 闲置线程数量
  (n-total-threads   0              :type (unsigned-byte 64)) ; 总线程数量
  (n-blocked-threads 0              :type (unsigned-byte 64)) ; 被阻塞线程数量
  (shutdown-p        nil)
  (keepalive-time    *default-keepalive-time* :type (unsigned-byte 64)))

(defun inspect-pool (pool &optional (inspect-work-p nil))
  "返回线程池状态文本"
  (format nil "name: ~d, backlog of work: ~d, total threads: ~d, working threads: ~d, idle threads: ~d, blocked threads: ~d, shutdownp: ~d~@[, pending works: ~%~{~d~^~&~}~]"
          (thread-pool-name pool)
          (sb-concurrency:queue-count (thread-pool-backlog pool))
          (thread-pool-n-total-threads pool)
          (thread-pool-working-threads pool)
          (thread-pool-idle-threads pool)
          (thread-pool-n-blocked-threads pool)
          (thread-pool-shutdown-p pool)
          (when inspect-work-p
            (mapcar #'(lambda(work) (inspect-work work t))
                    (sb-concurrency:list-queue-contents (thread-pool-backlog pool))))))

(defmethod print-object ((pool thread-pool) stream)
  (print-unreadable-object (pool stream :type t)
    (format stream (inspect-pool pool))))

(defun thread-pool-peek-backlog (pool)
  "Return the top pending works of the pool. Return NIL if no pending work in the queue."
  (peek-queue (thread-pool-backlog pool)))

(defun thread-pool-n-concurrent-threads (thread-pool)
  "Return the number of threads in the pool are not blocked."
  (- (thread-pool-n-total-threads thread-pool)
     (thread-pool-n-blocked-threads thread-pool)))

(defstruct work-item
  name
  function
  thread-pool
  result
  status ; :running :aborted :ready :finished :cancelled
  desc)

(defun inspect-work (work &optional (simple-mode nil))
  (format nil (format nil "name: ~d, desc: ~d~@[, pool: ~d~]"
                      (work-item-name work)
                      (work-item-desc work)
                      (unless simple-mode
                        (thread-pool-name (work-item-thread-pool work))))))

(defmethod print-object ((work work-item) stream)
  (print-unreadable-object (work stream :type t)
    (format stream (inspect-work work))))

(defun thread-pool-main (thread-pool)
  (let* ((self (bt2:current-thread)))
    (loop (let ((work nil))
            ;; 通过无锁的原子方法实现, 线程知道自己是否闲置就行, 有多少忙碌多少闲置的工作线程可通过计算实现
            (with-slots (backlog keepalive-time lock cvar idle-threads) thread-pool
              (sb-ext:atomic-decf (thread-pool-working-threads thread-pool))
              (sb-ext:atomic-incf (thread-pool-idle-threads thread-pool))
              (setf (sb-thread:thread-name self) "Thread pool idle worker")
              (let ((start-idle-time (get-internal-run-time)))
                (flet ((exit-while-idle ()
                         (sb-ext:atomic-decf (thread-pool-idle-threads thread-pool))
                         (sb-ext:atomic-decf (thread-pool-n-total-threads thread-pool))
                         (return-from thread-pool-main)))
                  (loop (when (thread-pool-shutdown-p thread-pool)
                          (exit-while-idle))
                        ;; 队列中有未处理工作, 就获取这项工作并退出这个loop, 否则就不停循环等待新工作
                        (alexandria:when-let (wk (sb-concurrency:dequeue backlog))
                          (when (eq (work-item-status wk) :ready)
                            (setf work wk)
                            #+sbcl (setf (sb-thread:thread-name self)
                                         (concatenate 'string "Thread pool worker: " (work-item-name work)))
                            (sb-ext:atomic-decf (thread-pool-idle-threads thread-pool))
                            (sb-ext:atomic-incf (thread-pool-working-threads thread-pool))
                            (sb-ext:atomic-update (work-item-status wk) #'(lambda (x)
                                                                            (declare (ignore x))
                                                                            :running))
                            (return)))
                        (when (> (thread-pool-n-concurrent-threads thread-pool) *worker-num*)
                          (exit-while-idle))
                        (let* ((end-idle-time (+ start-idle-time
                                                 (* keepalive-time internal-time-units-per-second)))
                               (idle-time-remaining (- end-idle-time (get-internal-run-time))))
                          (when (minusp idle-time-remaining)
                            (exit-while-idle))
                          (bt2:with-lock-held (lock)
                            (bt2:condition-wait cvar
                                                lock
                                                :timeout (/ idle-time-remaining internal-time-units-per-second))))))))
            ;; 线程执行工作任务
            (unwind-protect-unwind-only
                (catch 'terminate-work ; catch用于工作内部的非局部退出
                  (funcall (work-item-function work)))
              (sb-ext:atomic-decf (thread-pool-working-threads thread-pool))
              (sb-ext:atomic-decf (thread-pool-n-total-threads thread-pool))
              (setf (work-item-status work) :aborted))))))

(defun thread-pool-add (function thread-pool &key name priority bindings desc)
  "Add a work item to the thread-pool.
Functions are called concurrently and in FIFO order.
A work item is returned, which can be passed to THREAD-POOL-CANCEL-ITEM
to attempt cancel the work.
BINDINGS is a list which specify special bindings
that should be active when FUNCTION is called. These override the
thread pool's initial-bindings."
  (declare (ignore priority)) ; TODO
  (check-type function function)
  (let ((work (make-instance 'work-item ;
                             :function (if bindings
                                           (let ((vars (mapcar #'first bindings))
                                                 (vals (mapcar #'second bindings)))
                                             (lambda ()
                                               (progv vars vals
                                                 (funcall function))))
                                           function)
                             :name name
                             :thread-pool thread-pool
                             :status :ready
                             :desc desc)))
    ;; 可以通过原子操作实现无锁版本
    (with-slots (backlog) thread-pool
      (when (thread-pool-shutdown-p thread-pool)
        (error "Attempted to add work item to shut down thread pool ~S" thread-pool))
      (sb-concurrency:enqueue work backlog)
      (when (and (<= (thread-pool-idle-threads thread-pool) 0)
                 (< (thread-pool-n-concurrent-threads thread-pool)
                    *worker-num*))
        ;; There are no idle threads and there are more logical cores than
        ;; currently running threads. Create a new thread for this work item.
        ;; Push it on the active list to make the logic in T-P-MAIN work out.
        #+:ignore(push (bt2:make-thread (lambda () (thread-pool-main thread-pool))      ; create a new worker thread
                              ;;:name `(thread-pool-worker ,thread-pool nil)  ; list type of name was not applicable in sbcl
                              :name "Idle Worker"
                              :initial-bindings (thread-pool-initial-bindings thread-pool))
                       (thread-pool-working-threads thread-pool))
        (bt2:make-thread (lambda () (thread-pool-main thread-pool))      ; create a new worker thread
                         :name "Idle Worker"
                         :initial-bindings (thread-pool-initial-bindings thread-pool))
        (sb-ext:atomic-incf (thread-pool-working-threads thread-pool))
        (sb-ext:atomic-incf (thread-pool-n-total-threads thread-pool)))
      ;; 通知线程池中正在等待的线程
      (bt2:condition-notify (thread-pool-cvar thread-pool)))
    work))

(defun thread-pool-add-many (function values thread-pool &key name priority bindings)
  "Add many work items to the pool.
A work item is created for each element of VALUES and FUNCTION is called
in the pool with that element.
Returns a list of the work items added."
  (loop
    for value in values
    collect (thread-pool-add
             (let ((value value))
               (lambda () (funcall function value)))
             thread-pool
             :name name
             :priority priority
             :bindings bindings)))

(defun thread-pool-cancel-item (work-item)
  "Cancel a work item, removing it from its thread-pool.
Returns true if the item was successfully cancelled,
false if the item had finished or is currently running on a worker thread."
  (sb-ext:atomic-update (work-item-status work-item) #'(lambda (x)
                                                         (declare (ignore x))
                                                         :cancelled)))


(defun thread-pool-flush (thread-pool)
  "Cancel all outstanding work on THREAD-POOL.
Returns a list of all cancelled items.
Does not cancel work in progress."
  (with-slots (backlog) thread-pool
    (sb-concurrency::try-walk-queue #'(lambda (work)
                                        (sb-ext:atomic-update (work-item-status work)
                                                              #'(lambda (x)
                                                                  (declare (ignore x))
                                                                  :cancelled)))
                                    backlog)
    (prog1 (sb-concurrency:list-queue-contents backlog)
      (queue-flush backlog))))

(defun thread-pool-shutdown (thread-pool &key abort)
  "Shutdown THREAD-POOL.
This cancels all outstanding work on THREAD-POOL
and notifies the worker threads that they should
exit once their active work is complete.
Once a thread pool has been shut down, no further work
can be added unless it's been restarted by thread-pool-restart.
If ABORT is true then worker threads will be terminated
via TERMINATE-THREAD."
  (with-slots (shutdown-p backlog thread-list) thread-pool
    (setf shutdown-p t)
    (thread-pool-flush thread-pool)
    (when abort
      (dolist (thread thread-list)
        (bt2:destroy-thread thread)))
    (bt2:condition-notify (thread-pool-cvar thread-pool)))
  (values))

(defun thread-pool-restart (thread-pool)
  "Calling thread-pool-shutdown will not destroy the pool object, but set the slot %shutdown t.
This function set the slot %shutdown nil so that the pool will be used then.
Return t if the pool has been shutdown, and return nil if the pool was active"
  (if (thread-pool-shutdown-p thread-pool)
      (progn (sb-ext:atomic-update (thread-pool-shutdown-p thread-pool)
                            #'(lambda (x)
                                (declare (ignore x))
                                nil))
             t)
      nil))


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
  (when (and (eql blocking-function 'bt2:acquire-lock)
             (eql (first arguments) (thread-pool-lock thread-pool)))
    ;; Don't suspend when acquiring the thread-pool lock, this causes
    ;; recursive locking on it.
    (return-from thread-pool-block
      (apply blocking-function arguments)))
  (unwind-protect
       (progn
         (bt2:with-lock-held ((thread-pool-lock thread-pool))
           (incf (thread-pool-n-blocked-threads thread-pool)))
         (apply blocking-function arguments))
    (bt2:with-lock-held ((thread-pool-lock thread-pool))
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
