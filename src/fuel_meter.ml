(** The process-wide computation-fuel meter (RT.1).

    Fuel is counted in fine units: one fuel unit is 64 fine units. The evaluator debits 64 per
    machine state and the other fuel-v1 costs through [Eval]; value rendering, code printing and
    form comparison {!tick} one fine unit per node and per text byte wherever they run, so every
    walk of a value during a bounded invocation, in the evaluator, a native, or a driver, draws on
    the same budget. [Eval.with_invocation] sets and restores {!ceiling}. The interpreter is
    single-threaded; the meter is not domain-safe. *)

exception Exceeded
(** A walk passed the ceiling. The meter is already exhausted when this is raised. *)

let used = ref 0
let ceiling = ref max_int

(** The budget, in fuel units, of the innermost bounded invocation; reported by E0919 even when the
    walk or run that ran out belongs to an unbounded invocation nested inside it. *)
let budget = ref 0

(** [trip ()] exhausts the meter: the remaining allowance is spent, and no later debit or walk can
    pass the negative ceiling. *)
let trip () =
  if !ceiling >= 0 then (
    if !ceiling < max_int then used := !ceiling;
    ceiling := -1)

(** [exhausted ()] holds once a bounded invocation has run out of fuel. *)
let exhausted () = !ceiling < 0

(** [tick units] records [units] fine units of walking work, raising {!Exceeded} past the ceiling.
*)
let[@inline] tick units =
  let total = !used + units in
  if total > !ceiling then (
    (* a refused walk spends the remainder once; after exhaustion nothing more is counted *)
    trip ();
    raise Exceeded)
  else used := total

(** [unmetered f] runs [f] (rendering outside the evaluator, such as printing a final result)
    without drawing on or tripping the budget. *)
let unmetered f =
  let saved_used = !used and saved_ceiling = !ceiling in
  ceiling := max_int;
  Fun.protect
    ~finally:(fun () ->
      used := saved_used;
      ceiling := saved_ceiling)
    f
