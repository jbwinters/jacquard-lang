(** Name resolution (plan W1.4): parsed kernel to resolved kernel.

    Locals stay [Var] (lexical scoping over [lam] params, [let] binders, [match] clause patterns,
    handler op-clause params and resume names, and the [ret] binder). Free names look up the store's
    name index and become [Ref (hash, kind)], retaining the original name in meta under [name].
    Within a [defterm] group, members see each other; a member reference resolves to the group-local
    marker [GroupRef i] (source order), not a hash (spec §6).

    Surface parsing may attach hash-excluded [surface-ref-kind] metadata to an unresolved [Var].
    Resolution consumes [term]/[con]/[op] hints before ordinary value-position precedence. This
    preserves escaped-name and Pascal constructor intent without adding a kernel form.

    [Named] references in patterns ([pcon]), op clauses, types ([tref]) and rows ([eref]) resolve
    against the same index and must have the matching kind. [Quote] payloads are data and are left
    unresolved, except that every [(unquote e)] splice inside them is resolved (splices evaluate).

    The store dependency is the seam the plan calls out: resolution takes a [names] record; W1.4
    tests it against an in-memory stub and W1.6's store provides the real one.

    Diagnostics (accumulated; resolution visits the whole tree): E0301 unknown name (with near-miss
    suggestions at edit distance <= 2), E0302 kind mismatch, E0303 duplicate binding name in a
    [defterm] group, E0304 duplicate variable in one pattern, and E0305-E0308 labeled-pattern schema
    failures. E0309-E0314 cover missing, invalid, incomplete, or ambiguous explicit named-call ABIs
    and call sites. *)

(** What a name in scope refers to. [KCon]/[KOp] hashes are the folded constructor/operation hashes
    (decl hash + ordinal, derived in W1.5). *)
type nkind = KTerm | KCon | KOp | KType | KEffect

type entry = { hash : Hash.t; kind : nkind }

type call_abi = string option list
(** Declaration-order callable slots. [None] is positional-only; [Some label] is one explicit
    external label. A usable ABI has one unlabeled prefix and one uniquely labeled suffix. *)

type names = {
  lookup : string -> entry list;
  all_names : unit -> string list;
  constructor_fields : Hash.t -> string option list option;
  callable_abi : Hash.t -> call_abi option;
}
(** The resolver's view of a store. [lookup] returns EVERY binding of a name — the index is (name,
    kind)-keyed (SL.1), so an effect and its operation may share a bare name; kind- directed
    positions pick their kind, and value positions use term > con > op precedence.
    [constructor_fields] returns the declaration-order field labels for a resolved constructor; it
    is the elaboration seam for labeled partial patterns and constructor calls. [callable_abi]
    returns an explicit, hash-bound v1 parameter-label vector for a term or operation and never
    derives labels from binder names. *)

let empty_names =
  {
    lookup = (fun _ -> []);
    all_names = (fun () -> []);
    constructor_fields = (fun _ -> None);
    callable_abi = (fun _ -> None);
  }

(** [of_alist entries] builds a stub index (duplicate names with distinct kinds allowed); the W1.6
    store exposes the real one. [constructor_fields] may provide a constructor's declaration-order
    field labels for labeled-pattern expansion. It defaults to no schema, so a labeled pattern then
    fails with a diagnostic instead of guessing from binder names. *)
let of_alist ?(constructor_fields = fun _ -> None) ?(callable_abi = fun _ -> None) alist =
  {
    lookup = (fun n -> List.filter_map (fun (m, e) -> if m = n then Some e else None) alist);
    all_names = (fun () -> List.map fst alist);
    constructor_fields;
    callable_abi;
  }

let kind_to_string = function
  | KTerm -> "a term"
  | KCon -> "a constructor"
  | KOp -> "an effect operation"
  | KType -> "a type"
  | KEffect -> "an effect"

let hinted_value_kind meta =
  match Meta.surface_ref_kind meta with
  | Some "term" -> Some (KTerm, Kernel.Term)
  | Some "con" -> Some (KCon, Kernel.Con)
  | Some "op" -> Some (KOp, Kernel.Op)
  | Some _ | None -> None

(* Damerau-free Levenshtein, capped: we only care whether d <= 2. *)
let edit_distance a b =
  let la = String.length a and lb = String.length b in
  if abs (la - lb) > 2 then 3
  else begin
    let prev = Array.init (lb + 1) Fun.id in
    let cur = Array.make (lb + 1) 0 in
    for i = 1 to la do
      cur.(0) <- i;
      for j = 1 to lb do
        let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        cur.(j) <- min (min (cur.(j - 1) + 1) (prev.(j) + 1)) (prev.(j - 1) + cost)
      done;
      Array.blit cur 0 prev 0 (lb + 1)
    done;
    prev.(lb)
  end

type state = { names : names; mutable diags : Diag.t list }

let report st d = st.diags <- d :: st.diags
let rec take n = function [] -> [] | x :: xs -> if n <= 0 then [] else x :: take (n - 1) xs

let suggestions st ~locals name =
  List.sort_uniq String.compare (locals @ st.names.all_names ())
  |> List.filter (fun candidate -> candidate <> name && edit_distance name candidate <= 2)
  |> take 3

let unknown st ~meta ~locals ~what name =
  let candidates = suggestions st ~locals name in
  let contrast =
    match candidates with
    | [ candidate ] ->
        Some
          (Diag.contrast
             ~mistaken:(Printf.sprintf "the unknown name `%s`" name)
             ~intended:(Printf.sprintf "the in-scope name `%s`" candidate))
    | [] | _ :: _ :: _ -> None
  in
  let cause =
    match candidates with
    | [] -> Printf.sprintf "No %s named `%s` is in scope." what name
    | values ->
        Printf.sprintf "No %s named `%s` is in scope; nearby names are %s." what name
          (String.concat ", " (List.map (Printf.sprintf "`%s`") values))
  in
  report st
    (Diag.error ?span:(Meta.span meta) ~domain:Resolution ~code:"E0301"
       ~summary:"This reference names something that is not in scope." ~cause
       ~next_step:"Correct the reference to an in-scope name or declaration." ~contrast ())

let kind_mismatch st ~meta name ~expected ~got =
  report st
    (Diag.error ?span:(Meta.span meta) ~domain:Resolution ~code:"E0302"
       ~summary:"This reference has the wrong kind for its position."
       ~cause:
         (Printf.sprintf "`%s` is %s, but this position needs %s." name (kind_to_string got)
            expected)
       ~next_step:"Reference a declaration of the required kind in this position."
       ~contrast:(Some (Diag.contrast ~mistaken:(kind_to_string got) ~intended:expected))
       ())

(* Resolve a non-term reference position (pcon/opclause/tref/eref): kind-directed, so among
   all bindings of the name the one with the expected kind wins. *)
let resolve_gref st ~meta ~locals ~expected_kind ~expected_desc ~what (g : Kernel.gref) :
    Kernel.gref =
  match g with
  | Kernel.Hashed _ -> g
  | Kernel.Named n -> (
      let entries = st.names.lookup n in
      match List.find_opt (fun e -> e.kind = expected_kind) entries with
      | Some { hash; _ } -> Kernel.Hashed hash
      | None -> (
          match entries with
          | { kind; _ } :: _ ->
              kind_mismatch st ~meta n ~expected:expected_desc ~got:kind;
              g
          | [] ->
              unknown st ~meta ~locals ~what n;
              g))

(* Variables bound by a pattern, in binding order; duplicates within one binder group are
   diagnosed (E0304). [seen] is shared across sibling patterns of one binding construct
   (n-ary lam params, opclause params + resume), so `(lam ((pvar x) (pvar x)) ...)` is
   rejected like a duplicate inside a single pattern. *)
let pat_vars_seen st seen (p : Kernel.pat) : string list =
  let acc = ref [] in
  let bind meta x =
    if Hashtbl.mem seen x then
      report st
        (Diag.error ?span:(Meta.span meta) ~domain:Resolution ~code:"E0304"
           ~summary:"A pattern binds the same variable more than once."
           ~cause:(Printf.sprintf "Variable `%s` is bound more than once in this pattern." x)
           ~next_step:"Rename or remove the duplicate pattern binding." ~contrast:None ())
    else begin
      Hashtbl.add seen x ();
      acc := x :: !acc
    end
  in
  let rec go (p : Kernel.pat) =
    match p.Kernel.it with
    | Kernel.PWild | Kernel.PLit _ -> ()
    | Kernel.PVar x -> bind p.Kernel.meta x
    | Kernel.PCon (_, ps) | Kernel.PTuple ps -> List.iter go ps
    | Kernel.PAs (x, inner) ->
        bind p.Kernel.meta x;
        go inner
  in
  go p;
  List.rev !acc

let pat_vars st p = pat_vars_seen st (Hashtbl.create 8) p

let pats_vars st ps =
  let seen = Hashtbl.create 8 in
  (seen, List.concat_map (pat_vars_seen st seen) ps)

let labeled_pattern_diagnostic st ~meta ~code ~summary ~cause ~next_step =
  report st
    (Diag.error ?span:(Meta.span meta) ~domain:Resolution ~code ~summary ~cause ~next_step
       ~contrast:None ())

let pattern_field_meta (pattern : Kernel.pat) =
  let field_meta = Meta.surface_container "pattern-field" pattern.meta in
  if Meta.is_empty field_meta then pattern.meta else field_meta

let omission_meta pattern_meta =
  let meta = Meta.with_surface_generated "labeled-pattern-omission" Meta.empty in
  match Meta.span pattern_meta with Some span -> Meta.with_span span meta | None -> meta

let duplicate_labels labels =
  let seen = Hashtbl.create 8 in
  let duplicates = ref [] in
  List.iter
    (fun label ->
      if Hashtbl.mem seen label then duplicates := label :: !duplicates
      else Hashtbl.add seen label ())
    labels;
  List.sort_uniq String.compare !duplicates

type group_entry = { group_name : string; group_index : int; group_abi : call_abi option }

let named_call_diagnostic st ~meta ~code ~summary ~cause ~next_step =
  report st
    (Diag.error ?span:(Meta.span meta) ~domain:Resolution ~code ~summary ~cause ~next_step
       ~contrast:None ())

let call_argument_meta (argument : Kernel.expr) =
  let field_meta = Meta.surface_container "call-argument" argument.meta in
  if Meta.is_empty field_meta then argument.meta else field_meta

let call_parameter_meta parameter =
  let field_meta = Meta.surface_container "call-parameter" parameter.Kernel.meta in
  if Meta.is_empty field_meta then parameter.Kernel.meta else field_meta

(** [declared_call_abi st ~what ~simple parameters] validates and returns an explicitly authored
    callable ABI. It reports E0313 and returns [None] for patterned parameters, duplicate labels, or
    an unlabeled slot after the labeled suffix. Entirely unlabeled declarations also return [None]
    without a diagnostic. *)
let declared_call_abi st ~what ~simple parameters =
  let slots =
    List.map (fun parameter -> Meta.surface_call_label parameter.Kernel.meta) parameters
  in
  if List.for_all Option.is_none slots then None
  else
    let first_patterned = List.find_opt (fun parameter -> not (simple parameter)) parameters in
    let rec unlabeled_after_named saw_named = function
      | [] -> None
      | parameter :: rest -> (
          match Meta.surface_call_label parameter.Kernel.meta with
          | Some _ -> unlabeled_after_named true rest
          | None when saw_named -> Some parameter
          | None -> unlabeled_after_named false rest)
    in
    let duplicates = duplicate_labels (List.filter_map Fun.id slots) in
    match (first_patterned, unlabeled_after_named false parameters, duplicates) with
    | Some parameter, _, _ ->
        named_call_diagnostic st ~meta:(call_parameter_meta parameter) ~code:"E0313"
          ~summary:"This declaration cannot expose a named-call ABI."
          ~cause:(Printf.sprintf "%s has a destructuring or wildcard parameter." what)
          ~next_step:
            "Use simple variable parameters throughout the callable, then label only its suffix.";
        None
    | None, Some parameter, _ ->
        named_call_diagnostic st ~meta:(call_parameter_meta parameter) ~code:"E0313"
          ~summary:"This declaration cannot expose a named-call ABI."
          ~cause:(Printf.sprintf "%s has an unlabeled parameter after a labeled parameter." what)
          ~next_step:"Keep every unlabeled parameter in one prefix before the labeled suffix.";
        None
    | None, None, duplicate :: _ ->
        let parameter =
          Option.value ~default:(List.hd parameters)
            (List.find_opt
               (fun parameter ->
                 Option.equal String.equal
                   (Meta.surface_call_label parameter.Kernel.meta)
                   (Some duplicate))
               (List.rev parameters))
        in
        named_call_diagnostic st ~meta:(call_parameter_meta parameter) ~code:"E0313"
          ~summary:"This declaration cannot expose a named-call ABI."
          ~cause:(Printf.sprintf "%s repeats external label `%s`." what duplicate)
          ~next_step:"Give each labeled parameter one unique external label.";
        None
    | None, None, [] -> Some slots

(** [binding_call_abi st binding] exposes labels only for a direct top-level lambda. *)
let binding_call_abi st (binding : Kernel.binding) =
  match binding.value.it with
  | Kernel.Lam (parameters, _) ->
      declared_call_abi st
        ~what:(Printf.sprintf "Term `%s`" binding.bname)
        ~simple:(fun parameter ->
          match parameter.Kernel.it with Kernel.PVar _ -> true | _ -> false)
        parameters
  | _ -> None

(** [operation_call_abi st operation] validates the operation's explicit parameter labels. *)
let operation_call_abi st (operation : Kernel.opspec) =
  declared_call_abi st
    ~what:(Printf.sprintf "Operation `%s`" operation.op_name)
    ~simple:(fun _ -> true)
    operation.op_params

(** [named_call_schema st group fn] returns a schema only for a direct resolved constructor, term,
    operation, or same-SCC group member. Locals, higher-order values, and computed callees fail
    closed by returning [None]. *)
let named_call_schema st group fn =
  match fn.Kernel.it with
  | Kernel.Ref (hash, Kernel.Con) -> st.names.constructor_fields hash
  | Kernel.Ref (hash, (Kernel.Term | Kernel.Op)) -> st.names.callable_abi hash
  | Kernel.GroupRef index ->
      Option.bind
        (List.find_opt (fun entry -> entry.group_index = index) group)
        (fun entry -> entry.group_abi)
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Lam _ | Kernel.App _ | Kernel.Let _ | Kernel.Match _
  | Kernel.Tuple _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _ | Kernel.Ann _ ->
      None

(** [fresh_named_argument_names ~locals ~group count] creates printable, collision-free local
    temporaries for source-order evaluation. *)
let fresh_named_argument_names ~locals ~group count =
  let occupied = Hashtbl.create (List.length locals + List.length group + count) in
  List.iter (fun name -> Hashtbl.replace occupied name ()) locals;
  List.iter (fun entry -> Hashtbl.replace occupied entry.group_name ()) group;
  let rec choose ordinal suffix =
    let name =
      if suffix = 0 then Printf.sprintf "named-call-arg-%d" ordinal
      else Printf.sprintf "named-call-arg-%d-%d" ordinal suffix
    in
    if Hashtbl.mem occupied name then choose ordinal (suffix + 1)
    else begin
      Hashtbl.add occupied name ();
      name
    end
  in
  List.init count (fun ordinal -> choose ordinal 0)

let generated_meta marker source =
  source |> Meta.without_trivia |> Meta.with_surface_generated marker

(** [lower_reordered_named_call] evaluates every argument once in source order, then applies the
    callee positionally in declaration order. It is called only for a nonempty exact-arity call. *)
let lower_reordered_named_call ~locals ~group (source : Kernel.expr) fn source_arguments
    ordered_sources =
  let names = fresh_named_argument_names ~locals ~group (List.length source_arguments) in
  let variables =
    Array.of_list
      (List.map2
         (fun name argument ->
           Kernel.
             {
               it = Var name;
               meta = generated_meta "named-call-argument-reference" argument.Kernel.meta;
             })
         names source_arguments)
  in
  let final_arguments = List.map (Array.get variables) ordered_sources in
  let final =
    Kernel.
      {
        it = App (fn, final_arguments);
        meta = generated_meta "named-call-positional-app" source.meta;
      }
  in
  List.fold_right2
    (fun name value body ->
      let binder =
        Kernel.{ it = PVar name; meta = generated_meta "named-call-argument-binder" value.meta }
      in
      let meta =
        if String.equal name (List.hd names) then
          Meta.with_surface_generated "named-call-reordered" source.meta
        else generated_meta "named-call-argument-let" value.meta
      in
      Kernel.{ it = Let { isrec = false; binder; value; body }; meta })
    names source_arguments final

(** [elaborate_named_call st ~group ~locals source fn arguments] validates explicit labels and
    returns the existing positional [App] representation. Invalid or unsupported sites report one of
    E0309-E0314 and retain a structurally valid application for accumulated resolution. *)
let elaborate_named_call st ~group ~locals (source : Kernel.expr) fn arguments =
  let labels = List.map (fun argument -> Meta.surface_call_label argument.Kernel.meta) arguments in
  if List.for_all Option.is_none labels then Kernel.{ source with it = App (fn, arguments) }
  else
    match named_call_schema st group fn with
    | None ->
        named_call_diagnostic st ~meta:source.meta ~code:"E0309"
          ~summary:"This callee has no usable named-call ABI."
          ~cause:
            "Named arguments require a direct constructor, operation, or top-level term with \
             explicit labels."
          ~next_step:
            "Call this value positionally, or declare an explicit labeled ABI on an eligible \
             direct callable.";
        Kernel.{ source with it = App (fn, arguments) }
    | Some schema -> (
        let rec positional_prefix count = function
          | None :: rest -> positional_prefix (count + 1) rest
          | Some _ :: _ | [] -> count
        in
        let prefix = positional_prefix 0 labels in
        let malformed_order =
          List.mapi (fun index label -> (index, label)) labels
          |> List.find_opt (fun (index, label) -> index >= prefix && Option.is_none label)
        in
        let duplicate_call_labels = duplicate_labels (List.filter_map Fun.id labels) in
        let schema_labels = List.filter_map Fun.id schema in
        let duplicate_schema_labels = duplicate_labels schema_labels in
        let rec schema_has_unlabeled_after_named saw_named = function
          | [] -> false
          | Some _ :: rest -> schema_has_unlabeled_after_named true rest
          | None :: _ when saw_named -> true
          | None :: rest -> schema_has_unlabeled_after_named false rest
        in
        let malformed_schema_order = schema_has_unlabeled_after_named false schema in
        let unknown =
          List.find_opt
            (fun argument ->
              match Meta.surface_call_label argument.Kernel.meta with
              | Some label -> not (List.exists (String.equal label) schema_labels)
              | None -> false)
            arguments
        in
        let slot_for_label label =
          let rec find index = function
            | [] -> None
            | Some candidate :: _ when String.equal label candidate -> Some index
            | _ :: rest -> find (index + 1) rest
          in
          find 0 schema
        in
        let overlap =
          List.find_opt
            (fun argument ->
              match Option.bind (Meta.surface_call_label argument.Kernel.meta) slot_for_label with
              | Some slot -> slot < prefix
              | None -> false)
            arguments
        in
        let report_argument code summary cause next_step argument =
          named_call_diagnostic st ~meta:(call_argument_meta argument) ~code ~summary ~cause
            ~next_step
        in
        if schema_labels = [] then begin
          named_call_diagnostic st ~meta:source.meta ~code:"E0309"
            ~summary:"This callee has no usable named-call ABI."
            ~cause:"The callable exposes no explicit external argument labels."
            ~next_step:
              "Call it positionally, or add an explicit labeled suffix to an eligible declaration.";
          Kernel.{ source with it = App (fn, arguments) }
        end
        else if duplicate_schema_labels <> [] then begin
          named_call_diagnostic st ~meta:source.meta ~code:"E0314"
            ~summary:"This callee's named-call ABI is ambiguous."
            ~cause:
              (Printf.sprintf "Its ABI repeats label(s) %s."
                 (String.concat ", " (List.map (Printf.sprintf "`%s`") duplicate_schema_labels)))
            ~next_step:"Repair the callable declaration or its stored ABI before using labels.";
          Kernel.{ source with it = App (fn, arguments) }
        end
        else if malformed_schema_order then begin
          named_call_diagnostic st ~meta:source.meta ~code:"E0314"
            ~summary:"This callee's named-call ABI is ambiguous."
            ~cause:"Its ABI has an unlabeled slot after a labeled slot."
            ~next_step:
              "Move every unlabeled constructor field into one prefix before the labeled suffix.";
          Kernel.{ source with it = App (fn, arguments) }
        end
        else if prefix > List.length schema || List.length arguments <> List.length schema then begin
          named_call_diagnostic st ~meta:source.meta ~code:"E0312"
            ~summary:"This named call does not fill the callable's exact arity."
            ~cause:
              (Printf.sprintf "The call supplies %d argument(s), but the ABI requires %d."
                 (List.length arguments) (List.length schema))
            ~next_step:"Supply every required slot exactly once; named calls have no defaults.";
          Kernel.{ source with it = App (fn, arguments) }
        end
        else
          match (malformed_order, duplicate_call_labels, unknown, overlap) with
          | Some (index, _), _, _, _ ->
              let argument = List.nth arguments index in
              report_argument "E0312" "A positional argument follows a named argument."
                "Named-call arguments must be a positional prefix followed by labeled arguments."
                "Move this positional argument before every `label: expression` argument." argument;
              Kernel.{ source with it = App (fn, arguments) }
          | None, duplicate :: _, _, _ ->
              let argument =
                Option.value ~default:(List.hd arguments)
                  (List.find_opt
                     (fun argument ->
                       Option.equal String.equal
                         (Meta.surface_call_label argument.Kernel.meta)
                         (Some duplicate))
                     (List.rev arguments))
              in
              report_argument "E0311" "This call supplies one named slot more than once."
                (Printf.sprintf "Label `%s` appears more than once in this call." duplicate)
                "Keep exactly one argument for each external label." argument;
              Kernel.{ source with it = App (fn, arguments) }
          | None, [], Some argument, _ ->
              let label = Option.get (Meta.surface_call_label argument.Kernel.meta) in
              report_argument "E0310" "This callable has no slot with the selected label."
                (Printf.sprintf "Label `%s` is not present in the callable's explicit ABI." label)
                "Use one of the callable's declared external labels." argument;
              Kernel.{ source with it = App (fn, arguments) }
          | None, [], None, Some argument ->
              let label = Option.get (Meta.surface_call_label argument.Kernel.meta) in
              report_argument "E0311" "This call fills one slot both positionally and by label."
                (Printf.sprintf "Label `%s` selects a slot already filled by the positional prefix."
                   label)
                "Remove the duplicate argument or shorten the positional prefix." argument;
              Kernel.{ source with it = App (fn, arguments) }
          | None, [], None, None -> (
              let ordered = Array.make (List.length schema) None in
              List.iteri
                (fun source_index argument ->
                  if source_index < prefix then ordered.(source_index) <- Some source_index
                  else
                    match
                      Option.bind (Meta.surface_call_label argument.Kernel.meta) slot_for_label
                    with
                    | Some slot -> ordered.(slot) <- Some source_index
                    | None -> ())
                arguments;
              let missing =
                Array.to_list ordered
                |> List.mapi (fun index source -> (index, source))
                |> List.find_opt (fun (_, source) -> Option.is_none source)
              in
              match missing with
              | Some (index, _) ->
                  let description =
                    match List.nth schema index with
                    | Some label -> Printf.sprintf "labeled slot `%s`" label
                    | None -> Printf.sprintf "unlabeled slot %d" (index + 1)
                  in
                  named_call_diagnostic st ~meta:source.meta ~code:"E0312"
                    ~summary:"This named call leaves one required slot unfilled."
                    ~cause:(Printf.sprintf "The call does not provide %s." description)
                    ~next_step:
                      "Extend the positional prefix or supply every remaining declared label.";
                  Kernel.{ source with it = App (fn, arguments) }
              | None ->
                  let ordered_sources = List.map Option.get (Array.to_list ordered) in
                  if ordered_sources = List.init (List.length arguments) Fun.id then
                    Kernel.{ source with it = App (fn, arguments) }
                  else lower_reordered_named_call ~locals ~group source fn arguments ordered_sources
              ))

let expand_labeled_pattern st ~meta hash patterns =
  let selections =
    List.filter_map
      (fun (pattern : Kernel.pat) ->
        Option.map (fun label -> (label, pattern)) (Meta.surface_pattern_label pattern.meta))
      patterns
  in
  if List.length selections <> List.length patterns then
    labeled_pattern_diagnostic st ~meta ~code:"E0307"
      ~summary:"This labeled constructor pattern has no usable field schema."
      ~cause:"A labeled pattern field reached resolution without an explicit `label:` marker."
      ~next_step:"Write every selected field as `label: pattern` and do not mix positional fields.";
  let selected_labels = List.map fst selections in
  let selected_duplicates = duplicate_labels selected_labels in
  List.iter
    (fun duplicate ->
      let duplicate_meta =
        match
          List.find_opt (fun (label, _) -> String.equal label duplicate) (List.rev selections)
        with
        | Some (_, pattern) -> pattern_field_meta pattern
        | None -> meta
      in
      labeled_pattern_diagnostic st ~meta:duplicate_meta ~code:"E0306"
        ~summary:"A labeled constructor pattern selects one field more than once."
        ~cause:(Printf.sprintf "Field `%s` is selected more than once in this pattern." duplicate)
        ~next_step:"Keep one `label: pattern` selection for each constructor field.")
    selected_duplicates;
  match st.names.constructor_fields hash with
  | None ->
      labeled_pattern_diagnostic st ~meta ~code:"E0307"
        ~summary:"This labeled constructor pattern has no usable field schema."
        ~cause:"The resolved constructor does not expose field-label metadata."
        ~next_step:"Use a stored constructor with labeled fields, or write a positional pattern.";
      patterns
  | Some fields ->
      let declaration_labels = List.filter_map Fun.id fields in
      let declaration_duplicates = duplicate_labels declaration_labels in
      if declaration_labels = [] then begin
        labeled_pattern_diagnostic st ~meta ~code:"E0307"
          ~summary:"This labeled constructor pattern has no usable field schema."
          ~cause:"The constructor declares no labeled fields."
          ~next_step:"Use a positional pattern for this constructor.";
        patterns
      end
      else if declaration_duplicates <> [] then begin
        labeled_pattern_diagnostic st ~meta ~code:"E0308"
          ~summary:"This constructor's field labels are ambiguous in a pattern."
          ~cause:
            (Printf.sprintf "The constructor declares duplicate field label(s): %s."
               (String.concat ", " (List.map (Printf.sprintf "`%s`") declaration_duplicates)))
          ~next_step:
            "Rename the duplicate declaration fields before selecting constructor fields by label.";
        patterns
      end
      else begin
        List.iter
          (fun (label, pattern) ->
            if not (List.exists (Option.equal String.equal (Some label)) fields) then
              labeled_pattern_diagnostic st ~meta:(pattern_field_meta pattern) ~code:"E0305"
                ~summary:"This constructor has no field with the selected label."
                ~cause:(Printf.sprintf "Field `%s` is not declared by this constructor." label)
                ~next_step:"Select one of the constructor's declared field labels.")
          selections;
        List.map
          (function
            | None -> Kernel.{ it = PWild; meta = omission_meta meta }
            | Some label -> (
                match
                  List.find_opt (fun (selected, _) -> String.equal selected label) selections
                with
                | Some (_, pattern) -> pattern
                | None -> Kernel.{ it = PWild; meta = omission_meta meta }))
          fields
      end

let rec resolve_pat st ~locals (p : Kernel.pat) : Kernel.pat =
  let it =
    match p.Kernel.it with
    | (Kernel.PWild | Kernel.PVar _ | Kernel.PLit _) as it -> it
    | Kernel.PCon (con, ps) ->
        let con =
          resolve_gref st ~meta:p.Kernel.meta ~locals ~expected_kind:KCon
            ~expected_desc:"a constructor" ~what:"constructor" con
        in
        let ps = List.map (resolve_pat st ~locals) ps in
        let ps =
          match (Meta.surface_form p.Kernel.meta, con) with
          | Some "labeled-pattern", Kernel.Hashed hash ->
              expand_labeled_pattern st ~meta:p.meta hash ps
          | Some "labeled-pattern", Kernel.Named _ | (Some _ | None), _ -> ps
        in
        Kernel.PCon (con, ps)
    | Kernel.PTuple ps -> Kernel.PTuple (List.map (resolve_pat st ~locals) ps)
    | Kernel.PAs (x, inner) -> Kernel.PAs (x, resolve_pat st ~locals inner)
  in
  { p with Kernel.it }

(** [resolve_ty st ~locals ~tyself ~effectself ty] resolves type and effect references while
    retaining the enclosing nominal type reference [tyself] and enclosing row reference [effectself]
    as [Named]. Those two recursive identities cannot contain their declaration hash;
    canonicalization assigns them dedicated bytes. Unknown and wrong-kind references are retained
    and accumulated in [st] as E0301/E0302, so callers must finish through [run]. *)
let rec resolve_ty st ~locals ~tyself ~effectself (t : Kernel.ty) : Kernel.ty =
  let it =
    match t.Kernel.it with
    | Kernel.TRef (Kernel.Named n) when tyself = Some n -> Kernel.TRef (Kernel.Named n)
    | Kernel.TRef r ->
        Kernel.TRef
          (resolve_gref st ~meta:t.Kernel.meta ~locals ~expected_kind:KType ~expected_desc:"a type"
             ~what:"type" r)
    | Kernel.TVar _ as it -> it
    | Kernel.TApp (head, args) ->
        Kernel.TApp
          ( resolve_ty st ~locals ~tyself ~effectself head,
            List.map (resolve_ty st ~locals ~tyself ~effectself) args )
    | Kernel.TArrow (params, row, result) ->
        Kernel.TArrow
          ( List.map (resolve_ty st ~locals ~tyself ~effectself) params,
            resolve_row st ~locals ~effectself row,
            resolve_ty st ~locals ~tyself ~effectself result )
    | Kernel.TTuple items ->
        Kernel.TTuple (List.map (resolve_ty st ~locals ~tyself ~effectself) items)
    | Kernel.TForall (tvs, rvs, body) ->
        Kernel.TForall (tvs, rvs, resolve_ty st ~locals ~tyself ~effectself body)
  in
  { t with Kernel.it }

(** [resolve_row st ~locals ~effectself row] resolves every ordinary row member as an effect hash.
    Only a member equal to the enclosing effect name remains [Named]; with [effectself = None], no
    unresolved row name is accepted. Diagnostics accumulate in [st] as for {!resolve_ty}. *)
and resolve_row st ~locals ~effectself (r : Kernel.row) : Kernel.row =
  {
    r with
    Kernel.effects =
      List.map
        (function
          | Kernel.Named n when effectself = Some n -> Kernel.Named n
          | effect_ref ->
              resolve_gref st ~meta:r.Kernel.wmeta ~locals ~expected_kind:KEffect
                ~expected_desc:"an effect" ~what:"effect" effect_ref)
        r.Kernel.effects;
  }

(* [group] maps defterm member names to their source-order index and any explicit call ABI. *)
let rec resolve_expr_in st ~group ~locals (e : Kernel.expr) : Kernel.expr =
  let mk it = { e with Kernel.it } in
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> e
  | Kernel.Var x -> (
      let hint = hinted_value_kind e.Kernel.meta in
      let lexical =
        match hint with
        | Some (KCon, _) | Some (KOp, _) -> false
        | Some (KTerm, _) | None -> true
        | Some ((KType | KEffect), _) -> false
      in
      if lexical && List.mem x locals then e
      else
        match
          if lexical then List.find_opt (fun entry -> String.equal entry.group_name x) group
          else None
        with
        | Some entry ->
            { Kernel.it = Kernel.GroupRef entry.group_index; meta = Meta.with_name x e.Kernel.meta }
        | None -> (
            let entries = st.names.lookup x in
            let value_entries =
              List.filter (fun en -> en.kind = KTerm || en.kind = KCon || en.kind = KOp) entries
            in
            (* value-position precedence over the kind-aware index: term > con > op; a bare
               var shadowed across value kinds gets a W0301 warning naming the loser *)
            let pick k = List.find_opt (fun en -> en.kind = k) value_entries in
            let chosen =
              match hint with
              | Some (kind, refkind) -> Option.map (fun entry -> (entry, refkind)) (pick kind)
              | None -> (
                  match pick KTerm with
                  | Some e -> Some (e, Kernel.Term)
                  | None -> (
                      match pick KCon with
                      | Some e -> Some (e, Kernel.Con)
                      | None -> (
                          match pick KOp with Some e -> Some (e, Kernel.Op) | None -> None)))
            in
            match chosen with
            | Some ({ hash; kind }, refkind) ->
                (* warn on distinct KINDS only: duplicate same-kind bindings are not shadowing *)
                let losers =
                  List.sort_uniq compare
                    (List.filter_map
                       (fun en -> if en.kind = kind then None else Some (kind_to_string en.kind))
                       value_entries)
                in
                if hint = None && losers <> [] then
                  report st
                    (Diag.warning ?span:(Meta.span e.Kernel.meta) ~domain:Resolution ~code:"W0301"
                       ~summary:"This bare name is ambiguous across value kinds."
                       ~cause:
                         (Printf.sprintf
                            "`%s` is bound as %s and also as %s; %s wins in value position." x
                            (kind_to_string kind) (String.concat " and " losers)
                            (kind_to_string kind))
                       ~next_step:"Use a kind-tagged escaped name to select the intended binding."
                       ~contrast:
                         (Some
                            (Diag.contrast ~mistaken:"an ambiguous bare value name"
                               ~intended:"a kind-tagged escaped name"))
                       ());
                { Kernel.it = Kernel.Ref (hash, refkind); meta = Meta.with_name x e.Kernel.meta }
            | None -> (
                match entries with
                | { kind; _ } :: _ ->
                    let expected =
                      match hint with
                      | Some (expected, _) -> kind_to_string expected
                      | None -> "a value"
                    in
                    kind_mismatch st ~meta:e.Kernel.meta x ~expected ~got:kind;
                    e
                | [] ->
                    (* sibling group members count as near-miss candidates too *)
                    unknown st ~meta:e.Kernel.meta
                      ~locals:(List.map (fun entry -> entry.group_name) group @ locals)
                      ~what:"name" x;
                    e)))
  | Kernel.Lam (params, body) ->
      let _, bound = pats_vars st params in
      mk
        (Kernel.Lam
           ( List.map (resolve_pat st ~locals) params,
             resolve_expr_in st ~group ~locals:(bound @ locals) body ))
  | Kernel.App (fn, args) ->
      let fn = resolve_expr_in st ~group ~locals fn in
      let args = List.map (resolve_expr_in st ~group ~locals) args in
      elaborate_named_call st ~group ~locals e fn args
  | Kernel.Let { isrec; binder; value; body } ->
      let bound = pat_vars st binder in
      let value_locals = if isrec then bound @ locals else locals in
      mk
        (Kernel.Let
           {
             isrec;
             binder = resolve_pat st ~locals binder;
             value = resolve_expr_in st ~group ~locals:value_locals value;
             body = resolve_expr_in st ~group ~locals:(bound @ locals) body;
           })
  | Kernel.Match (scrutinee, clauses) ->
      mk
        (Kernel.Match
           ( resolve_expr_in st ~group ~locals scrutinee,
             List.map
               (fun { Kernel.cpat; cbody; cmeta } ->
                 let bound = pat_vars st cpat in
                 {
                   Kernel.cpat = resolve_pat st ~locals cpat;
                   cbody = resolve_expr_in st ~group ~locals:(bound @ locals) cbody;
                   cmeta;
                 })
               clauses ))
  | Kernel.Tuple items -> mk (Kernel.Tuple (List.map (resolve_expr_in st ~group ~locals) items))
  | Kernel.Handle { body; ret = { rbinder; rbody; rmeta }; ops } ->
      let ret =
        let bound = pat_vars st rbinder in
        {
          Kernel.rbinder = resolve_pat st ~locals rbinder;
          rbody = resolve_expr_in st ~group ~locals:(bound @ locals) rbody;
          rmeta;
        }
      in
      let ops =
        List.map
          (fun { Kernel.op; params; resume; obody; ometa } ->
            let op =
              resolve_gref st ~meta:ometa ~locals ~expected_kind:KOp
                ~expected_desc:"an effect operation" ~what:"operation" op
            in
            let seen, bound = pats_vars st params in
            if Hashtbl.mem seen resume then
              report st
                (Diag.error ?span:(Meta.span ometa) ~domain:Resolution ~code:"E0304"
                   ~summary:"An operation clause binds the same variable twice."
                   ~cause:
                     (Printf.sprintf "Resume name `%s` duplicates an operation-clause parameter."
                        resume)
                   ~next_step:"Rename the resume binder or the duplicate operation parameter."
                   ~contrast:None ());
            {
              Kernel.op;
              params = List.map (resolve_pat st ~locals) params;
              resume;
              obody = resolve_expr_in st ~group ~locals:(resume :: (bound @ locals)) obody;
              ometa;
            })
          ops
      in
      mk (Kernel.Handle { body = resolve_expr_in st ~group ~locals body; ret; ops })
  | Kernel.Quote payload -> mk (Kernel.Quote (resolve_quote_payload st ~group ~locals payload))
  | Kernel.Unquote splice -> mk (Kernel.Unquote (resolve_expr_in st ~group ~locals splice))
  | Kernel.Ann (subject, ty) ->
      mk
        (Kernel.Ann
           ( resolve_expr_in st ~group ~locals subject,
             resolve_ty st ~locals ~tyself:None ~effectself:None ty ))

(* Quoted code stays data; only LIVE (level-0) unquote splices resolve. Nested quotes raise
   the quasiquote level; their unquotes are data until the inner quote itself evaluates. *)
and resolve_quote_payload st ~group ~locals ?(level = 0) (f : Form.t) : Form.t =
  if f.Form.head = "unquote" && level = 0 then
    match f.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok e ->
            let resolved = resolve_expr_in st ~group ~locals e in
            { f with Form.args = [ Form.F (Kernel.expr_to_form resolved) ] }
        | Error ds ->
            List.iter (report st) ds;
            f)
    | _ -> f (* shape already rejected by validation *)
  else
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    {
      f with
      Form.args =
        List.map
          (function
            | Form.F g -> Form.F (resolve_quote_payload st ~group ~locals ~level g) | a -> a)
          f.Form.args;
    }

let resolve_binding st ~group (b : Kernel.binding) : Kernel.binding =
  {
    b with
    Kernel.annot =
      Option.map (resolve_ty st ~locals:[] ~tyself:None ~effectself:None) b.Kernel.annot;
    value = resolve_expr_in st ~group ~locals:[] b.Kernel.value;
  }

let resolve_decl_in st (d : Kernel.decl) : Kernel.decl =
  let it =
    match d.Kernel.it with
    | Kernel.DefTerm bindings ->
        let group =
          List.mapi
            (fun index binding ->
              {
                group_name = binding.Kernel.bname;
                group_index = index;
                group_abi = binding_call_abi st binding;
              })
            bindings
        in
        let seen = Hashtbl.create 8 in
        List.iter
          (fun b ->
            if Hashtbl.mem seen b.Kernel.bname then
              report st
                (Diag.error ?span:(Meta.span b.Kernel.bmeta) ~domain:Resolution ~code:"E0303"
                   ~summary:"A definition group contains a duplicate binding name."
                   ~cause:
                     (Printf.sprintf "Binding `%s` appears more than once in this group."
                        b.Kernel.bname)
                   ~next_step:"Rename or remove the duplicate definition binding." ~contrast:None ())
            else Hashtbl.add seen b.Kernel.bname ())
          bindings;
        Kernel.DefTerm (List.map (resolve_binding st ~group) bindings)
    | Kernel.DefType { tname; tvars; cons } ->
        Kernel.DefType
          {
            tname;
            tvars;
            cons =
              List.map
                (fun c ->
                  {
                    c with
                    Kernel.fields =
                      List.map
                        (fun fl ->
                          {
                            fl with
                            Kernel.fty =
                              resolve_ty st ~locals:[] ~tyself:(Some tname) ~effectself:None
                                fl.Kernel.fty;
                          })
                        c.Kernel.fields;
                  })
                cons;
          }
    | Kernel.DefEffect { ename; evars; ops } ->
        List.iter (fun operation -> ignore (operation_call_abi st operation)) ops;
        Kernel.DefEffect
          {
            ename;
            evars;
            ops =
              List.map
                (fun o ->
                  {
                    o with
                    Kernel.op_params =
                      List.map
                        (resolve_ty st ~locals:[] ~tyself:(Some ename) ~effectself:(Some ename))
                        o.Kernel.op_params;
                    op_result =
                      resolve_ty st ~locals:[] ~tyself:(Some ename) ~effectself:(Some ename)
                        o.Kernel.op_result;
                  })
                ops;
          }
  in
  { d with Kernel.it }

(* Warnings (W-coded) never fail resolution; errors do. *)
let run st f x =
  let v = f st x in
  let errors, warnings =
    List.partition (fun diagnostic -> Diag.severity diagnostic = Diag.Error) (List.rev st.diags)
  in
  match errors with [] -> Ok (v, warnings) | ds -> Error ds

let fresh names = { names; diags = [] }

(** [resolve_expr_w names e] resolves a bare expression, returning W-coded warnings (e.g. W0301
    cross-kind shadowing) alongside the result. *)
let resolve_expr_w names (e : Kernel.expr) =
  run (fresh names) (fun st -> resolve_expr_in st ~group:[] ~locals:[]) e

(** [resolve_decl_w names d] resolves a declaration with warnings; [defterm] members see each other
    as [GroupRef] markers. *)
let resolve_decl_w names (d : Kernel.decl) = run (fresh names) resolve_decl_in d

(** [resolve_w names top] resolves either, with warnings. *)
let resolve_w names (t : Kernel.top) =
  match t with
  | Kernel.Decl d -> Result.map (fun (d, ws) -> (Kernel.Decl d, ws)) (resolve_decl_w names d)
  | Kernel.Expr e -> Result.map (fun (e, ws) -> (Kernel.Expr e, ws)) (resolve_expr_w names e)

(** [resolve_expr names e]: {!resolve_expr_w} with warnings dropped. *)
let resolve_expr names e = Result.map fst (resolve_expr_w names e)

(** [resolve_decl names d]: {!resolve_decl_w} with warnings dropped. *)
let resolve_decl names d = Result.map fst (resolve_decl_w names d)

(** [resolve names top]: {!resolve_w} with warnings dropped. *)
let resolve names t = Result.map fst (resolve_w names t)
