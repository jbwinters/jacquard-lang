(** The semantic differ (plan W5.2): definitions compare by content hash, so a rename is a rename, a
    reformat is nothing, and a real edit localizes to the smallest disagreeing subtrees.

    Classification per named definition, comparing an old side A to a new side B:
    - [Identical]: same name, same hash.
    - [Renamed]: same hash reachable under a different name (reported once, on the new name).
    - [Changed]: same name, different hash; carries the smallest disagreeing subtrees (with paths)
      plus the dependents of the old definition from the store's reverse index.
    - [Added] / [Removed]: name only on one side (and its hash not accounted a rename).

    "Meta-only" edits (formatting, comments, spans) hash identically by the metadata law, so they
    classify as [Identical]; the file-level entry point reports "no semantic changes" for such
    diffs. *)

type divergence = { path : string; a : string; b : string }

type entry =
  | Identical
  | Renamed of string  (** the old name *)
  | Changed of {
      divergences : divergence list;
      dependents : string list;
      origin : string option;  (** the NEW side's provenance tag, when stamped (PV.1) *)
    }
  | Added
  | Removed

type report = (string * entry) list
(** keyed by definition name (new side's names first, then removals) *)

(** Subtree notation used in divergence payloads. Classification and paths are notation-independent.
*)
type render_syntax = Bootstrap | Surface

(** [render_form syntax form] renders a complete kernel subtree in the selected notation. Surface
    rendering falls back to bootstrap for auxiliary or arbitrary triple forms. *)
let render_form syntax form =
  match syntax with
  | Bootstrap -> Printer.inline_form form
  | Surface -> (
      match Surface_print.print_fragment form with
      | Ok text when not (String.equal text "") -> text
      | Ok _ | Error _ -> Printer.inline_form form)

let operation_mode (form : Form.t) =
  if form.Form.head <> "op" then None
  else
    match form.Form.args with
    | Form.Sym name :: [ Form.F _; Form.F _ ] -> Some (name, Kernel.Multi)
    | Form.Sym name :: Form.Sym "once" :: [ Form.F _; Form.F _ ] -> Some (name, Kernel.Once)
    | _ -> None

(* Smallest disagreeing subtrees between two forms, with head-paths. If heads or arities
   differ the whole node is the divergence; otherwise recurse into exactly the differing
   arguments. *)
let rec form_divergences ?(syntax = Bootstrap) ~path (fa : Form.t) (fb : Form.t) : divergence list =
  if Form.equal_ignoring_meta fa fb then []
  else if
    match (operation_mode fa, operation_mode fb) with
    | Some (a_name, Kernel.Multi), Some (b_name, Kernel.Once) when a_name = b_name -> true
    | Some (a_name, Kernel.Once), Some (b_name, Kernel.Multi) when a_name = b_name -> true
    | _ -> false
  then
    let name, a_mode, b_mode =
      match (operation_mode fa, operation_mode fb) with
      | Some (name, a_mode), Some (_, b_mode) -> (name, a_mode, b_mode)
      | _ -> assert false
    in
    let show = function Kernel.Multi -> "multi" | Kernel.Once -> "once" in
    [
      {
        path;
        a = Printf.sprintf "op `%s`: %s" name (show a_mode);
        b =
          Printf.sprintf "op `%s`: %s%s" name (show b_mode)
            (match (a_mode, b_mode) with
            | Kernel.Multi, Kernel.Once -> " (handlers may no longer resume repeatedly)"
            | _ -> "");
      };
    ]
  else if fa.Form.head <> fb.Form.head || List.length fa.Form.args <> List.length fb.Form.args then
    [ { path; a = render_form syntax fa; b = render_form syntax fb } ]
  else
    List.concat
      (List.mapi
         (fun i (arg_a, arg_b) ->
           let path = Printf.sprintf "%s/%s[%d]" path fa.Form.head i in
           match (arg_a, arg_b) with
           | Form.F ga, Form.F gb -> form_divergences ~syntax ~path ga gb
           | a, b ->
               if Form.equal_arg a b then []
               else
                 (* a mixed form/scalar position renders each side by its own
                    shape; scalar_to_string on a form raised (task 73 review) *)
                 let render = function
                   | Form.F g -> Printer.inline_form g
                   | scalar -> Printer.scalar_to_string scalar
                 in
                 [ { path; a = render a; b = render b } ])
         (List.combine fa.Form.args fb.Form.args))

(* All ((name, kind), hash) bindings of a store, plus a way to fetch a decl's printed form.
   Keys carry the kind: a name bound to several kinds (an effect and its op, say) must be
   compared binding-by-binding, not against whichever hash ranks first. *)
let store_names (s : Store.t) : ((string * Resolve.nkind) * Hash.t) list =
  List.map (fun (n, { Resolve.hash; kind }) -> ((n, kind), hash)) (Store.names s)

type side = { store : Store.t; bindings : ((string * Resolve.nkind) * Hash.t) list }
(** A diff operand's object store and the exact name bindings exposed as comparison roots. *)

(** [store_side store] exposes every current name binding in [store] to the differ. *)
let store_side store = { store; bindings = store_names store }

(** [source_side store declarations] exposes only the final name bindings introduced by
    [declarations]. The complete [store], including any prelude used to resolve those declarations,
    remains available for object lookup and dependency analysis. *)
let source_side store declarations =
  let source_decl_bindings (decl : Kernel.decl) (hashes : Canon.decl_hashes) =
    let with_kind kind = List.map (fun (name, hash) -> ((name, kind), hash)) in
    match decl.Kernel.it with
    | Kernel.DefTerm _ -> with_kind Resolve.KTerm hashes.Canon.named
    | Kernel.DefType _ -> (
        match hashes.Canon.named with
        | [] -> []
        | head :: constructors ->
            with_kind Resolve.KType [ head ] @ with_kind Resolve.KCon constructors)
    | Kernel.DefEffect _ -> (
        match hashes.Canon.named with
        | [] -> []
        | head :: operations ->
            with_kind Resolve.KEffect [ head ] @ with_kind Resolve.KOp operations)
  in
  let kind_rank = function
    | Resolve.KTerm -> 0
    | Resolve.KCon -> 1
    | Resolve.KOp -> 2
    | Resolve.KType -> 3
    | Resolve.KEffect -> 4
  in
  let sort_bindings bindings =
    List.sort
      (fun ((name_a, kind_a), _) ((name_b, kind_b), _) ->
        match String.compare name_a name_b with
        | 0 -> compare (kind_rank kind_a) (kind_rank kind_b)
        | order -> order)
      bindings
  in
  let add_declaration bindings (decl, hashes) =
    let introduced = source_decl_bindings decl hashes in
    let replaced ((name, kind), _) =
      List.exists
        (fun ((introduced_name, introduced_kind), _) ->
          name = introduced_name && kind = introduced_kind)
        introduced
    in
    introduced @ List.filter (fun binding -> not (replaced binding)) bindings
  in
  { store; bindings = List.fold_left add_declaration [] declarations |> sort_bindings }

(** [decl_form side hash] returns the owning declaration as a form, or [None] when [hash] is not
    available in the side's store. *)
let decl_form side (h : Hash.t) : Form.t option =
  match Store.locate side.store h with
  | Ok { Store.decl; _ } -> Some (Kernel.decl_to_form decl)
  | Error _ -> None

(** [dependents_names side hash] returns sorted, deduplicated names exposed by [side] whose
    declarations directly depend on [hash]. Store lookup failures produce an empty list. *)
let dependents_names side (h : Hash.t) : string list =
  match Store.dependents side.store h with
  | Error _ -> []
  | Ok decl_hashes ->
      (* report the names bound to any hash owned by a dependent declaration *)
      List.filter_map
        (fun ((n, _), bh) ->
          match Store.locate side.store bh with
          | Ok { Store.decl_hash; _ } when List.exists (Hash.equal decl_hash) decl_hashes -> Some n
          | _ -> None)
        side.bindings
      |> List.sort_uniq String.compare

(** [diff_sides_with_syntax ~syntax ~old_side ~new_side] classifies every exposed (name, kind)
    binding across two sides; report keys stay plain names. *)
let diff_sides_with_syntax ~syntax ~(old_side : side) ~(new_side : side) : report =
  let a = old_side.bindings and b = new_side.bindings in
  let hash_of_key side key = List.assoc_opt key side in
  (* rename detection stays within a kind: store renames never change a binding's kind *)
  let keys_of_hash side kind h =
    List.filter_map
      (fun ((n, k), h') -> if k = kind && Hash.equal h h' then Some (n, k) else None)
      side
  in
  let new_entries =
    List.filter_map
      (fun (((n, kind) as key), hb) ->
        match hash_of_key a key with
        | Some ha when Hash.equal ha hb -> Some (n, Identical)
        | Some ha ->
            let divergences =
              match (decl_form old_side ha, decl_form new_side hb) with
              | Some fa, Some fb -> form_divergences ~syntax ~path:n fa fb
              | _ -> []
            in
            Some
              ( n,
                Changed
                  {
                    divergences;
                    dependents = dependents_names old_side ha;
                    origin = Store.origin new_side.store hb;
                  } )
        | None -> (
            (* same content under a different old name? that's a rename *)
            match keys_of_hash a kind hb with
            | old_key :: _ when hash_of_key b old_key = None -> Some (n, Renamed (fst old_key))
            | _ -> Some (n, Added)))
      b
  in
  let removed =
    List.filter_map
      (fun (((n, kind) as key), ha) ->
        if hash_of_key b key <> None then None
        else if
          (* accounted as a rename above? *)
          List.exists
            (fun (((_, k) as key'), hb) ->
              k = kind && Hash.equal ha hb && hash_of_key a key' = None)
            b
        then None
        else Some (n, Removed))
      a
  in
  new_entries @ removed

(** [diff_with_syntax ~syntax ~old_side ~new_side] compares every binding in two stores. *)
let diff_with_syntax ~syntax ~(old_side : Store.t) ~(new_side : Store.t) : report =
  diff_sides_with_syntax ~syntax ~old_side:(store_side old_side) ~new_side:(store_side new_side)

(** [diff] preserves the established bootstrap-rendered report contract. *)
let diff ~old_side ~new_side = diff_with_syntax ~syntax:Bootstrap ~old_side ~new_side

(** Render a report for the CLI: quiet about [Identical], one line per event, divergences indented
    with their paths. Returns [None] when there are no semantic changes. *)
let render (r : report) : string option =
  let lines =
    List.concat_map
      (fun (n, e) ->
        match e with
        | Identical -> []
        | Renamed old_name -> [ Printf.sprintf "renamed  %s -> %s" old_name n ]
        | Added -> [ Printf.sprintf "added    %s" n ]
        | Removed -> [ Printf.sprintf "removed  %s" n ]
        | Changed { divergences; dependents; origin } ->
            Printf.sprintf "changed  %s%s" n
              (match origin with Some tag -> " [" ^ tag ^ "]" | None -> "")
            :: (List.map
                  (fun { path; a; b } -> Printf.sprintf "  at %s:\n    - %s\n    + %s" path a b)
                  divergences
               @
               match dependents with
               | [] -> []
               | ds -> [ Printf.sprintf "  dependents: %s" (String.concat ", " ds) ]))
      r
  in
  if lines = [] then None else Some (String.concat "\n" lines)
