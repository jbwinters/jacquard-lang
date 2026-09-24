(* API.1 interface manifests; contracts in interface.mli. *)

let ( let* ) = Result.bind
let version = "interface-v1"

type visibility = Public | Hidden

type export = {
  name : string;
  kind : Resolve.nkind;
  hash : Hash.t;
  owner : Hash.t;
  signature : string option;
  mode : Kernel.op_mode option;
  arity : int option;
  labels : string option list option;
}

type t = {
  source : Hash.t option;
  prelude : (string * string) list option;
  exports : export list;
  hidden : (Hash.t * Hash.t) list;
}

let diagnostic ?span ~code cause =
  let summary, next_step =
    match code with
    | "E0613" ->
        ( "An interface manifest is malformed or unsupported.",
          "Regenerate the manifest with `jacquard interface emit` from the checked source." )
    | "E0614" ->
        ( "The store does not provide the interface the manifest describes.",
          "Install the manifest's declarations and companions, or regenerate the manifest." )
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown interface code " ^ code))
  in
  Diag.error ?span ~domain:Diag.Store ~code ~summary ~cause ~next_step ~contrast:None ()

let err ~code fmt = Printf.ksprintf (fun cause -> Error [ diagnostic ~code cause ]) fmt

let kind_rank = function
  | Resolve.KTerm -> 0
  | Resolve.KCon -> 1
  | Resolve.KOp -> 2
  | Resolve.KType -> 3
  | Resolve.KEffect -> 4

let compare_export left right =
  match String.compare left.name right.name with
  | 0 -> compare (kind_rank left.kind) (kind_rank right.kind)
  | order -> order

let find t name kind =
  List.find_opt (fun export -> String.equal export.name name && export.kind = kind) t.exports

let member_visibility t hash =
  if List.exists (fun export -> Hash.equal export.hash hash) t.exports then Some Public
  else if List.exists (fun (member, _) -> Hash.equal member hash) t.hidden then Some Hidden
  else None

(* --- producing --- *)

(* Signatures spell every identity as its full hash, so the text survives any public rename. *)
let render_signature scheme =
  let name_of hash = "#" ^ Hash.to_hex hash in
  Types.show_scheme ~name_of ~effect_name_of:name_of scheme

let of_side ?source checker (side : Diff.side) =
  let store = side.Diff.store in
  let rec build acc = function
    | [] -> Ok (List.sort compare_export acc)
    | ((name, kind), hash) :: rest ->
        let* { Store.decl; decl_hash = owner; role } = Store.locate store hash in
        let* signature, mode, arity, labels =
          match kind with
          | Resolve.KTerm ->
              let* scheme = Check.force_term checker hash in
              Ok
                ( Some (render_signature scheme),
                  None,
                  None,
                  List.assoc_opt hash store.Store.call_abis )
          | Resolve.KOp ->
              let* { Check.mode; scheme; _ } = Check.force_operation checker hash in
              Ok
                ( Some (render_signature scheme),
                  Some mode,
                  None,
                  List.assoc_opt hash store.Store.call_abis )
          | Resolve.KCon ->
              let* scheme = Check.force_constructor checker hash in
              let labels =
                match (decl.Kernel.it, role) with
                | Kernel.DefType { cons; _ }, Store.Constructor index -> (
                    match List.nth_opt cons index with
                    | Some constructor ->
                        Some
                          (List.map (fun (field : Kernel.field) -> field.label) constructor.fields)
                    | None -> None)
                | _ -> None
              in
              Ok (Some (render_signature scheme), None, None, labels)
          | Resolve.KType ->
              let arity =
                match decl.Kernel.it with
                | Kernel.DefType { tvars; _ } -> Some (List.length tvars)
                | _ -> None
              in
              Ok (None, None, arity, None)
          | Resolve.KEffect ->
              let arity =
                match decl.Kernel.it with
                | Kernel.DefEffect { evars; _ } -> Some (List.length evars)
                | _ -> None
              in
              Ok (None, None, arity, None)
        in
        build ({ name; kind; hash; owner; signature; mode; arity; labels } :: acc) rest
  in
  (* exports are what the store binds publicly; a member the declarations own but the store does
     not name (hidden, or a scheduler-private carrier) is recorded below as a hidden member *)
  let bound =
    List.filter
      (fun ((name, kind), hash) ->
        match Store.lookup_kind store name kind with
        | Some { Resolve.hash = current; _ } -> Hash.equal current hash
        | None -> false)
      side.Diff.bindings
  in
  let* exports = build [] bound in
  (* every derived identity of an exported declaration that is not itself exported *)
  let exported hash = List.exists (fun export -> Hash.equal export.hash hash) exports in
  let owners = List.sort_uniq Hash.compare (List.map (fun export -> export.owner) exports) in
  let rec collect acc = function
    | [] -> Ok (List.sort_uniq compare acc)
    | owner :: rest -> (
        let* { Store.decl; _ } = Store.locate store owner in
        match Canon.hash_top (Kernel.Decl decl) with
        | Error _ as error -> error
        | Ok { Canon.named; _ } ->
            let members =
              List.filter_map
                (fun (_, member) -> if exported member then None else Some (member, owner))
                named
            in
            collect (members @ acc) rest)
  in
  let* hidden = collect [] owners in
  Ok { source; prelude = Store.prelude_manifest store; exports; hidden }

(* --- serialization --- *)

let slot_form = function
  | None -> Form.form "slot" [ Form.Sym "positional" ]
  | Some label -> Form.form "slot" [ Form.Sym "named"; Form.Sym label ]

let export_form export =
  let optional = function Some form -> [ Form.F form ] | None -> [] in
  Form.form "export"
    ([
       Form.Sym (Store.kind_sym export.kind);
       Form.Sym export.name;
       Form.Hash export.hash;
       Form.F (Form.form "owner" [ Form.Hash export.owner ]);
     ]
    @ optional
        (Option.map
           (fun mode ->
             Form.form "mode"
               [ Form.Sym (match mode with Kernel.Once -> "once" | Kernel.Multi -> "multi") ])
           export.mode)
    @ optional (Option.map (fun arity -> Form.form "arity" [ Form.Int arity ]) export.arity)
    @ optional
        (Option.map
           (fun signature -> Form.form "signature" [ Form.Text signature ])
           export.signature)
    @ optional
        (Option.map
           (fun labels ->
             Form.form "labels" (List.map (fun slot -> Form.F (slot_form slot)) labels))
           export.labels))

(* The API proper: exports and hidden members. Source and prelude lines are provenance. *)
let api_forms t =
  List.map export_form t.exports
  @ List.map
      (fun (member, owner) ->
        Form.form "hidden" [ Form.Hash member; Form.F (Form.form "owner" [ Form.Hash owner ]) ])
      t.hidden

let forms t =
  Form.form version [ Form.F (Form.form "hash-algorithm" [ Form.Text Hash.algorithm ]) ]
  :: (match t.source with Some digest -> [ Form.form "source" [ Form.Hash digest ] ] | None -> [])
  @ (match t.prelude with
    | Some entries ->
        List.map
          (fun (file, digest) -> Form.form "prelude" [ Form.Text file; Form.Text digest ])
          entries
    | None -> [])
  @ api_forms t

let serialize t = Printer.print_all (forms t)
let identity t = Hash.of_string (Printer.print_all (api_forms t))

let parse ~file text =
  let* forms = Reader.parse_string ~file text in
  let malformed what = err ~code:"E0613" "%s: malformed %s in interface manifest" file what in
  let parse_slot = function
    | Form.F { Form.head = "slot"; args = [ Form.Sym "positional" ]; _ } -> Ok None
    | Form.F { Form.head = "slot"; args = [ Form.Sym "named"; Form.Sym label ]; _ }
      when Reader.valid_library_symbol label ->
        Ok (Some label)
    | _ -> malformed "label slot"
  in
  let rec parse_slots acc = function
    | [] -> Ok (List.rev acc)
    | slot :: rest ->
        let* slot = parse_slot slot in
        parse_slots (slot :: acc) rest
  in
  let rec parse_attributes export = function
    | [] -> Ok export
    | Form.F { Form.head = "mode"; args = [ Form.Sym "once" ]; _ } :: rest ->
        parse_attributes { export with mode = Some Kernel.Once } rest
    | Form.F { Form.head = "mode"; args = [ Form.Sym "multi" ]; _ } :: rest ->
        parse_attributes { export with mode = Some Kernel.Multi } rest
    | Form.F { Form.head = "arity"; args = [ Form.Int arity ]; _ } :: rest when arity >= 0 ->
        parse_attributes { export with arity = Some arity } rest
    | Form.F { Form.head = "signature"; args = [ Form.Text signature ]; _ } :: rest ->
        parse_attributes { export with signature = Some signature } rest
    | Form.F { Form.head = "labels"; args = slots; _ } :: rest ->
        let* labels = parse_slots [] slots in
        parse_attributes { export with labels = Some labels } rest
    | _ :: _ -> malformed "export attribute"
  in
  let rec go acc = function
    | [] -> Ok acc
    | { Form.head = "source"; args = [ Form.Hash digest ]; _ } :: rest ->
        go { acc with source = Some digest } rest
    | { Form.head = "prelude"; args = [ Form.Text file; Form.Text digest ]; _ } :: rest ->
        let entries = Option.value acc.prelude ~default:[] @ [ (file, digest) ] in
        go { acc with prelude = Some entries } rest
    | {
        Form.head = "export";
        args =
          Form.Sym kind
          :: Form.Sym name
          :: Form.Hash hash
          :: Form.F { Form.head = "owner"; args = [ Form.Hash owner ]; _ }
          :: attributes;
        _;
      }
      :: rest -> (
        match Store.kind_of_sym kind with
        | None -> malformed "export kind"
        | Some kind when not (Reader.valid_library_symbol name) ->
            ignore kind;
            malformed "export name"
        | Some kind ->
            let* export =
              parse_attributes
                {
                  name;
                  kind;
                  hash;
                  owner;
                  signature = None;
                  mode = None;
                  arity = None;
                  labels = None;
                }
                attributes
            in
            go { acc with exports = export :: acc.exports } rest)
    | {
        Form.head = "hidden";
        args = [ Form.Hash member; Form.F { Form.head = "owner"; args = [ Form.Hash owner ]; _ } ];
        _;
      }
      :: rest ->
        go { acc with hidden = (member, owner) :: acc.hidden } rest
    | form :: _ -> malformed (Printf.sprintf "`%s` form" form.Form.head)
  in
  match forms with
  | {
      Form.head;
      args = [ Form.F { Form.head = "hash-algorithm"; args = [ Form.Text algorithm ]; _ } ];
      _;
    }
    :: rest
    when String.equal head version ->
      if not (String.equal algorithm Hash.algorithm) then
        err ~code:"E0613" "%s: interface manifest uses hash algorithm %s, not %s" file algorithm
          Hash.algorithm
      else
        let* parsed = go { source = None; prelude = None; exports = []; hidden = [] } rest in
        Ok
          {
            parsed with
            exports = List.sort compare_export parsed.exports;
            hidden = List.sort_uniq compare parsed.hidden;
          }
  | { Form.head; _ } :: _ ->
      err ~code:"E0613" "%s: expected an `%s` header first, found `%s`" file version head
  | [] -> err ~code:"E0613" "%s: empty interface manifest" file

(* --- import validation --- *)

type mismatch =
  | Prelude_changed
  | Missing of export
  | Rebound of export * Hash.t
  | Companion_missing of export
  | Companion_mismatch of export * string option list
  | Declaration_mismatch of export * string
  | Exposed of Hash.t

let describe_labels labels =
  String.concat ", " (List.map (function None -> "positional" | Some label -> label ^ ":") labels)

let describe_mismatch = function
  | Prelude_changed -> "the store was loaded with a different prelude"
  | Missing export -> Printf.sprintf "%s %s is not bound" (Store.kind_sym export.kind) export.name
  | Rebound (export, found) ->
      Printf.sprintf "%s %s is bound to %s, not %s" (Store.kind_sym export.kind) export.name
        (Hash.to_hex found) (Hash.to_hex export.hash)
  | Companion_missing export ->
      Printf.sprintf "%s %s carries no call-abi-v1 companion for labels (%s)"
        (Store.kind_sym export.kind) export.name
        (describe_labels (Option.value export.labels ~default:[]))
  | Companion_mismatch (export, found) ->
      Printf.sprintf "%s %s carries labels (%s), not (%s)" (Store.kind_sym export.kind) export.name
        (describe_labels found)
        (describe_labels (Option.value export.labels ~default:[]))
  | Declaration_mismatch (export, what) ->
      Printf.sprintf "%s %s is declared with %s" (Store.kind_sym export.kind) export.name what
  | Exposed member -> Printf.sprintf "hidden member %s is publicly bound" (Hash.to_hex member)

(* The contracts a manifest records that are facts of the store's declaration rather than of its
   name index: the owner, an operation's mode, a type's or effect's arity, a constructor's labels. *)
let declaration_mismatches store export =
  match Store.locate store export.hash with
  | Error _ -> [ Declaration_mismatch (export, "no locatable declaration") ]
  | Ok { Store.decl; decl_hash; role } ->
      let owner =
        if Hash.equal decl_hash export.owner then []
        else [ Declaration_mismatch (export, "owner " ^ Hash.to_hex decl_hash) ]
      in
      let contract =
        match (export.kind, decl.Kernel.it, role) with
        | Resolve.KOp, Kernel.DefEffect { ops; _ }, Store.Operation index -> (
            match (List.nth_opt ops index, export.mode) with
            | Some operation, Some mode when operation.Kernel.op_mode = mode -> []
            | Some operation, _ ->
                [
                  Declaration_mismatch
                    ( export,
                      "mode "
                      ^
                      match operation.Kernel.op_mode with
                      | Kernel.Once -> "once"
                      | Kernel.Multi -> "multi" );
                ]
            | None, _ -> [ Declaration_mismatch (export, "no such operation") ])
        | Resolve.KCon, Kernel.DefType { cons; _ }, Store.Constructor index -> (
            match List.nth_opt cons index with
            | Some constructor ->
                let labels =
                  Some (List.map (fun (field : Kernel.field) -> field.label) constructor.fields)
                in
                if labels = export.labels then []
                else
                  [
                    Declaration_mismatch
                      (export, "fields (" ^ describe_labels (Option.value labels ~default:[]) ^ ")");
                  ]
            | None -> [ Declaration_mismatch (export, "no such constructor") ])
        | Resolve.KType, Kernel.DefType { tvars; _ }, Store.Whole ->
            if export.arity = Some (List.length tvars) then []
            else [ Declaration_mismatch (export, Printf.sprintf "arity %d" (List.length tvars)) ]
        | Resolve.KEffect, Kernel.DefEffect { evars; _ }, Store.Whole ->
            if export.arity = Some (List.length evars) then []
            else [ Declaration_mismatch (export, Printf.sprintf "arity %d" (List.length evars)) ]
        | Resolve.KTerm, Kernel.DefTerm _, Store.Member _ -> []
        | _ -> [ Declaration_mismatch (export, "another kind of declaration") ]
      in
      owner @ contract

let verify t store =
  let prelude =
    match (t.prelude, Store.prelude_manifest store) with
    | Some recorded, Some current when recorded <> current -> [ Prelude_changed ]
    | _ -> []
  in
  let export_mismatches export =
    match Store.lookup_kind store export.name export.kind with
    | None -> [ Missing export ]
    | Some { Resolve.hash; _ } when not (Hash.equal hash export.hash) -> [ Rebound (export, hash) ]
    | Some _ ->
        let companion =
          match export.kind with
          | Resolve.KTerm | Resolve.KOp -> (
              match (export.labels, List.assoc_opt export.hash store.Store.call_abis) with
              | None, _ -> []
              | Some _, None -> [ Companion_missing export ]
              | Some expected, Some found when expected <> found ->
                  [ Companion_mismatch (export, found) ]
              | Some _, Some _ -> [])
          | Resolve.KCon | Resolve.KType | Resolve.KEffect -> []
        in
        companion @ declaration_mismatches store export
  in
  let exposed =
    List.filter_map
      (fun (member, _) ->
        if List.exists (fun (_, entry) -> Hash.equal entry.Resolve.hash member) (Store.names store)
        then Some (Exposed member)
        else None)
      t.hidden
  in
  match prelude @ List.concat_map export_mismatches t.exports @ exposed with
  | [] -> Ok ()
  | mismatches -> Error mismatches

(* --- API comparison --- *)

type change =
  | Added
  | Removed
  | Renamed_from of string
  | Identity_changed of Hash.t * Hash.t
  | Signature_changed_to of string option * string option
  | Labels_changed of string option list option * string option list option
  | Mode_changed of Kernel.op_mode option * Kernel.op_mode option
  | Arity_changed of int option * int option
  | Became_hidden
  | Became_public

type report = { compatible : bool; entries : (export * change list) list }

let additive = function Added | Became_public -> true | _ -> false

let diff ~old ~new_ =
  let hidden_in t hash = List.exists (fun (member, _) -> Hash.equal member hash) t.hidden in
  let missing_from t export = Option.is_none (find t export.name export.kind) in
  (* a rename pairs a name that disappeared with a name that appeared for the same identity, each
     side consumed once; a surviving alias is neither, and an unpaired name is an addition or a
     removal in its own right *)
  let removed_names = List.filter (missing_from new_) old.exports in
  let added_names = List.filter (missing_from old) new_.exports in
  let pairs, _ =
    List.fold_left
      (fun (pairs, unpaired) export ->
        match
          List.partition
            (fun previous -> Hash.equal previous.hash export.hash && previous.kind = export.kind)
            unpaired
        with
        | previous :: rest, others ->
            ((export.name, export.kind, previous.name) :: pairs, rest @ others)
        | [], _ -> (pairs, unpaired))
      ([], removed_names) added_names
  in
  let renamed_from export =
    List.find_map
      (fun (name, kind, previous) ->
        if String.equal name export.name && kind = export.kind then Some previous else None)
      pairs
  in
  let renamed_away previous =
    List.exists
      (fun (_, kind, name) -> String.equal name previous.name && kind = previous.kind)
      pairs
  in
  let compared =
    List.map
      (fun export ->
        match find old export.name export.kind with
        | None ->
            let changes =
              match renamed_from export with
              | Some previous -> [ Renamed_from previous ]
              | None -> if hidden_in old export.hash then [ Became_public ] else [ Added ]
            in
            (export, changes)
        | Some previous ->
            let changes =
              (if Hash.equal previous.hash export.hash then []
               else [ Identity_changed (previous.hash, export.hash) ])
              @ (if previous.signature = export.signature then []
                 else [ Signature_changed_to (previous.signature, export.signature) ])
              @ (if previous.labels = export.labels then []
                 else [ Labels_changed (previous.labels, export.labels) ])
              @ (if previous.mode = export.mode then []
                 else [ Mode_changed (previous.mode, export.mode) ])
              @
              if previous.arity = export.arity then []
              else [ Arity_changed (previous.arity, export.arity) ]
            in
            (export, changes))
      new_.exports
  in
  let removed =
    List.filter_map
      (fun previous ->
        if renamed_away previous then None (* reported as a rename *)
        else if hidden_in new_ previous.hash then Some (previous, [ Became_hidden ])
        else Some (previous, [ Removed ]))
      removed_names
  in
  let entries = List.filter (fun (_, changes) -> changes <> []) compared @ removed in
  { compatible = List.for_all (fun (_, changes) -> List.for_all additive changes) entries; entries }

let describe_change = function
  | Added -> "added"
  | Removed -> "removed"
  | Renamed_from previous -> Printf.sprintf "renamed from %s" previous
  | Identity_changed (before, after) ->
      Printf.sprintf "identity %s -> %s" (Hash.to_hex before) (Hash.to_hex after)
  | Signature_changed_to (before, after) ->
      Printf.sprintf "signature %s -> %s"
        (Option.value before ~default:"<none>")
        (Option.value after ~default:"<none>")
  | Labels_changed (before, after) ->
      let show = function
        | None -> "positional-only"
        | Some labels -> "(" ^ describe_labels labels ^ ")"
      in
      Printf.sprintf "labels %s -> %s" (show before) (show after)
  | Mode_changed (before, after) ->
      let show = function
        | Some Kernel.Once -> "once"
        | Some Kernel.Multi -> "multi"
        | None -> "<none>"
      in
      Printf.sprintf "mode %s -> %s" (show before) (show after)
  | Arity_changed (before, after) ->
      let show = function Some arity -> string_of_int arity | None -> "<none>" in
      Printf.sprintf "arity %s -> %s" (show before) (show after)
  | Became_hidden -> "hidden"
  | Became_public -> "exposed"

let render_report report =
  match report.entries with
  | [] -> None
  | entries ->
      let lines =
        List.map
          (fun (export, changes) ->
            Printf.sprintf "%-10s %s %s: %s"
              (if List.for_all additive changes then "compatible" else "breaking")
              (Store.kind_sym export.kind) export.name
              (String.concat "; " (List.map describe_change changes)))
          entries
      in
      Some (String.concat "\n" lines)
