# SC.13 Channel Contract Traces

These format-1 fixtures are normative design traces, not output from the SC.9
scheduler. SC.14 must reproduce the same state transitions when it adds the
runtime. Each line records one scheduler decision, the chosen task and
operation affecting channel state, the complete abstract channel state before
and after the atomic operation, its result, and the exact append-to-runnable
wake order.

- `rendezvous-v1.trace` pins negative-capacity rejection without ChannelId
  consumption, the current-task wake after open, capacity-zero handoff, sender
  and receiver blocking, receiver cancellation without survivor reordering,
  close rejection of the survivor, receive-after-close, and an explicit second
  close on the closed state.
- `buffered-v1.trace` pins FIFO buffering, backpressure, oldest-sender
  promotion, sender cancellation without survivor reordering, registration-order
  close rejection of the remaining senders, draining accepted values after
  close, the terminal closed result, and the same current-task wake after open.

Task and channel spellings are diagnostic-only deterministic IDs. A channel is
`SCOPE@OPEN_INDEX`; an invalid-capacity open allocates no ID and consumes no
index. Values in these fixtures are tokens standing for typed Jacquard values.
