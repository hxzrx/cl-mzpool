(defpackage #:cl-mzpool-tests
  (:use #:cl #:parachute)
  (:export #:test
           #:pool
           #:pool2))

(in-package :cl-mzpool-tests)

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




(define-test make-thread-pool2 :parent pool2
  (finish (mpool2:make-thread-pool))
  ;;(fail   (mpool2:make-thread-pool :keepalive-time -1)) ; this definitely fails but will signal compile error
  (finish (mpool2:make-thread-pool :name "" :worker-num 10 :keepalive-time 0))
  (finish (mpool2:make-thread-pool :name "test pool" :worker-num 10 :keepalive-time 1)))
