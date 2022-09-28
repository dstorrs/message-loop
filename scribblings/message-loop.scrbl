#lang scribble/manual

@(require (for-label racket)
          racket/sandbox
          scribble/example)

@require[@for-label[message-loop
                    racket/base]]

@title{message-loop}
@author{David K. Storrs}

@defmodule[message-loop]

@section{Introduction}

Provides a single-threaded message loop that can be used as an aggregation point
to trigger arbitrary actions.  Essentially a thread that listens on an async
channel, sends the result through a dispatch table, and then loops.

The message loop can be started before or after listeners are added.  When a
message is posted, all listeners who have registered for that type of message
will have a chance to react, in an unspecified order.

@section{Examples}

@(define eval
   (call-with-trusted-sandbox-configuration
    (lambda ()
      (parameterize ([sandbox-output 'string]
                     [sandbox-error-output 'string]
                     [sandbox-memory-limit 50])
        (make-evaluator 'racket)))))

@examples[
#:eval eval
#:label #f
   (require struct-plus-plus racket/async-channel rx-tx-async-channel)
   (require message-loop)

   (struct++ person (name age) #:transparent)
 
   (start-message-loop)

   (define comm-ch (rx-tx-async-channel++))
   (define ch (make-async-channel))

   (code:comment "Listen for 'birth messages and send out a nicely formatted string")
   (add-listener (listener++ #:listen-for '(birth)
                             #:id         'listener1
                             #:action     (λ (l msg)
                                              (define p (message.data msg))
                                              (async-channel-put ch
                                                                 (format "listener ~a, message ~v. ~a was born"
                                                                         (listener.id l)
                                                                         (message-type msg)
                                                                         (person-name p))))))

   (post-message (message++ #:type 'birth #:data (person "Bob" 17)))
   (code:comment "listener notices that bob was born, puts that fact on the channel")
   (println (sync ch))

   (code:comment "Add multiple listeners at once, one for 'birthday messages and one for 'birthday-modify messages")
   (add-listeners
      (listener++ #:listen-for '(birthday)
                  #:id         'listener2
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
                                                    (set-person-age prsn new-age))))
      (listener++ #:listen-for '(type-only)
      		  #:id 'type-only-listener
    		  #:action (λ (l msg) (async-channel-put ch msg)))
     )

     (code:comment "post a birthday for bob, get back a string describing it")
     (post-message (message++ #:type 'birthday #:data (person "Bob" 17)))
     (println (async-channel-get ch))

     (code:comment "post a birthday-modify for bob, get back an updated version of bob") 
     (post-message (message++ #:type 'birthday-modify #:data (person "Bob" 17)))
     (println (sync (rx-tx-async-channel.to-parent comm-ch)))

     (code:comment "post a birthday for Alice to demonstrate that the listener didn't stop after running once")
     (post-message (message++ #:type 'birthday #:data (person "Alice" 24)))
     (println (async-channel-get ch))

     (code:comment "ditto for birthday-modify")
     (post-message (message++ #:type 'birthday-modify #:data (person "Alice" 24)))
     (println (sync (rx-tx-async-channel.to-parent comm-ch)))
     
     (code:comment "post a message type.  the message struct will be created")
     (post-message 'type-only)
     (println (async-channel-get ch))


     (code:comment "multiple listeners can trigger from a single message")
     (define ch (make-async-channel))
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
     (code:comment "We will get back the IDs of the listeners that receive the message")
     (post-message (message++ #:type 'multi))
     (println (sort (for/list ([i 2]) (sync ch)) symbol<?))

     (define ch (make-async-channel))
     (define bob (person "Bob" 42))

     (code:comment "One listener that listens for both 'matriculate and 'graduate messages")
     (add-listener (listener++ #:listen-for '(matriculate graduate)
                               #:id         'multiple-type-listener
                               #:action     (λ (l msg)
                                              (define p (message.data msg))
                                              (async-channel-put ch
                                                                 (format "listener ~a, message type ~v for ~a"
                                                                         (listener.id l)
                                                                         (message-type msg)
                                                                         (person.name p))))))

     (code:comment "Receive a 'matriculate message")
     (post-message (message++ #:type 'matriculate #:data bob))
     (println (sync ch))

     (code:comment "Receive a 'graduate message")
     (post-message (message++ #:type 'graduate #:data bob))
     (println (sync ch))

]

@section{API}

@subsection{Processing}

@defproc[(start-message-loop) any]{Begin the message processing.  Listeners can be added before this is called.  Messages posted before this is called will remain queued for processing until it is called.}

@defproc[(stop-message-loop) any]{Terminates the message processing thread.}

@subsection{Messages}

The @racketid[message] structure is used to signal that interested listeners should activate.

@defproc[(message-type? [arg any/c]) boolean?]{An alias for @racket[symbol?].  Used for futureproofing.}

@defproc[(message++ [#:type type message-type?]
		    [#:source source any/c #f]
		    [#:data data any/c #f])
		    message?]{Keyword constructor for the message struct. @racketid[source] is intended to specify who created the message while @racketid[data] can carry any message-specific information to be used by the listener.}

@defproc*[([(message.type [msg message?]) message-type?]
  	   [(message.source [msg message?]) any/c]
  	   [(message.data [msg message?]) any/c]
			  )]{Accessors for each of the fields in the @racketid[message] struct.}


@defproc[(post-message [msg message?]) any]{Sends a message to the processing thread.  It will then be farmed out to all relevant listeners.  If @racket[start-message-loop] has not been called, the message will be queued until the loop is started.}


@subsection{Listeners}

The @racketid[listener] structure defines what message types to listen for and what to do with them.

@defproc[(listener++ [#:listen-for message-types (or/c (listof message-type?) message-type?)]
		     [#:action action (-> listener? message? any)]
		     [#:id id symbol? (gensym "listener-")]
                     [#:comm comm rx-tx-async-channel? (rx-tx-async-channel++)])
		     listener?]{Keyword constructor for the @racketid[listener] struct.

@racketid[listen-for] is a list of message types to listen for. NOTE: As a convenience, you may specify a single message type and it will be converted to a one-element list in the process of creating the struct.

@racketid[action] is the procedure that will be called when the relevant message type comes in.  It is called with the listener itself and with the message that triggered the listener.

@racketid[id] allows you to easily distinguish between listeners.

@racketid[comm] provides a pair of async channels that can be used to communicate to and from the listener.
}

@defproc*[([(listener.listen-for [l listener?]) (listof message-type?)]
           [(listener.action [l listener?]) (-> listener? message? any)]
           [(listener.id [l listener?]) symbol?]
           [(listener.comm [l listener?]) rx-tx-async-channel?])]{Accessors for the various fields of a listener.}

@defproc[(add-listener [l listener?]) any]{Notify the message processor to use this listener.  Listeners can be added before the message processing loop is started (cf @racket[start-message-loop]) but, obviously, processing will not happen until then.}
@defproc[(add-listeners [l listener?] ...) any]{Add multiple listeners at a time.}

