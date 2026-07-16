(** Opaque mutable state for an affine resumption.

    This module is Dune-private: public clients can hold a token through [Value.t], but cannot
    construct, inspect, consume, or restore it directly. Consumption is monotonic; the evaluator may
    observe it for mutation guards but has no reset operation. *)

type 'a t = { payload : 'a; mutable consumed : bool }

let create payload = { payload; consumed = false }
let payload state = state.payload

let consume state =
  if state.consumed then None
  else (
    state.consumed <- true;
    Some state.payload)

let snapshot state = state.consumed
