(defpackage #:cl-mzpool-tests
  (:use #:cl #:parachute)
  (:export #:test
           #:))

(in-package :cl-mzpool-tests)

(define-test cl-mzpool-tests)

(define-test mzpool-test :parent cl-mzpool-tests)
(define-test mzpool2-test :parent cl-mzpool-tests)
