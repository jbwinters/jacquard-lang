(** Opaque, evaluator-owned mutable state for an affine resumption.

    This module is Dune-private: public clients can hold a token through [Value.t], but cannot
    construct, inspect, consume, or restore it directly. Consumption is monotonic; the evaluator may
    observe it for mutation guards but has no reset operation. Each token also retains its creating
    evaluator-run identity so a foreign evaluator is rejected before consumption. *)

type 'a t = { owner : Task_handle.run; payload : 'a; mutable consumed : bool }

let create ~owner payload = { owner; payload; consumed = false }
let payload state = state.payload
let owned_by ~owner state = state.owner == owner

let consume state =
  if state.consumed then None
  else (
    state.consumed <- true;
    Some state.payload)

let snapshot state = state.consumed
