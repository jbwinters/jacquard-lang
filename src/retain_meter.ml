(** The process-wide registry ceilings (RT.2 §4, docs/designs/allocation-limits.md).

    Each registry counts the entries an invocation retains at once, across every scheduler and scope
    (a nested [async.scope] cannot reset it). [Eval.with_invocation] and [Eval.with_scope] set and
    restore each {!ceiling}, so a nested invocation stays within the outer one's. Reaching a ceiling
    is sticky until the bounded invocation ends, like allocation exhaustion. The interpreter is
    single-threaded; the meter is not domain-safe. *)

type registry =
  | Tasks
      (** retained tasks: spawned tasks and nested scope bodies, until their scope is torn down *)
  | Channels  (** open channels, until their scope is torn down *)

type counter = {
  mutable count : int;  (** entries retained now *)
  mutable ceiling : int;  (** the most entries allowed at once; [max_int] when unbounded *)
  mutable limit : int;  (** the ceiling of the innermost bounded invocation; reported by E0921 *)
}

let tasks = { count = 0; ceiling = max_int; limit = 0 }
let channels = { count = 0; ceiling = max_int; limit = 0 }
let counter = function Tasks -> tasks | Channels -> channels

(** [flag registry] is the command-line option that sets the registry's ceiling. *)
let flag = function Tasks -> "--max-tasks" | Channels -> "--max-channels"

(** [noun registry] names one entry of the registry, for diagnostics. *)
let noun = function Tasks -> "retained task" | Channels -> "open channel"

type reached = { registry : registry; limit : int; wanted : int }
(** The ceiling that was reached, with the count the refused entry would have made: sticky until the
    bounded invocation ends. *)

let reached : reached option ref = ref None

(** The ceiling reached by the invocation that most recently ended with one reached ([None] when it
    ran out of allocation instead), so a native returning that invocation's E0921 reaches it in the
    enclosing invocation too. Counted by [Alloc_meter.nested_exhaustions]. *)
let last_nested : reached option ref = ref None

(** [acquire registry] retains one entry. It refuses, and records the ceiling as reached, when the
    entry would pass the registry's ceiling or a ceiling was already reached. *)
let acquire registry =
  if Option.is_some !reached then false
  else
    let counter = counter registry in
    let wanted = counter.count + 1 in
    if wanted > counter.ceiling then (
      reached := Some { registry; limit = counter.limit; wanted };
      false)
    else (
      counter.count <- wanted;
      true)

(** [release registry n] releases [n] entries retained earlier. *)
let release registry n =
  let counter = counter registry in
  counter.count <- max 0 (counter.count - n)

(** [exhausted ()] holds once a ceiling has been reached. *)
let exhausted () = Option.is_some !reached

type saved = { saved_ceilings : (int * int) list; saved_reached : reached option }
(** A saved ceiling configuration, restored when a bounded invocation or scope ends. *)

let registries = [ Tasks; Channels ]

let save () =
  {
    saved_ceilings =
      List.map
        (fun registry ->
          let counter = counter registry in
          (counter.ceiling, counter.limit))
        registries;
    saved_reached = !reached;
  }

(** [bound registry limit] lowers the registry's ceiling to [limit] more entries than it holds now,
    within the ceiling already in force. It returns whether the new ceiling binds (is no higher than
    the enclosing one), in which case [limit] is what E0921 reports. *)
let bound registry limit =
  let counter = counter registry in
  let own = if limit > max_int - counter.count then max_int else counter.count + limit in
  if own <= counter.ceiling then (
    counter.ceiling <- own;
    counter.limit <- limit;
    true)
  else false

(** [restore saved] restores the enclosing ceilings. A ceiling reached inside stays reached only if
    the refused entry would also have passed the enclosing ceiling. *)
let restore saved =
  List.iter2
    (fun registry (ceiling, limit) ->
      let counter = counter registry in
      counter.ceiling <- ceiling;
      counter.limit <- limit)
    registries saved.saved_ceilings;
  reached :=
    match (saved.saved_reached, !reached) with
    | (Some _ as outer), _ -> outer
    | None, Some inner when inner.wanted > (counter inner.registry).ceiling ->
        Some { inner with limit = (counter inner.registry).limit }
    | None, (Some _ | None) -> None
