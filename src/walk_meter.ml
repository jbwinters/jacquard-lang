(** A counter for whole-value walks (RT.1 computation fuel).

    Rendering, printing, and comparing values or code forms tick this meter once per node and once
    per text byte. Outside {!metered} nothing observes it; inside, a walk that passes the limit
    stops with {!Exceeded}, so a native that walks an exponentially shared value stops at its
    allowance instead of finishing the walk. The interpreter is single-threaded; the meter is not
    domain-safe. *)

exception Exceeded

let count = ref 0
let limit = ref max_int

(** [tick units] records [units] of walking work, raising [Exceeded] past the active limit. *)
let[@inline] tick units =
  count := !count + units;
  if !count > !limit then raise Exceeded

(** [metered ~limit f] runs [f] with a fresh count and the given limit. It returns [f]'s result and
    the work it walked, or [None] if the walk passed [limit]. The enclosing count and limit are
    restored on every exit, and the enclosing count includes the inner work. Other exceptions from
    [f] propagate. *)
let metered ~limit:inner f =
  let saved_count = !count and saved_limit = !limit in
  count := 0;
  limit := inner;
  let restore walked =
    limit := saved_limit;
    count := saved_count + walked
  in
  match f () with
  | result ->
      let walked = !count in
      restore walked;
      Some (result, walked)
  | exception Exceeded ->
      restore inner;
      None
  | exception exn ->
      restore !count;
      raise exn
