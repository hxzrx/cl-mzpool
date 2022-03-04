(defpackage #:cl-mzpool-tests
  (:use #:cl #:parachute)
  (:export #:test
           #:pool
           #:pool2))

(in-package :cl-mzpool-tests)


(defmacro make-parameterless-fun (fun &rest args)
  "(funcall (make-parameterless-fun + 1 3))"
  `(lambda ()
      (funcall #',fun ,@args)))

(defun make-random-list (n &optional (max 100))
  (loop for i below n collect (random max)))


(define-test cl-mzpool-tests)
(define-test utils :parent cl-mzpool-tests)
(define-test pool :parent cl-mzpool-tests)
(define-test pool2 :parent cl-mzpool-tests)

(define-test peek-queue :parent utils
  (let ((queue (sb-concurrency:make-queue)))
    (is eq nil (utils:peek-queue queue))
    (is eq nil (utils:peek-queue queue))

    (sb-concurrency:enqueue nil queue)
    (is eq nil (utils:peek-queue queue))

    (sb-concurrency:dequeue queue)
    (is eq nil (utils:peek-queue queue))

    (sb-concurrency:enqueue t queue)
    (is eq t (utils:peek-queue queue))

    (sb-concurrency:dequeue queue)
    (is eq nil (utils:peek-queue queue))

    (sb-concurrency:enqueue 1 queue)
    (is = 1 (utils:peek-queue queue))
    (sb-concurrency:enqueue 2 queue)
    (is = 1 (utils:peek-queue queue))))

(define-test queue-flush :parent utils
  (let ((queue (sb-concurrency:make-queue)))
    (true (sb-concurrency:queue-empty-p queue))
    (false (utils:queue-flush queue))

    (sb-concurrency:enqueue nil queue)
    (false (sb-concurrency:queue-empty-p queue))
    (utils:queue-flush queue)
    (true (sb-concurrency:queue-empty-p queue))

    (sb-concurrency:enqueue 1 queue)
    (false (sb-concurrency:queue-empty-p queue))
    (true (utils:queue-flush queue))
    (true (sb-concurrency:queue-empty-p queue))

    (sb-concurrency:enqueue 1 queue)
    (sb-concurrency:enqueue 2 queue)
    (sb-concurrency:enqueue 3 queue)
    (true (utils:queue-flush queue))
    (true (sb-concurrency:queue-empty-p queue))
    (false (utils:queue-flush queue))))


;;; ------- thread-pool2 -------

(define-test pool2-make-pool-and-inspect :parent pool2
  (finish (mpool2:inspect-pool (mpool2:make-thread-pool)))
  ;;(fail (mpool2:inspect-pool (mpool2:make-thread-pool :keepalive-time -1))) ; this definitely fails but will signal compile error
  (finish (mpool2:inspect-pool (mpool2:make-thread-pool :name "" :max-worker-num 10 :keepalive-time 0)))
  (finish (mpool2:inspect-pool (mpool2:make-thread-pool :name "test pool" :max-worker-num 10 :keepalive-time 1))))

(define-test pool2-peek-backlog :parent pool2
  (let ((pool (mpool2:make-thread-pool)))
    (is eq nil (mpool2::thread-pool-peek-backlog pool))
    (sb-concurrency:enqueue :work1 (mpool2::thread-pool-backlog pool))
    (is eq :work1 (mpool2:thread-pool-peek-backlog pool))
    (sb-concurrency:enqueue :work2 (mpool2::thread-pool-backlog pool))
    (is eq :work1 (mpool2:thread-pool-peek-backlog pool))
    (sb-concurrency:dequeue (mpool2::thread-pool-backlog pool))
    (is eq :work2 (mpool2:thread-pool-peek-backlog pool))
    (sb-concurrency:dequeue (mpool2::thread-pool-backlog pool))
    (is eq nil (mpool2::thread-pool-peek-backlog pool))))

(define-test pool2-make-work-item :parent pool2
  (let ((pool (mpool2:make-thread-pool)))
    (finish (mpool2:inspect-work (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                                        :thread-pool pool)))
    (finish (mpool2:inspect-work (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3))))
    (finish (mpool2:inspect-work (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                                        :thread-pool pool
                                                        :name "name")))
    (finish (mpool2:inspect-work (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                                        :thread-pool pool
                                                        :desc "desc")))
    (finish (mpool2:inspect-work (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                                        :thread-pool pool
                                                        :name "name"
                                                        :desc "desc")))))

(define-test pool2-add-work :parent pool2
  (let* ((pool (mpool2:make-thread-pool))
         (work0 (mpool2:make-work-item :function #'(lambda () (+ 1 2 3)))) ; to test in default pool
         (work1 (mpool2:make-work-item :function #'(lambda () (+ 1 2 3)))) ; to test in local pool, will be warned
         (work2 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3) ; all test in local pool
                                       :thread-pool pool))
         (work3 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work4 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work5 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work6 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work7 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work8 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool))
         (work9 (mpool2:make-work-item :function (make-parameterless-fun + 1 2 3)
                                       :thread-pool pool)))
    (finish (mpool2:add-work work0))
    (finish (mpool2:add-work work1 pool))
    (finish (mpool2:add-work work2 pool))
    (finish (mpool2:add-work work3 pool))
    (finish (mpool2:add-work work4 pool))
    (finish (mpool2:add-work work5 pool))
    (finish (mpool2:add-work work6 pool))
    (finish (mpool2:add-work work7 pool))
    (finish (mpool2:add-work work8 pool))
    (finish (mpool2:add-work work9 pool))
    (sleep 0.0001)
    (is equal (list 6) (mpool2:get-result work0))
    (is equal (list 6) (mpool2:get-result work1))
    (is equal (list 6) (mpool2:get-result work2))
    (is equal (list 6) (mpool2:get-result work3))
    (is equal (list 6) (mpool2:get-result work4))
    (is equal (list 6) (mpool2:get-result work5))
    (is equal (list 6) (mpool2:get-result work6))
    (is equal (list 6) (mpool2:get-result work7))
    (is equal (list 6) (mpool2:get-result work8))
    (is equal (list 6) (mpool2:get-result work9))
    (sleep 0.0001)
    (is eq nil (mpool2::thread-pool-peek-backlog pool))))
