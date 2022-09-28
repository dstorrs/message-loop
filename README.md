message-loop
============

Provides a single-threaded message loop that can be used as an
aggregation point to trigger arbitrary actions. Essentially a thread
that listens on an async channel, sends the result through a dispatch
table, and then loops.

The message loop can be started before or after listeners are
added. When a message is posted, all listeners who have registered for
that type of message will have a chance to react, in an unspecified
order.

See scribble docs.
