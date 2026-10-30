(** The process-wide logical-allocation meter (RT.2, cost model alloc-v1;
    docs/designs/allocation-limits.md).

    Allocation is counted in cells. The evaluator charges the cells a transition allocates before it
    allocates them ([Eval.charge_alloc]); [Eval.with_invocation ~alloc] sets and restores
    {!ceiling}, so an invocation nested inside a bounded one stays within the outer allowance.
    Exhaustion is sticky until the bounded invocation ends. The interpreter is single-threaded; the
    meter is not domain-safe. *)

let used = ref 0
let ceiling = ref max_int

(** The budget, in cells, of the innermost bounded invocation; reported by E0921. *)
let budget = ref 0

(** [trip ()] exhausts the meter: the remaining allowance is spent, and no later charge can pass the
    negative ceiling. *)
let trip () =
  if !ceiling >= 0 then (
    if !ceiling < max_int then used := !ceiling;
    ceiling := -1)

(** The number of invocations that have ended with allocation exhausted. A native's E0921 exhausts
    the enclosing invocation only when this rose while the native ran: evidence that a nested run
    really did run out, not just an error that carries the code. *)
let nested_exhaustions = ref 0

(** [exhausted ()] holds once a bounded invocation has run out of allocation. *)
let exhausted () = !ceiling < 0
