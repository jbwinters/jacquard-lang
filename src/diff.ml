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

(* Smallest disagreeing subtrees between two forms, with head-paths. If heads or arities
   differ the whole node is the divergence; otherwise recurse into exactly the differing
   arguments. *)
let rec form_divergences ?(syntax = Bootstrap) ~path (fa : Form.t) (fb : Form.t) : divergence list =
  if Form.equal_ignoring_meta fa fb then []
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

let decl_form store (h : Hash.t) : Form.t option =
  match Store.locate store h with
  | Ok { Store.decl; _ } -> Some (Kernel.decl_to_form decl)
  | Error _ -> None

let dependents_names store (h : Hash.t) : string list =
  match Store.dependents store h with
  | Error _ -> []
  | Ok decl_hashes ->
      (* report the names bound to any hash owned by a dependent declaration *)
      List.filter_map
        (fun ((n, _), bh) ->
          match Store.locate store bh with
          | Ok { Store.decl_hash; _ } when List.exists (Hash.equal decl_hash) decl_hashes -> Some n
          | _ -> None)
        (store_names store)
      |> List.sort_uniq String.compare

(** [diff_with_syntax ~syntax ~old_side ~new_side] classifies every (name, kind) binding across two
    stores; report keys stay plain names. *)
let diff_with_syntax ~syntax ~(old_side : Store.t) ~(new_side : Store.t) : report =
  let a = store_names old_side and b = store_names new_side in
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
                    origin = Store.origin new_side hb;
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
