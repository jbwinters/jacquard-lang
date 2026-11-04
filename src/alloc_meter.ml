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
    (* never lowers the count: a nested ceiling clamped below [max_int] can sit under it *)
    if !ceiling < max_int then used := max !used !ceiling;
    ceiling := -1)

(** The number of invocations that have ended with allocation exhausted. A native's E0921 exhausts
    the enclosing invocation only when this rose while the native ran: evidence that a nested run
    really did run out, not just an error that carries the code. *)
let nested_exhaustions = ref 0

(** Text rendered while a counted rendering runs (RT.2, §3.1 "counted while built"). [rendering] is
    on inside {!Eval.with_rendered}; [rendered] holds the cells of the renderings finished so far,
    charged when it ends. *)
let rendering = ref false

let rendered = ref 0

(** Cells pending in the renderings enclosing this one, charged when they end. *)
let outer_rendered = ref 0

exception Built_exceeded

let text_cells bytes = 1 + ((bytes + 7) / 8)

(** [rendered_so_far bytes] checks a rendering's output against the remaining allowance as it grows,
    raising {!Built_exceeded} at most one element past it. *)
let[@inline] rendered_so_far bytes =
  if !rendering && !outer_rendered + !rendered + text_cells bytes > !ceiling - !used then
    raise Built_exceeded

(** [rendering_done bytes] records a finished rendering. *)
let[@inline] rendering_done bytes = if !rendering then rendered := !rendered + text_cells bytes

(** [rendered_piece text] records a piece of text a counted rendering keeps, stopping at the
    remaining allowance, and returns it. *)
let rendered_piece text =
  rendering_done (String.length text);
  if !rendering && !outer_rendered + !rendered > !ceiling - !used then raise Built_exceeded;
  text

(** [exhausted ()] holds once a bounded invocation has run out of allocation. *)
let exhausted () = !ceiling < 0
