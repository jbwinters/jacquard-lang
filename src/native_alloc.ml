(** How each trusted native allocates, in alloc-v1 cells (RT.2, docs/designs/allocation-limits.md
    §3.1). A test fails on any installed trusted native without a class. *)

type kind =
  | Fresh
      (** a result of constant size (a scalar, boolean, option of a scalar, hash or one code node),
          or built from scratch no larger than a constant: every node is new, charged on return *)
  | Sized  (** charges its result itself, before building it ([Eval.charge_native_alloc]) *)
  | Rendered  (** its result is a rendering, counted as the text grows and sized if joined *)
  | Rendering  (** renders text it keeps or discards, then returns a [Fresh] result *)
  | Shared_text  (** [some(text)] or [none] over a text the input already holds *)
  | Posterior
      (** renders hashed code, and returns a record that embeds some of its inputs, which are not
          charged again *)

(** Text costs one cell plus one per started 8 bytes. *)
let text_cells = Alloc_meter.text_cells

(* Nodes are counted once each, by physical identity: sharing costs nothing (§3.1), and a value or
   code form shared exponentially often is walked once per distinct node. *)
module Seen = Hashtbl.Make (struct
  type t = Obj.t

  let equal = ( == )
  let hash = Hashtbl.hash
end)

let first seen node =
  let key = Obj.repr node in
  if Seen.mem seen key then false
  else (
    Seen.add seen key ();
    true)

let rec form_cells seen (form : Form.t) =
  if first seen form then
    List.fold_left
      (fun total -> function Form.F child -> total + form_cells seen child | _ -> total)
      1 form.Form.args
  else 0

let rec value_cells seen (value : Value.t) =
  if not (first seen value) then 0
  else
    match value with
    | Value.VInt _ | Value.VReal _ -> 0
    | Value.VText text -> text_cells (String.length text)
    | Value.VHash _ -> 5
    | Value.VSecret secret -> text_cells (Secret.length secret)
    | Value.VCode form -> form_cells seen form
    | Value.VTuple items | Value.VCon { args = items; _ } ->
        List.fold_left
          (fun total item -> total + value_cells seen item)
          (1 + List.length items)
          items
    | _ -> 1

(** [fresh_cells value] counts every distinct node of [value]: code costs one cell per form node, as
    a spliced quote does, text one plus one per started 8 bytes, a structure one plus its fields. *)
let fresh_cells value = value_cells (Seen.create 64) value

(* the nodes of [shared] values are already paid for: mark them without charging *)
let fresh_cells_over ~shared value =
  let seen = Seen.create 64 in
  List.iter (fun input -> ignore (value_cells seen input)) shared;
  value_cells seen value

(** [cells kind ~args result] is what [result] adds on return, for a native of class [kind] called
    with [args]. *)
let cells kind ~args result =
  match kind with
  | Sized | Rendered -> 0
  | Fresh | Rendering -> fresh_cells result
  | Shared_text -> ( match result with Value.VCon { args = [ _ ]; _ } -> 3 | _ -> 1)
  | Posterior -> fresh_cells_over ~shared:args result

(** How a root handler's result is charged when it returns (RT.2 slice 2d). *)
type root =
  | New_nodes
      (** every node of the result not already in its arguments is new, charged on return. A handler
          that reads external text first checks its size against the remaining allowance
          ([Eval.admit_text]), so no read is unbounded under a budget *)
  | Evaluated
      (** the result was built, and charged, by the evaluator (the handler runs code), or the
          handler charged what it built itself *)

(** [root_cells root ~args result] is what a root handler's [result] adds on return. *)
let root_cells root ~args result =
  match root with New_nodes -> fresh_cells_over ~shared:args result | Evaluated -> 0

(** [form_tree_nodes ~limit form] counts the nodes of [form] as a tree, a shared subform once per
    occurrence (the kernel expression built from it does not share), stopping once the count passes
    [limit]: the result is at most [limit + 1]. *)
let form_tree_nodes ~limit (form : Form.t) =
  let rec walk count (form : Form.t) =
    if count > limit then count
    else
      List.fold_left
        (fun count -> function Form.F child -> walk count child | _ -> count)
        (count + 1) form.Form.args
  in
  walk 0 form

(** [renders kind] holds for classes whose renderings are counted while they are built. *)
let renders = function
  | Rendered | Rendering | Posterior -> true
  | Fresh | Sized | Shared_text -> false

let rendered = [ "code.diff"; "code.render"; "debug.inspect" ]
let rendering = [ "code.hash"; "pmf" ]

let sized =
  [
    "code.form";
    "code.un-form";
    "dist.sample-lw";
    "dist.sample-lw-weights-v1";
    "support";
    "text.concat";
    "text.join";
    "text.join-variadic-v1";
    "text.slice";
    "text.split";
    "text.trim";
  ]

let fresh =
  [
    "add";
    "add-real";
    "async.scope-v0";
    "code.eq?";
    "code.of-hash";
    "code.of-int";
    "code.of-real";
    "code.of-text";
    "code.to-int";
    "div";
    "div-real";
    "eq";
    "governance.effect-order-key";
    "governance.fresh-audit-run-id";
    "governance.require-audit-run-id";
    "governance.resolve-operation-id";
    "hash.parse";
    "hash.to-text";
    "instance.fresh-v0";
    "instance.same-v0";
    "int-compare";
    "lt";
    "lt-real";
    "mod";
    "mul";
    "mul-real";
    "real.from-int";
    "real.gt?";
    "real.gte?";
    "real.lte?";
    "sub";
    "sub-real";
    "text-compare";
    "text.ascii-digit-value";
    "text.ascii-digit?";
    "text.ascii-letter?";
    "text.ascii-space?";
    "text.codepoint";
    "text.contains?";
    "text.empty?";
    "text.from-int";
    "text.from-real";
    "text.from-real-fixed";
    "text.length";
    "text.to-int";
    "text.to-real";
  ]

let table : (string, kind) Hashtbl.t =
  let table = Hashtbl.create 97 in
  let classify kind names = List.iter (fun name -> Hashtbl.replace table name kind) names in
  classify Fresh fresh;
  classify Sized sized;
  classify Rendered rendered;
  classify Rendering rendering;
  classify Shared_text [ "code.to-text" ];
  classify Posterior
    [ "posterior.project-exact-v1"; "posterior.run-exact-v1"; "posterior.sample-evidence-v1" ];
  table

(** [classify name] is the class of the trusted native registered as [name], if any. *)
let classify name = Hashtbl.find_opt table name

(** [kind name] is [name]'s class, counting an unclassified native's whole result as new. *)
let kind name = Option.value (classify name) ~default:Fresh
