(** Frozen deterministic contracts and the scheduler-owned state machine for scoped channels.

    A channel is local to one structured scope and evaluator run. This module deliberately knows
    nothing about Jacquard values or evaluator continuations: callers choose the task, resume, and
    payload types and must validate opaque ownership before invoking a transition. *)

exception Bug_invalid_channel_id of string
(** Internal invariant failure raised only when trusted scheduler code attempts to construct a
    malformed channel identity. *)

val channel_handle_type_hash : string
(** HASH_V0 identity of the frozen [ChannelHandle a] declaration. *)

val channel_opaque_constructor_hash : string
(** Derived identity of the scheduler-private [ChannelOpaque] carrier. *)

val channel_error_type_hash : string
(** HASH_V0 identity of the frozen [ChannelError] declaration. *)

val channel_closed_constructor_hash : string
(** Derived identity of the frozen [ChannelClosed] constructor. *)

val invalid_capacity_constructor_hash : string
(** Derived identity of the frozen [InvalidCapacity] constructor. *)

val channel_effect_hash : string
(** HASH_V0 identity of the exact frozen four-operation [Channel a] effect. *)

val channel_operation_hashes : (string * string) list
(** Exact member identities, in declaration order from [channel.open] through [channel.close]. *)

val is_channel_private_hash : Hash.t -> bool
(** [is_channel_private_hash hash] holds exactly for identities Jacquard code must never name or
    construct. In SC.14 this is the private [ChannelOpaque] carrier. *)

type channel_id = private { scope_path : int list; open_index : int }
(** Deterministic scope-local identity. [open_index] is the zero-based ordinal of a successful
    [channel.open]; rejected negative capacities do not consume an ordinal. *)

val channel_id : scope_path:int list -> open_index:int -> channel_id
(** [channel_id] constructs a trusted scheduler identity. The scope path follows the Task path
    grammar and [open_index] must be non-negative and fit unsigned 32 bits. Invalid trusted input
    raises [Bug_invalid_channel_id]. *)

val compare_channel_id : channel_id -> channel_id -> int
(** [compare_channel_id] orders scope paths lexicographically and then successful-open ordinals. *)

val trace_channel_id : channel_id -> string
(** [trace_channel_id] renders the scheduler-only spelling [path@open], for example [0/2@3]. *)

type ('task, 'value) pending_sender = { sender : 'task; sent_value : 'value }
(** One FIFO blocked sender and its unaccepted payload. Its affine resume remains owned by that
    task's scheduler entry; channel state never owns raw continuations. *)

type 'task pending_receiver = { receiver : 'task }
(** One FIFO blocked receiver. Its affine resume remains owned by the scheduler task entry. *)

type ('task, 'value) t
(** Mutable scheduler-owned state for one channel. *)

type ('task, 'value) opening =
  | Opened of ('task, 'value) t
  | Invalid_capacity of int
      (** Typed outcome of opening. A negative capacity returns [Invalid_capacity] without
          constructing a channel ID or mutating scheduler state. *)

val open_channel : scope_path:int list -> open_index:int -> capacity:int -> ('task, 'value) opening
(** [open_channel] returns [Invalid_capacity capacity] for negative input before validating or
    allocating [open_index]. Otherwise it constructs empty open channel state. Malformed trusted
    identities raise [Bug_invalid_channel_id]. *)

type 'task send_outcome =
  | Send_completed
  | Send_delivered of 'task pending_receiver
  | Send_blocked
  | Send_closed
      (** Result of one send transition. A delivered receiver must be resumed before the sender;
          [Send_blocked] means the channel now owns the supplied payload while the scheduler task
          entry owns its resume. *)

val send : ('task, 'value) t -> sender:'task -> value:'value -> 'task send_outcome
(** [send] implements closed refusal, direct receiver handoff, bounded FIFO buffering, or FIFO
    sender suspension in that order. It accepts or retains the supplied payload exactly once. *)

type ('task, 'value) recv_outcome =
  | Recv_delivered of { value : 'value; completed_sender : ('task, 'value) pending_sender option }
  | Recv_blocked
  | Recv_closed
      (** Result of one receive transition. [completed_sender] is the oldest rendezvous sender or
          the oldest sender promoted into a newly free buffer slot. *)

val recv : ('task, 'value) t -> receiver:'task -> ('task, 'value) recv_outcome
(** [recv] consumes the oldest buffered value first, promoting at most one blocked sender; then it
    rendezvous-delivers the oldest sender; then reports a drained close or suspends FIFO. *)

type ('task, 'value) close_outcome = {
  rejected_senders : ('task, 'value) pending_sender list;
  rejected_receivers : 'task pending_receiver list;
}
(** Waiters released by the first close, each in original FIFO order. Buffered values remain
    drainable. A repeated close returns empty lists. *)

val close : ('task, 'value) t -> ('task, 'value) close_outcome
(** [close] marks the channel closed, rejects every blocked sender, and rejects receivers only when
    no buffered value remains. It is idempotent. *)

type ('task, 'value) cancellation =
  | Cancelled_sender of ('task, 'value) pending_sender
  | Cancelled_receiver of 'task pending_receiver
  | Not_blocked
      (** Ownership removed by cancelling one channel-blocked task. Survivors retain FIFO order. *)

val cancel :
  equal_task:('task -> 'task -> bool) -> ('task, 'value) t -> 'task -> ('task, 'value) cancellation
(** [cancel] removes at most one blocked operation for [task] without reordering survivors. *)

type ('task, 'value) teardown = {
  dropped_values : 'value list;
  dropped_senders : ('task, 'value) pending_sender list;
  dropped_receivers : 'task pending_receiver list;
}
(** Every remaining channel-owned payload and waiter identity transferred out during scope
    teardown, in deterministic channel-local FIFO order. Scheduler entries continue to own the
    corresponding affine resumes. *)

val teardown : ('task, 'value) t -> ('task, 'value) teardown
(** [teardown] closes and empties the channel, transferring all remaining ownership exactly once.
    Repeated teardown returns empty lists. *)

type view = {
  id : channel_id;
  capacity : int;
  closed : bool;
  buffered : int;
  waiting_senders : int;
  waiting_receivers : int;
}
(** Read-only counts for invariant tests, diagnostics, and deadlock detection. *)

val view : ('task, 'value) t -> view
(** [view] observes state without transferring any payload or resume ownership. *)
