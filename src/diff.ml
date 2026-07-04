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
  | Changed of { divergences : divergence list; dependents : string list }
  | Added
  | Removed

type report = (string * entry) list
(** keyed by definition name (new side's names first, then removals) *)

(* Smallest disagreeing subtrees between two forms, with head-paths. If heads or arities
   differ the whole node is the divergence; otherwise recurse into exactly the differing
   arguments. *)
let rec form_divergences ~path (fa : Form.t) (fb : Form.t) : divergence list =
  if Form.equal_ignoring_meta fa fb then []
  else if fa.Form.head <> fb.Form.head || List.length fa.Form.args <> List.length fb.Form.args then
    [ { path; a = Printer.inline_form fa; b = Printer.inline_form fb } ]
  else
    List.concat
      (List.mapi
         (fun i (arg_a, arg_b) ->
           let path = Printf.sprintf "%s/%s[%d]" path fa.Form.head i in
           match (arg_a, arg_b) with
           | Form.F ga, Form.F gb -> form_divergences ~path ga gb
           | a, b ->
               if Form.equal_arg a b then []
               else [ { path; a = Printer.scalar_to_string a; b = Printer.scalar_to_string b } ])
         (List.combine fa.Form.args fb.Form.args))

(* All (name, hash) bindings of a store, plus a way to fetch a decl's printed form. *)
let store_names (s : Store.t) : (string * Hash.t) list =
  List.map (fun (n, { Resolve.hash; _ }) -> (n, hash)) (Store.names s)

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
        (fun (n, bh) ->
          match Store.locate store bh with
          | Ok { Store.decl_hash; _ } when List.exists (Hash.equal decl_hash) decl_hashes -> Some n
          | _ -> None)
        (store_names store)
      |> List.sort_uniq String.compare

(** [diff ~old_side ~new_side] classifies every name across two stores. *)
let diff ~(old_side : Store.t) ~(new_side : Store.t) : report =
  let a = store_names old_side and b = store_names new_side in
  let hash_of_name side n = List.assoc_opt n side in
  let names_of_hash side h =
    List.filter_map (fun (n, h') -> if Hash.equal h h' then Some n else None) side
  in
  let new_entries =
    List.filter_map
      (fun (n, hb) ->
        match hash_of_name a n with
        | Some ha when Hash.equal ha hb -> Some (n, Identical)
        | Some ha ->
            let divergences =
              match (decl_form old_side ha, decl_form new_side hb) with
              | Some fa, Some fb -> form_divergences ~path:n fa fb
              | _ -> []
            in
            Some (n, Changed { divergences; dependents = dependents_names old_side ha })
        | None -> (
            (* same content under a different old name? that's a rename *)
            match names_of_hash a hb with
            | old_name :: _ when hash_of_name b old_name = None -> Some (n, Renamed old_name)
            | _ -> Some (n, Added)))
      b
  in
  let removed =
    List.filter_map
      (fun (n, ha) ->
        if hash_of_name b n <> None then None
        else if
          (* accounted as a rename above? *)
          List.exists (fun (n', hb) -> Hash.equal ha hb && hash_of_name a n' = None) b
        then None
        else Some (n, Removed))
      a
  in
  new_entries @ removed

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
        | Changed { divergences; dependents } ->
            Printf.sprintf "changed  %s" n
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
