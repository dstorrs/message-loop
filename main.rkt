#lang racket/base

(require handy/utils)

(require racket/require
         (multi-in racket (async-channel contract format function match set splicing))
         rx-tx-async-channel
         struct-plus-plus
         thread-with-id
         )

(provide (struct-out message)
         message++
         message.type
         message.source
         message.data
         (struct-out listener)
         listener++
         listener.id
         listener.listen-for
         listener.action
         listener.comm

         start-message-loop
         stop-message-loop
         post-message
         add-listener
         add-listeners
         )

(define message-type? symbol?)

;  embodies a message that can be sent to the message loop.  They must have a type to
;  specify what the message means.  They can optionally have a `source`, which specifies
;  who is sending the message.  They can optionally have some arbitrary data.
(struct++ message ([type         message-type?]
                   [(source #f)  any/c]
                   [(data #f)    any/c]))

; listeners have a list of message types that they are listening for
; they have an action
(struct++ listener ([(id (gensym "listener-"))      symbol?]
                    [listen-for                     (or/c message-type? (listof message-type?))
                                                    (λ (v)
                                                      (if (list? v) v (list v)))]
                    [action                         (-> listener? message? any)]
                    [(comm (rx-tx-async-channel++)) rx-tx-async-channel?]
                    )
          #:property prop:procedure (λ (l msg) ((listener.action l) l msg)))


(define message-loop-ch (make-async-channel))
(define handlers (make-hash))

(define/contract (post-message msg)
  (-> (or/c message-type? message?) any)
  (async-channel-put message-loop-ch
                     (if (message? msg)
                         msg
                         (message++ #:type msg))))

(define/contract (add-listener l)
  (-> listener? any)
  (define message-types (listener.listen-for l))
  (for ([message-type (in-list message-types)])
    (define current-listeners (hash-ref handlers message-type (mutable-set)))
    (hash-set! handlers message-type
               (and (set-add! current-listeners l)
                    current-listeners))))


(define (add-listeners . listeners)
  (for-each add-listener listeners))



;;----------------------------------------------------------------------

(splicing-let ([message-loop-thread #f])
  (define (start-message-loop)
    (when message-loop-thread
      (raise (exn:fail "message loop already running" (current-continuation-marks))))
    (set! message-loop-thread
          (thread-with-id
           (thunk
            (let loop ()
              ; Wait until we get a message.  Process the message.  Loop
              (define msg (sync message-loop-ch))
              (define type (message.type msg))
              (define listeners (hash-ref handlers type #f))
              (when listeners
                (for ([next-listener (in-set listeners)])
                  (next-listener msg)))
              (loop))))))

  (define (stop-message-loop)
    (when message-loop-thread
      (kill-thread message-loop-thread))
    (set!  message-loop-thread #f))
  )

;;----------------------------------------------------------------------
;;----------------------------------------------------------------------
;;----------------------------------------------------------------------


(module+ test
  (require test-more)

  (struct++ person (name age) #:transparent)

  (start-message-loop)

  (test-suite
   "basic API"

   (let ([comm-ch (rx-tx-async-channel++)]
         [ch (make-async-channel)])

     (add-listener (listener++ #:listen-for '(birth)
                               #:id         'listener1
                               #:comm       comm-ch
                               #:action     (λ (l msg)
                                              (define p (message.data msg))
                                              (async-channel-put ch
                                                                 (format "listener ~a, event ~v. ~a was born"
                                                                         (listener.id l)
                                                                         (message-type msg)
                                                                         (person-name p))))))

     (post-message (message++ #:type 'birth #:data (person "Bob" 17)))

     (is (sync/timeout 0.5 ch)
         "listener listener1, event 'birth. Bob was born"
         "successfully determined that bob was born")


     (add-listeners
      (listener++ #:listen-for '(birthday)
                  #:id         'listener2
                  #:comm       comm-ch
                  #:action     (λ (l msg)
                                 (define p (message.data msg))
                                 (async-channel-put
                                  ch
                                  (format "listener ~a heard that ~a had a birthday at time ~a"
                                          (listener.id l)
                                          (person.name p)
                                          1234))))
      (listener++ #:listen-for '(birthday-modify)
                  #:id         'listener3
                  #:comm       comm-ch
                  #:action     (λ (l msg)
                                 (match-define (struct* message
                                                        ([data (and prsn
                                                                    (struct person (name age)))]))
                                   msg)
                                 (define new-age (add1 age))
                                 (async-channel-put (rx-tx-async-channel.to-parent
                                                     (listener.comm l))
                                                    (set-person-age prsn new-age)))))

     ; post a birthday for bob
     (post-message (message++ #:type 'birthday #:data (person "Bob" 17)))
     (is (async-channel-get ch)
         "listener listener2 heard that Bob had a birthday at time 1234"
         "got the time of bob's birthday")

     (post-message (message++ #:type 'birthday-modify #:data (person "Bob" 17)))
     (is (sync/timeout 0.5 (rx-tx-async-channel.to-parent comm-ch))
         (person "Bob" 18)
         "successfully noticed Bob's birthday and aged him up")

     ; post a birthday for Alice to verify the listener is still working
     (post-message (message++ #:type 'birthday #:data (person "Alice" 24)))
     (is (async-channel-get ch)
         "listener listener2 heard that Alice had a birthday at time 1234"
         "second time:  got the time of Alice's birthday")

     ; ditto for birthday-modify
     (post-message (message++ #:type 'birthday-modify #:data (person "Alice" 24)))
     (is (sync/timeout 0.5 (rx-tx-async-channel.to-parent comm-ch))
         (person "Alice" 25)
         "second time: successfully noticed Alice's birthday and aged her up")
     )
   )
  (test-suite
   "posting types instead of full messages"
   (let ([ch (make-async-channel)])
     (add-listener (listener++ #:listen-for '(foo)
                                #:id         'listener-foo
                                #:action     (λ (l msg)
                                               (async-channel-put
                                                ch
                                                (list (listener.id l)
                                                      (message.type msg))))))
     (post-message 'foo)
     (is (sync ch) '(listener-foo foo) "can post a type and the system will generate a message"))
   )

  (test-suite
   "multiple listeners can take the same message type"
   (let ([ch (make-async-channel)])
     (add-listeners (listener++ #:listen-for '(multi)
                                #:id         'listener-X
                                #:action     (λ (l msg)
                                               (async-channel-put
                                                ch
                                                (listener.id l))))
                    (listener++ #:listen-for '(multi)
                                #:id         'listener-Y
                                #:action     (λ (l msg)
                                               (async-channel-put
                                                ch
                                                (listener.id l)))))
     (post-message (message++ #:type 'multi))
     (define results (sort (for/list ([i 2]) (sync ch)) symbol<?))
     (is results
         (list 'listener-X 'listener-Y)
         "multiple listeners can react to a single message"))
   )

  (test-suite
   "a single listener can take multiple message types"
   (let ([ch (make-async-channel)]
         [bob (person "Bob" 42)])

     (add-listener (listener++ #:listen-for '(birth death)
                               #:id         'multiple-type-listener
                               #:action     (λ (l msg)
                                              (define p (message.data msg))
                                              (async-channel-put ch
                                                                 (format "listener ~a, event type ~v for ~a"
                                                                         (listener.id l)
                                                                         (message-type msg)
                                                                         (person.name p))))))

     (post-message (message++ #:type 'birth #:data bob))
     (is (sync ch)
         "listener multiple-type-listener, event type 'birth for Bob"
         "'multiple-type-listener' triggered for bob's birth"
         )
     (post-message (message++ #:type 'death #:data bob))
     (is (sync ch)
         "listener multiple-type-listener, event type 'death for Bob"
         "'multiple-type-listener' triggered for bob's death"))
   )

  (test-suite
   "add listener before start"

   (stop-message-loop)
   
   (define ch (make-async-channel))
   (add-listener (listener++ #:listen-for 'foo
                             #:action (λ _ (async-channel-put ch 'ok))))
   (post-message (message++ #:type 'foo))
   (is-false (sync/timeout 0.5 ch) "no response from listener before start-message-loop")
   (start-message-loop)
   (is (sync/timeout 0.5 ch) 'ok "post-message is stored until after start-message-loop"))
  
  (done-testing)
  )
