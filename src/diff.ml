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

(** The part of a definition a divergence falls in, for the readable report. [Signature] and [Body]
    are a top-level binding's annotation and value; [Clause n] is the [n]th (1-based) clause of the
    innermost [match] inside a body; [Member] is one operation of an effect or constructor of a
    type. *)
type region =
  | Authority
  | Signature
  | Body
  | Clause of int
  | Operation
  | Member of string * string  (** an effect's [op] or a type's [con], by kind and name *)
  | Definition

type authority_effect = { short : string; full : string }
(** One effect of an authority row: [short] is the blessed display name, or [name#<12 hex>] for an
    unblessed identity; [full] is {!Effect_registry.render_resolved}. *)

(** What the readable report renders for a divergence. [Subtrees] are the two smallest enclosing
    kernel forms (a differing scalar leaf is shown through its parent form); [Authority] the two
    resolved rows; [Summary] reuses [a]/[b]. *)
type detail =
  | Subtrees of Form.t * Form.t
  | Authority_rows of
      (authority_effect list * string option) * (authority_effect list * string option)
  | Summary

type divergence = { path : string; a : string; b : string; region : region; detail : detail }
(** [path], [a] and [b] are the structural report ([--paths]); [region] and [detail] feed the
    readable one. *)

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

(** [authority_row form] extracts a fully resolved kernel row for review rendering. Named or
    malformed rows return [None] and retain the ordinary structural-diff path. *)
let authority_row (form : Form.t) =
  if form.Form.head <> "row" then None
  else
    let rec collect effects = function
      | [] -> Some (List.rev effects, None)
      | [ Form.Sym tail ] -> Some (List.rev effects, Some tail)
      | Form.F { Form.head = "eref"; args = [ Form.Hash hash ]; _ } :: rest ->
          collect (hash :: effects) rest
      | _ -> None
    in
    collect [] form.Form.args

(** [render_authority_row ~effect_name_of row] renders resolved identities through the blessed
    registry, using [effect_name_of] only as the unblessed package/name hint. *)
let render_authority_row ~effect_name_of (effects, tail) =
  let effects =
    effects
    |> List.map (fun identity ->
        Alloc_meter.rendered_piece
          (Effect_registry.render_resolved ~name_hint:(effect_name_of identity) identity))
    |> List.sort String.compare
  in
  let items = match tail with Some tail -> effects @ [ "| " ^ tail ] | None -> effects in
  "authority {" ^ String.concat ", " items ^ "}"

(** Internal traversal. Only the row child of a typed [tarrow] is authority. [raw_context] becomes
    true at a quote boundary and prevents even type-shaped quoted data from receiving authority
    semantics. *)
let authority_effects ~effect_name_of (effects, tail) =
  let describe identity =
    let full =
      Alloc_meter.rendered_piece
        (Effect_registry.render_resolved ~name_hint:(effect_name_of identity) identity)
    in
    let short =
      match Effect_registry.find_canonical identity with
      | Some metadata -> metadata.Effect_registry.display_name
      | None -> effect_name_of identity ^ "#" ^ String.sub (Hash.to_hex identity) 0 12
    in
    { short; full }
  in
  (List.sort (fun x y -> String.compare x.short y.short) (List.map describe effects), tail)

(** [child_region region head i child] is the region of argument [i] (the form [child]) of a [head]
    form in [region]. *)
let child_region region head i (child : Form.t) =
  match (region, head, i, child.Form.head, child.Form.args) with
  | Definition, "binding", 1, _, _ -> Signature
  | Definition, "binding", 2, _, _ -> Body
  | (Body | Clause _), "match", i, _, _ when i >= 1 -> Clause i
  | Definition, ("defeffect" | "deftype"), _, (("op" | "con") as kind), Form.Sym name :: _ ->
      Member (kind, name)
  | region, _, _, _, _ -> region

let rec form_divergences_in ~syntax ~effect_name_of ~authority_context ~raw_context ~region ~path
    (fa : Form.t) (fb : Form.t) : divergence list =
  if Form.equal_ignoring_meta fa fb then []
  else if
    authority_context
    &&
    match (authority_row fa, authority_row fb) with
    | Some old_row, Some new_row -> old_row <> new_row
    | _ -> false
  then
    let old_row, new_row =
      match (authority_row fa, authority_row fb) with
      | Some old_row, Some new_row -> (old_row, new_row)
      | _ -> assert false
    in
    [
      {
        path = Alloc_meter.rendered_piece path;
        a = Alloc_meter.rendered_piece (render_authority_row ~effect_name_of old_row);
        b = Alloc_meter.rendered_piece (render_authority_row ~effect_name_of new_row);
        region = Authority;
        detail =
          Authority_rows
            (authority_effects ~effect_name_of old_row, authority_effects ~effect_name_of new_row);
      };
    ]
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
        path = Alloc_meter.rendered_piece path;
        a = Alloc_meter.rendered_piece (Printf.sprintf "op `%s`: %s" name (show a_mode));
        b =
          Alloc_meter.rendered_piece
            (Printf.sprintf "op `%s`: %s%s" name (show b_mode)
               (match (a_mode, b_mode) with
               | Kernel.Multi, Kernel.Once -> " (handlers may no longer resume repeatedly)"
               | _ -> ""));
        region = Operation;
        detail = Summary;
      };
    ]
  else if fa.Form.head <> fb.Form.head || List.length fa.Form.args <> List.length fb.Form.args then
    [
      {
        path = Alloc_meter.rendered_piece path;
        a = render_form syntax fa;
        b = render_form syntax fb;
        region;
        detail = Subtrees (fa, fb);
      };
    ]
  else
    List.concat
      (List.mapi
         (fun i (arg_a, arg_b) ->
           let path = Printf.sprintf "%s/%s[%d]" path fa.Form.head i in
           match (arg_a, arg_b) with
           | Form.F ga, Form.F gb ->
               let region = child_region region fa.Form.head i ga in
               let child_raw_context =
                 raw_context || fa.Form.head = "quote" || fb.Form.head = "quote"
               in
               let child_authority_context =
                 (not child_raw_context) && fa.Form.head = "tarrow" && fb.Form.head = "tarrow"
                 && i = 1
               in
               form_divergences_in ~syntax ~effect_name_of
                 ~authority_context:child_authority_context ~raw_context:child_raw_context ~region
                 ~path ga gb
           | a, b ->
               if Form.equal_arg a b then []
               else
                 (* a mixed form/scalar position renders each side by its own
                    shape; scalar_to_string on a form raised (task 73 review) *)
                 let render = function
                   | Form.F g -> Printer.inline_form g
                   | scalar -> Alloc_meter.rendered_piece (Printer.scalar_to_string scalar)
                 in
                 [
                   {
                     path = Alloc_meter.rendered_piece path;
                     a = render a;
                     b = render b;
                     region;
                     detail = Subtrees (fa, fb);
                   };
                 ])
         (List.combine fa.Form.args fb.Form.args))

(** [form_divergences ~path old new] finds the smallest disagreeing subtrees with head paths. If
    heads or arities differ, the whole node is the divergence; otherwise it recurses into exactly
    the differing arguments. Resolved type-level effect rows receive authority review metadata,
    while rows below [quote] remain ordinary data. [effect_name_of] supplies only the fallback hint
    for identities absent from the registry. *)
let form_divergences ?(syntax = Bootstrap) ?(effect_name_of = fun _ -> "unregistered") ~path fa fb =
  form_divergences_in ~syntax ~effect_name_of ~authority_context:false ~raw_context:false
    ~region:Definition ~path fa fb

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
  let effect_name_of hash =
    let find side =
      List.find_map
        (fun ((name, kind), candidate) ->
          if kind = Resolve.KEffect && Hash.equal hash candidate then Some name else None)
        side.bindings
    in
    match find old_side with
    | Some name -> name
    | None -> Option.value ~default:"unregistered" (find new_side)
  in
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
              | Some fa, Some fb -> form_divergences ~syntax ~effect_name_of ~path:n fa fb
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
                  (fun { path; a; b; _ } -> Printf.sprintf "  at %s:\n    - %s\n    + %s" path a b)
                  divergences
               @
               match dependents with
               | [] -> []
               | ds -> [ Printf.sprintf "  dependents: %s" (String.concat ", " ds) ]))
      r
  in
  if lines = [] then None else Some (String.concat "\n" lines)

(* --- readable report (DX.2) --- *)

(** [rename_hashes rename text] replaces every [#<64 hex>] in [text], with its optional [:kind] tag,
    by [rename kind hex] ([kind] is [None] when untagged). *)
let rename_hashes rename text =
  let n = String.length text in
  let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  let is_word c = (c >= 'a' && c <= 'z') || c = '_' in
  let buffer = Buffer.create n in
  let rec go i =
    if i >= n then ()
    else if
      text.[i] = '#'
      && i + 64 < n
      && (let rec all j = j > 64 || (is_hex text.[i + j] && all (j + 1)) in
          all 1)
      && (i + 65 >= n || not (is_hex text.[i + 65]))
    then (
      let hex = String.sub text (i + 1) 64 in
      let j = i + 65 in
      let kind, j =
        if j < n && text.[j] = ':' then
          let rec word k = if k < n && is_word text.[k] then word (k + 1) else k in
          let k = word (j + 1) in
          if k > j + 1 then (Some (String.sub text (j + 1) (k - j - 1)), k) else (None, j)
        else (None, j)
      in
      Buffer.add_string buffer (rename kind hex);
      go j)
    else (
      Buffer.add_char buffer text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buffer

(** [shorten_hashes text] abbreviates every full hash to [#] and its first 12 hex digits. *)
let shorten_hashes text = rename_hashes (fun _ hex -> "#" ^ String.sub hex 0 12) text

(** [side_lookup side] names a hash by the side's own bindings first, then by any name its store
    binds (the prelude, for a source file), for the surface printer. *)
let side_lookup side : Surface_print.lookup =
  let table = Hashtbl.create 64 in
  let add ((name, kind), hash) =
    let key = (kind, Hash.to_hex hash) in
    if not (Hashtbl.mem table key) then Hashtbl.add table key name
  in
  List.iter add side.bindings;
  List.iter add (store_names side.store);
  fun kind hash ->
    let kind =
      match kind with
      | Surface_name.Term -> Some Resolve.KTerm
      | Surface_name.Op -> Some Resolve.KOp
      | Surface_name.Type -> Some Resolve.KType
      | Surface_name.Con -> Some Resolve.KCon
      | Surface_name.Effect -> Some Resolve.KEffect
      | Surface_name.Tvar | Surface_name.Rvar -> None
    in
    Option.bind kind (fun kind -> Hashtbl.find_opt table (kind, Hash.to_hex hash))

(** [readable_form lookup form] renders [form] in surface syntax with references named through
    [lookup], falling back to bootstrap notation; unnamed hashes are abbreviated. *)
let readable_form lookup form =
  let text =
    match Surface_print.print_fragment ~lookup form with
    | Ok text when not (String.equal text "") -> text
    | Ok _ | Error _ -> Printer.inline_form form
  in
  shorten_hashes text

let region_label = function
  | Authority -> "authority"
  | Signature -> "signature"
  | Body -> "body"
  | Clause n -> Printf.sprintf "clause %d" n
  | Operation -> "operation"
  | Member (kind, name) -> kind ^ " " ^ name
  | Definition -> "definition"

(** [change_lines label old_text new_text] puts short single-line sides on one line and otherwise
    stacks them as [-]/[+] lines, indenting continuation lines. *)
let change_lines label old_text new_text =
  let short text = String.length text <= 40 && not (String.contains text '\n') in
  if short old_text && short new_text then
    [ Printf.sprintf "  %-9s  %s  ->  %s" label old_text new_text ]
  else
    let side mark text =
      Printf.sprintf "    %s %s" mark (String.concat "\n      " (String.split_on_char '\n' text))
    in
    [ Printf.sprintf "  %s" label; side "-" old_text; side "+" new_text ]

(** [identified_form lookup form] renders [form] with each reference as [name#<12 hex>] (or
    [#<12 hex>] when unnamed), for two sides that read the same by name but differ in identity. *)
let identified_form (lookup : Surface_print.lookup) form =
  let text =
    match Surface_print.print_fragment form with
    | Ok text when not (String.equal text "") -> text
    | Ok _ | Error _ -> Printer.inline_form form
  in
  let kind_of_tag = function
    | Some "term" -> Some Surface_name.Term
    | Some "op" -> Some Surface_name.Op
    | Some "type" -> Some Surface_name.Type
    | Some "con" -> Some Surface_name.Con
    | Some "effect" -> Some Surface_name.Effect
    | _ -> None
  in
  rename_hashes
    (fun tag hex ->
      let name =
        Option.bind (kind_of_tag tag) (fun kind ->
            Option.bind (Hash.of_hex hex) (fun hash ->
                Option.map (Surface_name.render kind) (lookup kind hash)))
      in
      Option.value ~default:"" name ^ "#" ^ String.sub hex 0 12)
    text

let divergence_lines ~old_lookup ~new_lookup { a; b; region; detail; _ } =
  match detail with
  | Subtrees (fa, fb) ->
      let old_text = readable_form old_lookup fa and new_text = readable_form new_lookup fb in
      if String.equal old_text new_text then
        change_lines (region_label region) (identified_form old_lookup fa)
          (identified_form new_lookup fb)
      else change_lines (region_label region) old_text new_text
  | Summary -> change_lines (region_label region) (shorten_hashes a) (shorten_hashes b)
  | Authority_rows ((old_effects, old_tail), (new_effects, new_tail)) ->
      let row (effects, tail) =
        let items = List.map (fun e -> e.short) effects in
        let items = match tail with Some tail -> items @ [ "| " ^ tail ] | None -> items in
        "{" ^ String.concat ", " items ^ "}"
      in
      let missing_from others e = not (List.exists (fun o -> String.equal o.full e.full) others) in
      let added = List.filter (missing_from old_effects) new_effects in
      let removed = List.filter (missing_from new_effects) old_effects in
      Printf.sprintf "  %-9s  %s  ->  %s" (region_label Authority)
        (row (old_effects, old_tail))
        (row (new_effects, new_tail))
      :: (List.map (fun e -> "    - " ^ e.full) removed
         @ List.map (fun e -> "    + " ^ e.full) added)

(** [added_signature side name] is the annotated type of a term [name] in [side], when it has one.
*)
let added_signature side name =
  match List.assoc_opt (name, Resolve.KTerm) side.bindings with
  | None -> None
  | Some hash -> (
      match decl_form side hash with
      | None -> None
      | Some decl ->
          let rec bindings (form : Form.t) =
            if form.Form.head = "binding" then [ form ]
            else
              List.concat_map (function Form.F child -> bindings child | _ -> []) form.Form.args
          in
          List.find_map
            (fun (binding : Form.t) ->
              match binding.Form.args with
              | [ Form.Sym bname; Form.F { Form.head = "group"; args = [ Form.F ty ]; _ }; _ ]
                when String.equal bname name ->
                  Some (readable_form (side_lookup side) ty)
              | _ -> None)
            (bindings decl))

(** [render_readable ~old_side ~new_side report] renders [report] for people: regions instead of
    kernel paths, both sides in surface syntax with references named on their own side (an unnamed
    reference shows [#] and 12 hex digits), and blessed effects by display name with their review
    meaning. Returns [None] when there are no semantic changes. *)
let render_readable ~old_side ~new_side (r : report) : string option =
  let old_lookup = side_lookup old_side and new_lookup = side_lookup new_side in
  let rec dedupe = function
    | x :: (y :: _ as rest) when x = y -> dedupe rest
    | x :: rest -> x :: dedupe rest
    | [] -> []
  in
  let lines =
    List.concat_map
      (fun (n, e) ->
        match e with
        | Identical -> []
        | Renamed old_name -> [ Printf.sprintf "renamed  %s -> %s" old_name n ]
        | Added -> (
            match added_signature new_side n with
            | Some signature -> [ Printf.sprintf "added    %s : %s" n signature ]
            | None -> [ Printf.sprintf "added    %s" n ])
        | Removed -> [ Printf.sprintf "removed  %s" n ]
        | Changed { divergences; dependents; origin } -> (
            Printf.sprintf "changed  %s%s" n
              (match origin with Some tag -> " [" ^ tag ^ "]" | None -> "")
            :: (dedupe (List.map (divergence_lines ~old_lookup ~new_lookup) divergences)
               |> List.concat)
            @
            match dependents with
            | [] -> []
            | ds -> [ Printf.sprintf "  dependents: %s" (String.concat ", " ds) ]))
      r
  in
  if lines = [] then None else Some (String.concat "\n" lines)
