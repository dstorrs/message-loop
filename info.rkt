#lang info
(define collection "message-loop")
(define deps '("base"
               "rx-tx-async-channel"
               "struct-plus-plus"
               "thread-with-id"
               ))
(define build-deps '("scribble-lib" "racket-doc" "test-more"))
(define scribblings '(("scribblings/message-loop.scrbl" ())))
(define pkg-desc "Description Here")
(define version "1.0")
(define pkg-authors '("David K. Storrs"))
(define license '(MIT))
