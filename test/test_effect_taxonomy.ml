open Jacquard

let taxonomy_file = "../spec/effect-taxonomy-v1.tsv"
let taxonomy_v2_file = "../spec/effect-taxonomy-v2.tsv"
let taxonomy_doc = "../docs/effect-taxonomy.md"
let membrane_doc = "../docs/effect-membranes.md"
let review_doc = "../docs/effect-review.md"
let stdlib_doc = "../docs/stdlib.md"
let tutorial_doc = "../docs/tutorial.md"
let concurrency_doc = "../docs/concurrency.md"
let schema_fixture = "docs-doctest/fixtures/effect-taxonomy-schemas.jac"
let approval_fixture = "docs-doctest/fixtures/stdlib-handler-policy.jac"
let channel_effect_hash = "bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756"
let membrane_fixture = "docs-doctest/fixtures/governed-membrane-signatures.jac"
let membrane_stdout = "docs-doctest/fixtures/governed-membrane-signatures.stdout"

type row = {
  effect_name : string;
  index_name : string;
  namespace : string;
  tier : string;
  parameters : string;
  mode : Kernel.op_mode;
  risk : string;
  ring : int;
  status : string;
  interface_hash : string;
  operations : string;
  meaning : string;
}

type handler_contract = {
  handled_effect : string;
  boundary : string;
  terms : string list;
  root_grant : bool;
}

let handler_contracts =
  [
    {
      handled_effect = "Abort";
      boundary = "`abort.to-option`, `abort.or`";
      terms = [ "abort.to-option"; "abort.or" ];
      root_grant = false;
    };
    {
      handled_effect = "Throw";
      boundary = "`throw.to-result`, `throw.catch`";
      terms = [ "throw.to-result"; "throw.catch" ];
      root_grant = false;
    };
    {
      handled_effect = "State";
      boundary = "`state.run`, `state.eval`";
      terms = [ "state.run"; "state.eval" ];
      root_grant = false;
    };
    {
      handled_effect = "Emit";
      boundary = "`emit.collect`, `emit.pipe`";
      terms = [ "emit.collect"; "emit.pipe" ];
      root_grant = false;
    };
    {
      handled_effect = "Dist";
      boundary = "`dist.enumerate`, `dist.sample-lw`, explicit root sampling grant";
      terms = [ "dist.enumerate"; "dist.sample-lw" ];
      root_grant = true;
    };
    {
      handled_effect = "Fault";
      boundary = "`fault.none`, `fault.random`, `fault.all`";
      terms = [ "fault.none"; "fault.random"; "fault.all" ];
      root_grant = false;
    };
    {
      handled_effect = "Eval";
      boundary = "explicit root grant only";
      terms = [];
      root_grant = true;
    };
    {
      handled_effect = "Console";
      boundary = "`console.scripted`, explicit root grant";
      terms = [ "console.scripted" ];
      root_grant = true;
    };
    {
      handled_effect = "Clock";
      boundary = "`clock.fixed`, explicit root grant";
      terms = [ "clock.fixed" ];
      root_grant = true;
    };
    {
      handled_effect = "Fs";
      boundary = "`fs.in-memory`, `fs.read-only`, explicit root grant";
      terms = [ "fs.in-memory"; "fs.read-only" ];
      root_grant = true;
    };
    {
      handled_effect = "Net";
      boundary = "`net.scripted`, `net.record`, explicit root grant";
      terms = [ "net.scripted"; "net.record" ];
      root_grant = true;
    };
    {
      handled_effect = "Infer";
      boundary = "`infer.scripted`, explicit root grant";
      terms = [ "infer.scripted" ];
      root_grant = true;
    };
    {
      handled_effect = "Approval";
      boundary =
        "`approval.console`, `approval.scripted`, `approval.dry-run`, `approval.policy-auto`";
      terms =
        [ "approval.console"; "approval.scripted"; "approval.dry-run"; "approval.policy-auto" ];
      root_grant = false;
    };
    {
      handled_effect = "Audit";
      boundary = "`audit.in-memory`, `audit.line-log`";
      terms = [ "audit.in-memory"; "audit.line-log" ];
      root_grant = false;
    };
    {
      handled_effect = "Secret";
      boundary =
        "`Prelude.install_secret_fixed`, `Prelude.install_secret_vault`, explicit environment root \
         grant";
      terms = [];
      root_grant = true;
    };
    {
      handled_effect = "Judge";
      boundary = "`judge.rules`, `judge.fixed`, `judge.scripted`, `judge.model`";
      terms = [ "judge.rules"; "judge.fixed"; "judge.scripted"; "judge.model" ];
      root_grant = false;
    };
    {
      handled_effect = "Workspace";
      boundary = "`workspace.read-file`, `workspace.write-file`, `workspace.fetch` typed facade";
      terms = [];
      root_grant = false;
    };
    {
      handled_effect = "Channel";
      boundary = "interpreted exact-scope FIFO channels installed by SC.14";
      terms = [];
      root_grant = false;
    };
  ]

let schema_reserved_effects = [ "Choose"; "Env"; "Pg"; "Blob"; "Serve"; "Crypto"; "Log"; "Async" ]
let unimplemented_reserved_effects = [ "Choose"; "Env"; "Pg"; "Blob"; "Serve"; "Crypto"; "Log" ]

type effect_shape = { ename : string; evars : string list; ops : Kernel.opspec list }

type channel_trace_event = {
  decision : int;
  task : string;
  operation : string;
  before : string;
  action : string;
  after : string;
  result : string;
  wake : string;
}

let split_tabs line = Str.split_delim (Str.regexp "\t") line

let parse_row line =
  match split_tabs line with
  | [
   effect_name;
   index_name;
   namespace;
   tier;
   parameters;
   mode;
   risk;
   ring;
   status;
   interface_hash;
   operations;
   meaning;
  ] ->
      {
        effect_name;
        index_name;
        namespace;
        tier;
        parameters;
        mode =
          (match mode with
          | "once" -> Kernel.Once
          | "multi" -> Kernel.Multi
          | other -> Alcotest.failf "unknown taxonomy mode %s" other);
        risk;
        ring =
          (match int_of_string_opt ring with
          | Some ring -> ring
          | None -> Alcotest.failf "invalid taxonomy ring %s" ring);
        status;
        interface_hash;
        operations;
        meaning;
      }
  | columns ->
      Alcotest.failf "taxonomy row has %d columns, expected 12: %s" (List.length columns) line

let rows_from path =
  Corpus_support.read_file path |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      let line = String.trim line in
      if String.equal line "" || String.starts_with ~prefix:"#" line then None
      else Some (parse_row line))

let rows () = rows_from taxonomy_file
let rows_v2 () = rows_from taxonomy_v2_file

let operation_names operations =
  String.split_on_char ';' operations
  |> List.map (fun schema ->
      match String.index_opt schema ':' with
      | Some index -> String.sub schema 0 index
      | None -> Alcotest.failf "operation schema lacks a colon: %s" schema)

let implementation_operation_names row =
  if String.equal row.effect_name "Channel" then operation_names row.operations
  else
    let prefix = row.index_name ^ "." in
    operation_names row.operations
    |> List.map (fun name ->
        if String.starts_with ~prefix name then
          String.sub name (String.length prefix) (String.length name - String.length prefix)
        else name)

let compact value =
  value |> String.lowercase_ascii |> Str.global_replace (Str.regexp "[ \t\r\n-]+") ""

let rec schema_ty (ty : Kernel.ty) =
  match ty.it with
  | Kernel.TRef (Kernel.Named name) -> name
  | Kernel.TRef (Kernel.Hashed hash) -> "#" ^ Hash.to_hex hash
  | Kernel.TVar name -> name
  | Kernel.TApp (head, args) -> String.concat " " (schema_ty head :: List.map schema_ty_atom args)
  | Kernel.TArrow (params, row, result) ->
      let effects =
        List.map
          (function Kernel.Named name -> name | Kernel.Hashed hash -> "#" ^ Hash.to_hex hash)
          row.effects
      in
      let row_items =
        String.concat "," effects ^ match row.rvar with None -> "" | Some tail -> "|" ^ tail
      in
      "("
      ^ String.concat "," (List.map schema_ty params)
      ^ ")->{" ^ row_items ^ "}" ^ schema_ty result
  | Kernel.TTuple [] -> "()"
  | Kernel.TTuple items -> "(" ^ String.concat "," (List.map schema_ty items) ^ ")"
  | Kernel.TForall (tvars, rvars, body) ->
      "forall " ^ String.concat "," tvars ^ "|" ^ String.concat "," rvars ^ "." ^ schema_ty body

and schema_ty_atom ty =
  match ty.Kernel.it with
  | Kernel.TApp _ | Kernel.TArrow _ | Kernel.TForall _ -> "(" ^ schema_ty ty ^ ")"
  | _ -> schema_ty ty

let operation_schemas (ops : Kernel.opspec list) =
  ops
  |> List.map (fun (op : Kernel.opspec) ->
      op.op_name ^ ":("
      ^ String.concat "," (List.map schema_ty op.op_params)
      ^ ")->" ^ schema_ty op.op_result)
  |> String.concat ";"

let row_type_parameters row =
  if String.equal row.parameters "-" then [] else String.split_on_char ',' row.parameters

let implementation_operation_schema row schema =
  let schema =
    if String.equal row.effect_name "Judge" then
      Str.global_replace
        (Str.regexp_string "(Call)->Assessment")
        "(GovernanceCall)->GovernanceAssessment" schema
    else schema
  in
  match String.index_opt schema ':' with
  | None -> Alcotest.failf "operation schema lacks a colon: %s" schema
  | Some index ->
      let name = String.sub schema 0 index in
      let prefix = row.index_name ^ "." in
      let name =
        if (not (String.equal row.effect_name "Channel")) && String.starts_with ~prefix name then
          String.sub name (String.length prefix) (String.length name - String.length prefix)
        else name
      in
      name ^ " " ^ String.sub schema index (String.length schema - index)

let taxonomy_effect_source row =
  let parameters =
    match row_type_parameters row with [] -> "" | parameters -> " " ^ String.concat " " parameters
  in
  let operations =
    String.split_on_char ';' row.operations
    |> List.map (implementation_operation_schema row)
    |> String.concat "\n  "
  in
  let mode = match row.mode with Kernel.Once -> "once" | Kernel.Multi -> "multi" in
  Printf.sprintf "%s effect %s%s where {\n  %s\n}\n" mode row.effect_name parameters operations

let taxonomy_effect_decl row =
  let source = taxonomy_effect_source row in
  let file = "<taxonomy:" ^ row.effect_name ^ ">" in
  let tops =
    match Surface_parse.parse_string ~file source with
    | Ok tops -> tops
    | Error diagnostics -> Eval_support.fail_diags ("parse " ^ file) diagnostics
  in
  match Surface_lower.lower_tops tops with
  | Ok [ Kernel.Decl declaration ] -> declaration
  | Ok _ -> Alcotest.failf "%s did not lower to exactly one effect declaration" file
  | Error diagnostics -> Eval_support.fail_diags ("lower " ^ file) diagnostics

let same_gref left right =
  match (left, right) with
  | Kernel.Named left, Kernel.Named right -> String.equal left right
  | Kernel.Hashed left, Kernel.Hashed right -> Hash.equal left right
  | Kernel.Named _, Kernel.Hashed _ | Kernel.Hashed _, Kernel.Named _ -> false

let rec same_ty (left : Kernel.ty) (right : Kernel.ty) =
  match (left.it, right.it) with
  | Kernel.TRef left, Kernel.TRef right -> same_gref left right
  | Kernel.TVar left, Kernel.TVar right -> String.equal left right
  | Kernel.TApp (left_head, left_args), Kernel.TApp (right_head, right_args) ->
      same_ty left_head right_head && List.equal same_ty left_args right_args
  | ( Kernel.TArrow (left_params, left_row, left_result),
      Kernel.TArrow (right_params, right_row, right_result) ) ->
      List.equal same_ty left_params right_params
      && List.equal same_gref left_row.effects right_row.effects
      && Option.equal String.equal left_row.rvar right_row.rvar
      && same_ty left_result right_result
  | Kernel.TTuple left, Kernel.TTuple right -> List.equal same_ty left right
  | ( Kernel.TForall (left_tvars, left_rvars, left_body),
      Kernel.TForall (right_tvars, right_rvars, right_body) ) ->
      List.equal String.equal left_tvars right_tvars
      && List.equal String.equal left_rvars right_rvars
      && same_ty left_body right_body
  | ( ( Kernel.TRef _ | Kernel.TVar _ | Kernel.TApp _ | Kernel.TArrow _ | Kernel.TTuple _
      | Kernel.TForall _ ),
      _ ) ->
      false

let same_opspec (left : Kernel.opspec) (right : Kernel.opspec) =
  String.equal left.op_name right.op_name
  && left.op_mode = right.op_mode
  && List.equal same_ty left.op_params right.op_params
  && same_ty left.op_result right.op_result

let canonical_name store kind hash =
  match
    Store.names store
    |> List.filter_map (fun (name, (entry : Resolve.entry)) ->
        if entry.kind = kind && Hash.equal entry.hash hash then Some name else None)
    |> List.sort_uniq String.compare
  with
  | name :: _ -> name
  | [] ->
      Alcotest.failf "resolved %s identity #%s has no public prelude name"
        (match kind with
        | Resolve.KType -> "type"
        | Resolve.KEffect -> "effect"
        | Resolve.KTerm -> "term"
        | Resolve.KCon -> "constructor"
        | Resolve.KOp -> "operation")
        (Hash.to_hex hash)

let check_canonical_gref store kind label unresolved resolved =
  match (unresolved, resolved) with
  | Kernel.Named source_name, Kernel.Hashed hash ->
      Alcotest.(check string)
        (label ^ " canonical referenced name")
        (canonical_name store kind hash) source_name
  | Kernel.Named source_name, Kernel.Named self_name ->
      Alcotest.(check string) (label ^ " self reference") source_name self_name
  | Kernel.Hashed source_hash, Kernel.Hashed resolved_hash ->
      Alcotest.(check bool)
        (label ^ " explicit reference identity")
        true
        (Hash.equal source_hash resolved_hash)
  | _ -> Alcotest.failf "%s changed reference shape during resolution" label

let paired label left right =
  if List.length left <> List.length right then
    Alcotest.failf "%s changed arity during resolution" label;
  List.combine left right

let rec check_canonical_ty_names store label (unresolved : Kernel.ty) (resolved : Kernel.ty) =
  match (unresolved.it, resolved.it) with
  | Kernel.TRef unresolved, Kernel.TRef resolved ->
      check_canonical_gref store Resolve.KType label unresolved resolved
  | Kernel.TVar unresolved, Kernel.TVar resolved ->
      Alcotest.(check string) (label ^ " type variable") unresolved resolved
  | Kernel.TApp (unresolved_head, unresolved_args), Kernel.TApp (resolved_head, resolved_args) ->
      check_canonical_ty_names store (label ^ " constructor") unresolved_head resolved_head;
      List.iteri
        (fun index (unresolved, resolved) ->
          check_canonical_ty_names store
            (Printf.sprintf "%s argument %d" label index)
            unresolved resolved)
        (paired label unresolved_args resolved_args)
  | ( Kernel.TArrow (unresolved_params, unresolved_row, unresolved_result),
      Kernel.TArrow (resolved_params, resolved_row, resolved_result) ) ->
      List.iteri
        (fun index (unresolved, resolved) ->
          check_canonical_ty_names store
            (Printf.sprintf "%s parameter %d" label index)
            unresolved resolved)
        (paired label unresolved_params resolved_params);
      List.iteri
        (fun index (unresolved, resolved) ->
          check_canonical_gref store Resolve.KEffect
            (Printf.sprintf "%s effect %d" label index)
            unresolved resolved)
        (paired label unresolved_row.effects resolved_row.effects);
      Alcotest.(check (option string))
        (label ^ " row variable") unresolved_row.rvar resolved_row.rvar;
      check_canonical_ty_names store (label ^ " result") unresolved_result resolved_result
  | Kernel.TTuple unresolved, Kernel.TTuple resolved ->
      List.iteri
        (fun index (unresolved, resolved) ->
          check_canonical_ty_names store
            (Printf.sprintf "%s tuple item %d" label index)
            unresolved resolved)
        (paired label unresolved resolved)
  | ( Kernel.TForall (unresolved_tvars, unresolved_rvars, unresolved_body),
      Kernel.TForall (resolved_tvars, resolved_rvars, resolved_body) ) ->
      Alcotest.(check (list string))
        (label ^ " forall type variables")
        unresolved_tvars resolved_tvars;
      Alcotest.(check (list string))
        (label ^ " forall row variables") unresolved_rvars resolved_rvars;
      check_canonical_ty_names store (label ^ " forall body") unresolved_body resolved_body
  | _ -> Alcotest.failf "%s changed type shape during resolution" label

let check_canonical_operation_names store effect_name unresolved resolved =
  List.iter
    (fun ((unresolved : Kernel.opspec), (resolved : Kernel.opspec)) ->
      List.iteri
        (fun index ((unresolved_ty : Kernel.ty), (resolved_ty : Kernel.ty)) ->
          check_canonical_ty_names store
            (Printf.sprintf "%s.%s parameter %d" effect_name unresolved.op_name index)
            unresolved_ty resolved_ty)
        (paired (effect_name ^ "." ^ unresolved.op_name) unresolved.op_params resolved.op_params);
      check_canonical_ty_names store
        (Printf.sprintf "%s.%s result" effect_name unresolved.op_name)
        unresolved.op_result resolved.op_result)
    (paired effect_name unresolved resolved)

let resolved_taxonomy_effect store row =
  let unresolved = taxonomy_effect_decl row in
  let resolved =
    match Resolve.resolve_decl (Store.names_view store) unresolved with
    | Ok declaration -> declaration
    | Error diagnostics ->
        Eval_support.fail_diags ("resolve taxonomy schema " ^ row.effect_name) diagnostics
  in
  match (unresolved.it, resolved.it) with
  | Kernel.DefEffect unresolved, Kernel.DefEffect resolved ->
      Alcotest.(check string) (row.effect_name ^ " effect name") row.index_name resolved.ename;
      Alcotest.(check (list string))
        (row.effect_name ^ " exact type parameters")
        (row_type_parameters row) resolved.evars;
      check_canonical_operation_names store row.effect_name unresolved.ops resolved.ops;
      resolved.ops
  | _ -> Alcotest.failf "%s taxonomy schema is not an effect" row.effect_name

let schema_tops () =
  let source = Corpus_support.read_file schema_fixture in
  let parsed =
    match Surface_parse.parse_string ~file:schema_fixture source with
    | Ok tops -> tops
    | Error diagnostics -> Eval_support.fail_diags "parse taxonomy schema fixture" diagnostics
  in
  match Surface_lower.lower_tops parsed with
  | Ok tops -> tops
  | Error diagnostics -> Eval_support.fail_diags "lower taxonomy schema fixture" diagnostics

let schema_declarations () =
  schema_tops ()
  |> List.filter_map (function
    | Kernel.Decl declaration -> Some declaration
    | Kernel.Expr _ -> None)

let contains_string haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let count_string haystack needle =
  let expression = Str.regexp_string needle in
  let rec loop position count =
    try
      let found = Str.search_forward expression haystack position in
      loop (found + String.length needle) (count + 1)
    with Not_found -> count
  in
  loop 0 0

let normalize_whitespace value = Str.global_replace (Str.regexp "[ \t\r\n]+") " " value
let mode_name = function Kernel.Once -> "once" | Kernel.Multi -> "multi"
let markdown_operations operations = Str.global_replace (Str.regexp_string "|") "\\|" operations

let trace_field path line key token =
  let prefix = key ^ "=" in
  match String.starts_with ~prefix token with
  | true -> String.sub token (String.length prefix) (String.length token - String.length prefix)
  | false -> Alcotest.failf "%s trace field %s is malformed in %S" path key line

let parse_channel_trace_event path line =
  match String.split_on_char ' ' line with
  | [ decision; task; operation; before; action; after; result; wake ] ->
      let decision = trace_field path line "decision" decision in
      {
        decision =
          (match int_of_string_opt decision with
          | Some decision -> decision
          | None -> Alcotest.failf "%s has non-integer decision %S" path decision);
        task = trace_field path line "task" task;
        operation = trace_field path line "op" operation;
        before = trace_field path line "before" before;
        action = trace_field path line "action" action;
        after = trace_field path line "after" after;
        result = trace_field path line "result" result;
        wake = trace_field path line "wake" wake;
      }
  | fields ->
      Alcotest.failf "%s trace event has %d fields, expected 8: %S" path (List.length fields) line

let markdown_row (row : row) =
  Printf.sprintf
    "| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%d` | `%s` | `%s` | `%s` | %s |"
    row.effect_name row.index_name row.namespace row.tier row.parameters (mode_name row.mode)
    row.risk row.ring row.status row.interface_hash
    (markdown_operations row.operations)
    row.meaning

let check_unique label values =
  let sorted = List.sort String.compare values in
  let rec duplicates = function
    | a :: (b :: _ as rest) when String.equal a b -> a :: duplicates rest
    | _ :: rest -> duplicates rest
    | [] -> []
  in
  Alcotest.(check (list string)) label [] (duplicates sorted)

let test_complete_contract () =
  let rows = rows () in
  let doc = Corpus_support.read_file taxonomy_doc in
  Alcotest.(check int) "blessed effect count" 26 (List.length rows);
  Alcotest.(check int)
    "implemented count" 18
    (List.length (List.filter (fun row -> String.equal row.status "implemented") rows));
  Alcotest.(check int)
    "reserved count" 8
    (List.length (List.filter (fun row -> String.equal row.status "reserved") rows));
  check_unique "effect names unique" (List.map (fun row -> row.effect_name) rows);
  check_unique "official index names unique" (List.map (fun row -> row.index_name) rows);
  List.iter
    (fun row ->
      Alcotest.(check string) (row.effect_name ^ " namespace") "official" row.namespace;
      Alcotest.(check bool)
        (row.effect_name ^ " tier") true
        (List.mem row.tier
           [ "control"; "uncertainty"; "meta"; "world"; "model"; "governance"; "concurrency" ]);
      Alcotest.(check bool)
        (row.effect_name ^ " risk") true
        (List.mem row.risk [ "none"; "low"; "medium"; "high"; "special" ]);
      Alcotest.(check bool) (row.effect_name ^ " ring") true (row.ring >= 1 && row.ring <= 3);
      Alcotest.(check bool)
        (row.effect_name ^ " parameters recorded")
        true
        (String.length row.parameters > 0);
      Alcotest.(check bool)
        (row.effect_name ^ " operations recorded")
        true
        (String.length row.operations > 0 && operation_names row.operations <> []);
      Alcotest.(check bool)
        (row.effect_name ^ " reviewer meaning")
        true
        (String.length row.meaning >= 12);
      Alcotest.(check bool)
        (row.effect_name ^ " all Markdown fields match TSV")
        true
        (contains_string doc (markdown_row row));
      match row.status with
      | "implemented" ->
          Alcotest.(check bool)
            (row.effect_name ^ " full interface hash")
            true
            (String.length row.interface_hash = 64
            && String.for_all
                 (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                 row.interface_hash)
      | "reserved" ->
          if String.equal row.effect_name "Async" then
            Alcotest.(check string)
              "Async checker-privileged interface identity" Concurrency_contract.async_effect_hash
              row.interface_hash
          else if String.equal row.effect_name "Channel" then
            Alcotest.(check string)
              "Channel SC.13 interface identity" channel_effect_hash row.interface_hash
          else
            Alcotest.(check string)
              (row.effect_name ^ " first-release policy")
              "first-release" row.interface_hash
      | other -> Alcotest.failf "%s has invalid status %s" row.effect_name other)
    rows

let find effect_name =
  match List.find_opt (fun row -> String.equal row.effect_name effect_name) (rows ()) with
  | Some row -> row
  | None -> Alcotest.failf "missing taxonomy effect %s" effect_name

let prelude_store () =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok store -> store
    | Error diagnostics -> Eval_support.fail_diags "taxonomy store" diagnostics
  in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "taxonomy prelude load" diagnostics);
  store

let test_resolved_reserved_schemas () =
  let expected =
    [
      ("Env", [ "env.get" ]);
      ("Pg", [ "pg.query" ]);
      ("Blob", [ "blob.get"; "blob.put-if-absent"; "blob.exists?" ]);
      ("Serve", [ "serve.next"; "serve.respond" ]);
      ("Crypto", [ "crypto.verify"; "crypto.random" ]);
      ("Log", [ "log.emit" ]);
      ("Async", [ "async.spawn"; "async.await"; "async.cancel"; "async.yield" ]);
    ]
  in
  List.iter
    (fun (effect_name, operations) ->
      let row = find effect_name in
      Alcotest.(check string) (effect_name ^ " remains reserved") "reserved" row.status;
      Alcotest.(check (list string))
        (effect_name ^ " exact operation inventory")
        operations (operation_names row.operations))
    expected;
  Alcotest.(check string)
    "spawn retains Async in the child row" "async.spawn:(()->{Async|e}a)->Task a"
    (List.hd (String.split_on_char ';' (find "Async").operations));
  let declarations = schema_declarations () in
  let executable_expected = expected in
  List.iter
    (fun (effect_name, _) ->
      let expected_row = find effect_name in
      match
        List.find_opt
          (function
            | { Kernel.it = Kernel.DefEffect { ename; _ }; _ } ->
                String.equal ename expected_row.index_name
            | _ -> false)
          declarations
      with
      | Some { Kernel.it = Kernel.DefEffect { ops; _ }; _ } ->
          Alcotest.(check string)
            (effect_name ^ " fixture schema") (compact expected_row.operations)
            (compact (operation_schemas ops));
          List.iter
            (fun op ->
              Alcotest.(check bool)
                (effect_name ^ "." ^ op.Kernel.op_name ^ " fixture mode")
                true (op.op_mode = expected_row.mode))
            ops
      | Some _ -> Alcotest.failf "%s fixture entry is not an effect" effect_name
      | None -> Alcotest.failf "%s is missing from the executable schema fixture" effect_name)
    executable_expected;
  Alcotest.(check bool)
    "Async self-row schema is executable through SC.4" true
    (List.exists
       (function
         | { Kernel.it = Kernel.DefEffect { ename; _ }; _ } -> String.equal ename "async"
         | _ -> false)
       declarations);
  let approval = find "Approval" in
  Alcotest.(check string) "Approval is released" "implemented" approval.status;
  Alcotest.(check string)
    "Approval exact operation schema" "approval.ask:(Proposal)->Decision" approval.operations;
  let judge = find "Judge" in
  Alcotest.(check string) "Judge is released" "implemented" judge.status;
  Alcotest.(check string)
    "Judge exact operation schema" "judge.assess:(Call)->Assessment" judge.operations;
  let doc = Corpus_support.read_file taxonomy_doc in
  let normalized_doc = normalize_whitespace doc in
  List.iter
    (fun obligation ->
      Alcotest.(check bool)
        ("Async implementation obligation: " ^ obligation)
        true
        (contains_string normalized_doc obligation))
    [
      "exact resolved `async.spawn` identity";
      "dependent operation scheme";
      "aliases, higher-order wrappers, returned closures, tuples";
      "SC.3 represents opaque run/scope-local Task values";
      "SC.9 installs the interpreted structured scheduler";
    ];
  let prelude = lazy (prelude_store ()) in
  let constructor_inventory type_name =
    match
      List.find_opt
        (function
          | { Kernel.it = Kernel.DefType { tname; _ }; _ } -> String.equal tname type_name
          | _ -> false)
        declarations
    with
    | Some { Kernel.it = Kernel.DefType { cons; _ }; _ } ->
        List.map (fun con -> con.Kernel.con_name) cons
    | Some _ -> Alcotest.failf "%s fixture entry is not a type" type_name
    | None -> (
        let store = Lazy.force prelude in
        match Store.lookup_kind store type_name Resolve.KType with
        | None -> Alcotest.failf "%s is missing from the fixture and prelude" type_name
        | Some entry -> (
            match Store.locate store entry.hash with
            | Ok { Store.decl = { Kernel.it = Kernel.DefType { cons; _ }; _ }; _ } ->
                List.map (fun con -> con.Kernel.con_name) cons
            | Ok _ -> Alcotest.failf "%s prelude entry is not a type" type_name
            | Error diagnostics ->
                Eval_support.fail_diags ("locate prelude type " ^ type_name) diagnostics))
  in
  List.iter
    (fun (type_name, constructors) ->
      Alcotest.(check (list string))
        (type_name ^ " normative constructor names")
        constructors (constructor_inventory type_name))
    [
      ("risk", [ "low"; "medium"; "high"; "forbidden" ]);
      ("verdict", [ "allow"; "simulate"; "ask"; "block" ]);
      ("authority", [ "effect"; "resource" ]);
      ("call", [ "call" ]);
      ("assessment", [ "assessment" ]);
      ("outcome-summary", [ "outcome-summary" ]);
      ("proposal", [ "proposal" ]);
      ("decision", [ "approved"; "denied"; "escalate" ]);
      ("audit-entry", [ "evaluated"; "consented"; "completed" ]);
      ("secret-ref", [ "secret-ref" ]);
      ("task-result", [ "done"; "failed"; "cancelled" ]);
      ("channel-handle", [ "channel-opaque" ]);
      ("channel-error", [ "channel-closed"; "invalid-capacity" ]);
    ];
  Alcotest.(check bool)
    "Channel effect has no colliding Channel data type" false
    (List.exists
       (function
         | { Kernel.it = Kernel.DefType { tname; _ }; _ } -> String.equal tname "channel"
         | _ -> false)
       declarations);
  Alcotest.(check bool)
    "ChannelHandle data type is present" true
    (List.exists
       (function
         | { Kernel.it = Kernel.DefType { tname; _ }; _ } -> String.equal tname "channel-handle"
         | _ -> false)
       declarations)

let install_schema_fixture store =
  let installed = ref [] in
  schema_declarations ()
  |> List.iter (fun declaration ->
      let resolved =
        match Resolve.resolve_decl (Store.names_view store) declaration with
        | Ok declaration -> declaration
        | Error diagnostics -> Eval_support.fail_diags "resolve taxonomy fixture" diagnostics
      in
      let hashes =
        match Store.put_decl store resolved with
        | Ok hashes -> hashes
        | Error diagnostics -> Eval_support.fail_diags "put taxonomy fixture" diagnostics
      in
      installed := (resolved, hashes) :: !installed);
  List.rev !installed

let frozen_async installed =
  match
    List.find_opt
      (function
        | { Kernel.it = Kernel.DefEffect { ename; _ }; _ }, _ -> String.equal ename "async"
        | _ -> false)
      installed
  with
  | Some pair -> pair
  | None -> Alcotest.fail "resolved taxonomy fixture has no Async declaration"

let frozen_channel installed =
  match
    List.find_opt
      (function
        | { Kernel.it = Kernel.DefEffect { ename; _ }; _ }, _ -> String.equal ename "channel"
        | _ -> false)
      installed
  with
  | Some pair -> pair
  | None -> Alcotest.fail "resolved taxonomy fixture has no Channel declaration"

let frozen_type installed type_name =
  match
    List.find_opt
      (function
        | { Kernel.it = Kernel.DefType { tname; _ }; _ }, _ -> String.equal tname type_name
        | _ -> false)
      installed
  with
  | Some pair -> pair
  | None -> Alcotest.failf "resolved taxonomy fixture has no %s declaration" type_name

let named_hash hashes name =
  match List.assoc_opt name hashes.Canon.named with
  | Some hash -> Hash.to_hex hash
  | None -> Alcotest.failf "frozen declaration has no member named %s" name

let test_channel_interface_hash_contract () =
  let installed = install_schema_fixture (prelude_store ()) in
  let declaration, hashes = frozen_channel installed in
  Alcotest.(check string)
    "Channel declaration hash" channel_effect_hash
    (Hash.to_hex hashes.Canon.decl_hash);
  let operation_hashes =
    [
      ("channel.open", "23f13bd2fd87d17716873bf34c708d6c9a2ddd5f2b4e4f634db6e5d1827b1f07");
      ("channel.send", "348fc5c967097b939360ecb2b066ba22ea8b924834e507c87a0e0f05f26fbfb0");
      ("channel.recv", "db28d70a061da1f1108e01dfaa7e248c4268b9460971c518a9c37f1b51b52860");
      ("channel.close", "ffa22eb01ff7aa206fec56f540b6fd1758b8590e8e797e83f3cbfd295ebce29b");
    ]
  in
  List.iteri
    (fun ordinal (name, expected) ->
      Alcotest.(check string)
        (name ^ " derived hash") expected
        (Hash.to_hex (Canon.op_hash hashes.decl_hash ordinal));
      Alcotest.(check string) (name ^ " indexed hash") expected (named_hash hashes name))
    operation_hashes;
  (match declaration.it with
  | Kernel.DefEffect { ops; _ } ->
      Alcotest.(check (list string))
        "Channel operation modes"
        [ "once"; "once"; "once"; "once" ]
        (List.map (fun op -> mode_name op.Kernel.op_mode) ops)
  | _ -> Alcotest.fail "frozen Channel declaration is not an effect");
  let check_type type_name expected_decl expected_members =
    let _, type_hashes = frozen_type installed type_name in
    Alcotest.(check string)
      (type_name ^ " declaration hash") expected_decl
      (Hash.to_hex type_hashes.Canon.decl_hash);
    List.iter
      (fun (name, expected) ->
        Alcotest.(check string) (name ^ " constructor hash") expected (named_hash type_hashes name))
      expected_members
  in
  check_type "channel-handle" "f4f5601a435906a47faedae9006e44b874146f3ad4b586bf9d04535be14dccb4"
    [ ("channel-opaque", "dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36") ];
  check_type "channel-error" "25dc8f513c91c80fd6d33e843fc3f6cab183800805f46e269f716155149b4da7"
    [
      ("channel-closed", "de3da3e601fbba2c66864b87c6848d8224411df99f1967e132aaa166c1a3f3a9");
      ("invalid-capacity", "01b719cb597275f097c2c36b5e86b3d71604eb531fe00ef66d9c93ec3f55acfb");
    ];
  let check_trace path header expected_hash expected_events =
    let contents = Corpus_support.read_file path in
    Alcotest.(check string)
      (path ^ " content hash") expected_hash
      (Hash.to_hex (Hash.of_string contents));
    match String.split_on_char '\n' contents |> List.filter (fun line -> line <> "") with
    | actual_header :: decisions ->
        Alcotest.(check string) (path ^ " header") header actual_header;
        let actual_events = List.map (parse_channel_trace_event path) decisions in
        Alcotest.(check int)
          (path ^ " event count") (List.length expected_events) (List.length actual_events);
        List.iter2
          (fun expected actual ->
            let label = Printf.sprintf "%s decision %d" path expected.decision in
            Alcotest.(check int) (label ^ " contiguous decision") expected.decision actual.decision;
            Alcotest.(check string) (label ^ " chosen task") expected.task actual.task;
            Alcotest.(check string) (label ^ " operation") expected.operation actual.operation;
            Alcotest.(check string) (label ^ " before state") expected.before actual.before;
            Alcotest.(check string) (label ^ " action") expected.action actual.action;
            Alcotest.(check string) (label ^ " after state") expected.after actual.after;
            Alcotest.(check string) (label ^ " result") expected.result actual.result;
            Alcotest.(check string) (label ^ " wake order") expected.wake actual.wake)
          expected_events actual_events
    | [] -> Alcotest.failf "%s is empty" path
  in
  check_trace "../corpus/channel/rendezvous-v1.trace"
    "jacquard-channel-contract format=1 scenario=rendezvous channel=0@0 capacity=0"
    "da61f5bce576aa1660d0db7f249a26f58297497feab2bf7c49cf3c5d712fd383"
    [
      {
        decision = 0;
        task = "0#0";
        operation = "open:-1";
        before = "-";
        action = "reject-capacity";
        after = "-";
        result = "error:invalid-capacity:-1";
        wake = "0#0";
      };
      {
        decision = 1;
        task = "0#0";
        operation = "open:0";
        before = "-";
        action = "create";
        after = "open|buffer=-|senders=-|receivers=-";
        result = "ok:0@0";
        wake = "0#0";
      };
      {
        decision = 2;
        task = "0#1";
        operation = "send:7";
        before = "open|buffer=-|senders=-|receivers=-";
        action = "block-sender";
        after = "open|buffer=-|senders=0#1:7|receivers=-";
        result = "pending";
        wake = "-";
      };
      {
        decision = 3;
        task = "0#2";
        operation = "recv";
        before = "open|buffer=-|senders=0#1:7|receivers=-";
        action = "rendezvous:0#1";
        after = "open|buffer=-|senders=-|receivers=-";
        result = "receiver-ok:7,sender-ok:unit";
        wake = "0#1,0#2";
      };
      {
        decision = 4;
        task = "0#3";
        operation = "recv";
        before = "open|buffer=-|senders=-|receivers=-";
        action = "block-receiver";
        after = "open|buffer=-|senders=-|receivers=0#3";
        result = "pending";
        wake = "-";
      };
      {
        decision = 5;
        task = "0#4";
        operation = "recv";
        before = "open|buffer=-|senders=-|receivers=0#3";
        action = "block-receiver";
        after = "open|buffer=-|senders=-|receivers=0#3,0#4";
        result = "pending";
        wake = "-";
      };
      {
        decision = 6;
        task = "0#0";
        operation = "cancel:0#3";
        before = "open|buffer=-|senders=-|receivers=0#3,0#4";
        action = "cancel-receiver:0#3";
        after = "open|buffer=-|senders=-|receivers=0#4";
        result = "unit,target-cancelled";
        wake = "0#0";
      };
      {
        decision = 7;
        task = "0#0";
        operation = "close";
        before = "open|buffer=-|senders=-|receivers=0#4";
        action = "close,reject-receivers";
        after = "closed|buffer=-|senders=-|receivers=-";
        result = "closer-unit,receiver-error:0#4:channel-closed";
        wake = "0#4,0#0";
      };
      {
        decision = 8;
        task = "0#2";
        operation = "recv";
        before = "closed|buffer=-|senders=-|receivers=-";
        action = "closed-empty";
        after = "closed|buffer=-|senders=-|receivers=-";
        result = "error:channel-closed";
        wake = "0#2";
      };
      {
        decision = 9;
        task = "0#0";
        operation = "close";
        before = "closed|buffer=-|senders=-|receivers=-";
        action = "already-closed";
        after = "closed|buffer=-|senders=-|receivers=-";
        result = "unit";
        wake = "0#0";
      };
    ];
  check_trace "../corpus/channel/buffered-v1.trace"
    "jacquard-channel-contract format=1 scenario=buffered channel=0@0 capacity=2"
    "691f852482a0d69742c0ecf0cbb283fcf2dd6367117089acec306f19385713a2"
    [
      {
        decision = 0;
        task = "0#0";
        operation = "open:2";
        before = "-";
        action = "create";
        after = "open|buffer=-|senders=-|receivers=-";
        result = "ok:0@0";
        wake = "0#0";
      };
      {
        decision = 1;
        task = "0#1";
        operation = "send:a";
        before = "open|buffer=-|senders=-|receivers=-";
        action = "buffer";
        after = "open|buffer=a|senders=-|receivers=-";
        result = "ok:unit";
        wake = "0#1";
      };
      {
        decision = 2;
        task = "0#2";
        operation = "send:b";
        before = "open|buffer=a|senders=-|receivers=-";
        action = "buffer";
        after = "open|buffer=a,b|senders=-|receivers=-";
        result = "ok:unit";
        wake = "0#2";
      };
      {
        decision = 3;
        task = "0#3";
        operation = "send:c";
        before = "open|buffer=a,b|senders=-|receivers=-";
        action = "block-sender";
        after = "open|buffer=a,b|senders=0#3:c|receivers=-";
        result = "pending";
        wake = "-";
      };
      {
        decision = 4;
        task = "0#4";
        operation = "recv";
        before = "open|buffer=a,b|senders=0#3:c|receivers=-";
        action = "dequeue:a,promote:0#3:c";
        after = "open|buffer=b,c|senders=-|receivers=-";
        result = "receiver-ok:a,sender-ok:unit";
        wake = "0#3,0#4";
      };
      {
        decision = 5;
        task = "0#5";
        operation = "send:d";
        before = "open|buffer=b,c|senders=-|receivers=-";
        action = "block-sender";
        after = "open|buffer=b,c|senders=0#5:d|receivers=-";
        result = "pending";
        wake = "-";
      };
      {
        decision = 6;
        task = "0#6";
        operation = "send:e";
        before = "open|buffer=b,c|senders=0#5:d|receivers=-";
        action = "block-sender";
        after = "open|buffer=b,c|senders=0#5:d,0#6:e|receivers=-";
        result = "pending";
        wake = "-";
      };
      {
        decision = 7;
        task = "0#0";
        operation = "cancel:0#5";
        before = "open|buffer=b,c|senders=0#5:d,0#6:e|receivers=-";
        action = "cancel-sender:0#5-drop:d";
        after = "open|buffer=b,c|senders=0#6:e|receivers=-";
        result = "unit,target-cancelled";
        wake = "0#0";
      };
      {
        decision = 8;
        task = "0#7";
        operation = "send:f";
        before = "open|buffer=b,c|senders=0#6:e|receivers=-";
        action = "block-sender";
        after = "open|buffer=b,c|senders=0#6:e,0#7:f|receivers=-";
        result = "pending";
        wake = "-";
      };
      {
        decision = 9;
        task = "0#0";
        operation = "close";
        before = "open|buffer=b,c|senders=0#6:e,0#7:f|receivers=-";
        action = "close,reject-senders";
        after = "closed|buffer=b,c|senders=-|receivers=-";
        result = "closer-unit,sender-error:0#6:channel-closed,sender-error:0#7:channel-closed";
        wake = "0#6,0#7,0#0";
      };
      {
        decision = 10;
        task = "0#4";
        operation = "recv";
        before = "closed|buffer=b,c|senders=-|receivers=-";
        action = "drain:b";
        after = "closed|buffer=c|senders=-|receivers=-";
        result = "ok:b";
        wake = "0#4";
      };
      {
        decision = 11;
        task = "0#4";
        operation = "recv";
        before = "closed|buffer=c|senders=-|receivers=-";
        action = "drain:c";
        after = "closed|buffer=-|senders=-|receivers=-";
        result = "ok:c";
        wake = "0#4";
      };
      {
        decision = 12;
        task = "0#4";
        operation = "recv";
        before = "closed|buffer=-|senders=-|receivers=-";
        action = "closed-empty";
        after = "closed|buffer=-|senders=-|receivers=-";
        result = "error:channel-closed";
        wake = "0#4";
      };
    ];
  let concurrency = Corpus_support.read_file concurrency_doc |> normalize_whitespace in
  let documented_hashes =
    [
      channel_effect_hash;
      "f4f5601a435906a47faedae9006e44b874146f3ad4b586bf9d04535be14dccb4";
      "dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36";
      "25dc8f513c91c80fd6d33e843fc3f6cab183800805f46e269f716155149b4da7";
      "de3da3e601fbba2c66864b87c6848d8224411df99f1967e132aaa166c1a3f3a9";
      "01b719cb597275f097c2c36b5e86b3d71604eb531fe00ef66d9c93ec3f55acfb";
    ]
    @ List.map snd operation_hashes
  in
  List.iter
    (fun hash ->
      Alcotest.(check bool)
        ("SC.13 documented identity: " ^ hash)
        true
        (contains_string concurrency hash))
    documented_hashes;
  List.iter
    (fun obligation ->
      Alcotest.(check bool)
        ("SC.13 checklist: " ^ obligation)
        true
        (contains_string concurrency obligation))
    [
      "exact-identity scheduler admission";
      "--allow channel` remains invalid";
      "typed negative-capacity result before allocation";
      "idempotent drain-on-close";
      "cancellation-before-mutation";
      "blocked-receiver cancellation and close";
      "blocked-sender cancellation, survivor order";
      "exact run/scope ownership";
      "policy-independent all-suspended/at-least-one-channel-blocked E0908 refusal";
      "actors, mailboxes, links, monitors, supervision";
    ]

let hex_bytes bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let byte = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4] else alphabet.[byte land 0x0f])

let effect_bytes (declaration : Kernel.decl) =
  match declaration.it with
  | Kernel.DefEffect { ename; evars; ops } -> (
      match Canon.canonical_effect_bytes ~ename ~evars ~ops with
      | Ok bytes -> bytes
      | Error diagnostics -> Eval_support.fail_diags "canonical effect bytes" diagnostics)
  | _ -> Alcotest.fail "expected effect declaration"

let test_self_effect_hash_contract () =
  let store = prelude_store () in
  let declaration, hashes = frozen_async (install_schema_fixture store) in
  let bytes = effect_bytes declaration in
  Alcotest.(check string)
    "self-effect 0x38 declaration hash" Concurrency_contract.async_effect_hash
    (Hash.to_hex hashes.decl_hash);
  Alcotest.(check string)
    "self-effect 0x38 pinned payload bytes"
    "42056173796e630104460b6173796e632e737061776e01330038010001000165310100323007791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb30131010001460b6173796e632e617761697401323007791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3013101003230915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae0131010001460c6173796e632e63616e63656c01323007791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb301310100340001460b6173796e632e7969656c6400340001"
    (hex_bytes bytes);
  Alcotest.(check bool)
    "self-effect payload contains 0x38" true
    (String.contains bytes (Char.chr 0x38));
  let spawn_parameter =
    match declaration.it with
    | Kernel.DefEffect { ops = { Kernel.op_params = [ parameter ]; _ } :: _; _ } -> parameter
    | _ -> Alcotest.fail "frozen Async spawn parameter shape changed"
  in
  let spawn_row =
    match spawn_parameter.it with
    | Kernel.TArrow ([], row, _) -> row
    | _ -> Alcotest.fail "frozen Async thunk shape changed"
  in
  Alcotest.(check bool)
    "resolver preserves enclosing self effect as Named" true
    (spawn_row.effects = [ Kernel.Named "async" ] && spawn_row.rvar = Some "e");
  let mutate_spawn_row change =
    match declaration.it with
    | Kernel.DefEffect { ename; evars; ops = spawn :: rest } ->
        let spawn =
          match spawn.op_params with
          | [ parameter ] ->
              let parameter =
                match parameter.it with
                | Kernel.TArrow (parameters, row, result) ->
                    { parameter with it = Kernel.TArrow (parameters, change row, result) }
                | _ -> Alcotest.fail "frozen Async thunk shape changed"
              in
              { spawn with op_params = [ parameter ] }
          | _ -> Alcotest.fail "frozen Async spawn shape changed"
        in
        { declaration with it = Kernel.DefEffect { ename; evars; ops = spawn :: rest } }
    | _ -> Alcotest.fail "frozen Async declaration shape changed"
  in
  let closed = mutate_spawn_row (fun row -> { row with Kernel.rvar = None }) in
  let net_hash =
    match Store.lookup_kind store "net" Resolve.KEffect with
    | Some entry -> entry.hash
    | None -> Alcotest.fail "prelude has no Net effect"
  in
  let mixed =
    mutate_spawn_row (fun row ->
        { row with Kernel.effects = row.effects @ [ Kernel.Hashed net_hash ] })
  in
  let decl_hash declaration =
    match Canon.hash_decl declaration with
    | Ok hashes -> hashes.decl_hash
    | Error diagnostics -> Eval_support.fail_diags "hash self-effect mutation" diagnostics
  in
  let open_hash = hashes.decl_hash in
  let closed_hash = decl_hash closed in
  let mixed_hash = decl_hash mixed in
  Alcotest.(check bool)
    "self open and closed rows are distinct" true
    (not (Hash.equal open_hash closed_hash));
  Alcotest.(check bool)
    "self open and mixed rows are distinct" true
    (not (Hash.equal open_hash mixed_hash));
  Alcotest.(check bool)
    "self closed and mixed rows are distinct" true
    (not (Hash.equal closed_hash mixed_hash));
  let abort =
    match Store.lookup_kind store "abort" Resolve.KEffect with
    | Some entry -> (
        match Store.get store entry.hash with
        | Ok declaration -> declaration
        | Error diagnostics -> Eval_support.fail_diags "get Abort" diagnostics)
    | None -> Alcotest.fail "prelude has no Abort effect"
  in
  Alcotest.(check string)
    "legacy 0x36 declaration hash unchanged"
    "bfdfaeee39c6f5290ebea28e805bdeb92f448f1a1e0b9c47f3c70c53975b4375"
    (Hash.to_hex (decl_hash abort));
  Alcotest.(check string)
    "legacy effect pinned payload bytes" "420561626f72740101460561626f72740031010001"
    (hex_bytes (effect_bytes abort));
  Alcotest.(check bool)
    "legacy payload does not use 0x38" false
    (String.contains (effect_bytes abort) (Char.chr 0x38));
  let printed = Printer.print_all [ Kernel.decl_to_form declaration ] in
  let reparsed =
    match Reader.parse_one ~file:"async-roundtrip.jqd" printed with
    | Error diagnostics -> Eval_support.fail_diags "parse Async roundtrip" diagnostics
    | Ok form -> (
        match Kernel.decl_of_form form with
        | Ok declaration -> declaration
        | Error diagnostics -> Eval_support.fail_diags "validate Async roundtrip" diagnostics)
  in
  Alcotest.(check string)
    "printer/reader preserves self-effect hash" Concurrency_contract.async_effect_hash
    (Hash.to_hex (decl_hash reparsed));
  let malformed =
    match
      Reader.parse_one ~file:"malformed-self.jqd"
        "(deftype bad () (con bad-c (field (tarrow () (row (eref task)) (ttuple)))))"
    with
    | Error diagnostics -> Eval_support.fail_diags "parse malformed self context" diagnostics
    | Ok form -> (
        match Kernel.decl_of_form form with
        | Ok declaration -> declaration
        | Error diagnostics -> Eval_support.fail_diags "validate malformed self context" diagnostics
        )
  in
  (match Resolve.resolve_decl (Store.names_view store) malformed with
  | Error [ diagnostic ] ->
      Alcotest.(check string)
        "type used as effect rejected by resolver" "E0302" (Diag.code_or_uncoded diagnostic)
  | Error diagnostics ->
      Eval_support.fail_diags "unexpected malformed-context diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "type used as an effect unexpectedly resolved");
  (match Canon.hash_decl malformed with
  | Error [ diagnostic ] ->
      Alcotest.(check string)
        "Named row outside enclosing effect rejected by canon" "E0501"
        (Diag.code_or_uncoded diagnostic)
  | Error diagnostics -> Eval_support.fail_diags "unexpected malformed hash diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "malformed Named effect unexpectedly hashed");
  let reopen_dir = Eval_support.fresh_dir () in
  let reopen_store =
    match Store.open_store reopen_dir with
    | Ok store -> store
    | Error diagnostics -> Eval_support.fail_diags "open self-effect store" diagnostics
  in
  (match Prelude.load ~dir:"../prelude" reopen_store with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "load self-effect store prelude" diagnostics);
  let _, persisted = frozen_async (install_schema_fixture reopen_store) in
  let reopened =
    match Store.open_store reopen_dir with
    | Ok store -> store
    | Error diagnostics -> Eval_support.fail_diags "reopen self-effect store" diagnostics
  in
  match Store.get reopened persisted.decl_hash with
  | Ok persisted_decl ->
      Alcotest.(check string)
        "store put/get/reopen preserves self-effect hash" Concurrency_contract.async_effect_hash
        (Hash.to_hex (decl_hash persisted_decl))
  | Error diagnostics -> Eval_support.fail_diags "get reopened self-effect" diagnostics

let test_async_privilege_mutations () =
  let store = prelude_store () in
  let declaration, hashes = frozen_async (install_schema_fixture store) in
  let ctx =
    match Check.make_ctx store with
    | Ok ctx -> ctx
    | Error diagnostics -> Eval_support.fail_diags "make checker" diagnostics
  in
  let exact_spawn = Canon.op_hash hashes.decl_hash 0 in
  Alcotest.(check bool)
    "exact frozen Async spawn is privileged" true
    (Check.is_frozen_async_spawn ctx exact_spawn);
  Alcotest.(check string)
    "Task nominal identity is pinned" Concurrency_contract.task_type_hash
    (match Store.lookup_kind store "task" Resolve.KType with
    | Some entry -> Hash.to_hex entry.hash
    | None -> Alcotest.fail "missing Task identity");
  Alcotest.(check string)
    "TaskResult nominal identity is pinned" Concurrency_contract.task_result_type_hash
    (match Store.lookup_kind store "task-result" Resolve.KType with
    | Some entry -> Hash.to_hex entry.hash
    | None -> Alcotest.fail "missing TaskResult identity");
  let mutate_effect change =
    match declaration.it with
    | Kernel.DefEffect { ename; evars; ops } ->
        let changed = change { ename; evars; ops } in
        {
          declaration with
          it = Kernel.DefEffect { ename = changed.ename; evars = changed.evars; ops = changed.ops };
        }
    | _ -> Alcotest.fail "Async fixture is not an effect"
  in
  let map_nth index change items =
    List.mapi (fun actual item -> if actual = index then change item else item) items
  in
  let change_op index change shape = { shape with ops = map_nth index change shape.ops } in
  let change_ty ty it = { ty with Kernel.it } in
  let change_spawn_parameter change op =
    match op.Kernel.op_params with
    | [ parameter ] -> { op with op_params = [ change parameter ] }
    | _ -> Alcotest.fail "frozen spawn parameter shape changed"
  in
  let change_spawn_arrow change parameter =
    match parameter.Kernel.it with
    | Kernel.TArrow (parameters, row, result) ->
        let parameters, row, result = change (parameters, row, result) in
        change_ty parameter (Kernel.TArrow (parameters, row, result))
    | _ -> Alcotest.fail "frozen spawn thunk shape changed"
  in
  let task_result_hash =
    match Hash.of_hex Concurrency_contract.task_result_type_hash with
    | Some hash -> hash
    | None -> Alcotest.fail "invalid pinned TaskResult hash"
  in
  let task_hash =
    match Hash.of_hex Concurrency_contract.task_type_hash with
    | Some hash -> hash
    | None -> Alcotest.fail "invalid pinned Task hash"
  in
  let replace_app_head replacement ty =
    match ty.Kernel.it with
    | Kernel.TApp (head, arguments) ->
        change_ty ty
          (Kernel.TApp (change_ty head (Kernel.TRef (Kernel.Hashed replacement)), arguments))
    | _ -> Alcotest.fail "frozen Task application shape changed"
  in
  let wrong_task = replace_app_head task_result_hash in
  let wrong_task_result = replace_app_head task_hash in
  let wrong_app_argument ty =
    match ty.Kernel.it with
    | Kernel.TApp (head, [ argument ]) ->
        change_ty ty (Kernel.TApp (head, [ change_ty argument (Kernel.TVar "b") ]))
    | _ -> Alcotest.fail "frozen unary type application shape changed"
  in
  let rename_effect shape =
    let shape = { shape with ename = "not-async" } in
    change_op 0
      (change_spawn_parameter
         (change_spawn_arrow (fun (parameters, row, result) ->
              let effects =
                List.map
                  (function
                    | Kernel.Named "async" -> Kernel.Named "not-async" | reference -> reference)
                  row.Kernel.effects
              in
              (parameters, { row with Kernel.effects }, result))))
      shape
  in
  let mutations =
    [
      ("non-Async name with otherwise exact shape", mutate_effect rename_effect);
      ("extra effect variable", mutate_effect (fun shape -> { shape with evars = [ "a"; "b" ] }));
      ("missing operation", mutate_effect (fun shape -> { shape with ops = List.tl shape.ops }));
      ("extra operation", mutate_effect (fun shape -> { shape with ops = shape.ops @ shape.ops }));
      ("operation order", mutate_effect (fun shape -> { shape with ops = List.rev shape.ops }));
      ( "spawn name",
        mutate_effect (change_op 0 (fun op -> { op with Kernel.op_name = "not-spawn" })) );
      ( "await name",
        mutate_effect (change_op 1 (fun op -> { op with Kernel.op_name = "not-await" })) );
      ( "cancel name",
        mutate_effect (change_op 2 (fun op -> { op with Kernel.op_name = "not-cancel" })) );
      ( "yield name",
        mutate_effect (change_op 3 (fun op -> { op with Kernel.op_name = "not-yield" })) );
      ( "spawn mode",
        mutate_effect (change_op 0 (fun op -> { op with Kernel.op_mode = Kernel.Multi })) );
      ( "await mode",
        mutate_effect (change_op 1 (fun op -> { op with Kernel.op_mode = Kernel.Multi })) );
      ( "cancel mode",
        mutate_effect (change_op 2 (fun op -> { op with Kernel.op_mode = Kernel.Multi })) );
      ( "yield mode",
        mutate_effect (change_op 3 (fun op -> { op with Kernel.op_mode = Kernel.Multi })) );
      ( "spawn thunk arity",
        mutate_effect
          (change_op 0
             (change_spawn_parameter
                (change_spawn_arrow (fun (_, row, result) -> ([ result ], row, result))))) );
      ( "spawn closed self row",
        mutate_effect
          (change_op 0
             (change_spawn_parameter
                (change_spawn_arrow (fun (parameters, row, result) ->
                     (parameters, { row with Kernel.rvar = None }, result))))) );
      ( "spawn mixed self row",
        mutate_effect
          (change_op 0
             (change_spawn_parameter
                (change_spawn_arrow (fun (parameters, row, result) ->
                     (parameters, { row with Kernel.effects = row.effects @ row.effects }, result)))))
      );
      ( "spawn result variable linkage",
        mutate_effect
          (change_op 0
             (change_spawn_parameter
                (change_spawn_arrow (fun (parameters, row, result) ->
                     (parameters, row, change_ty result (Kernel.TVar "b")))))) );
      ( "spawn Task identity",
        mutate_effect
          (change_op 0 (fun op -> { op with Kernel.op_result = wrong_task op.op_result })) );
      ( "spawn Task argument linkage",
        mutate_effect
          (change_op 0 (fun op -> { op with Kernel.op_result = wrong_app_argument op.op_result }))
      );
      ( "await Task identity",
        mutate_effect
          (change_op 1 (fun op -> { op with Kernel.op_params = List.map wrong_task op.op_params }))
      );
      ( "await TaskResult identity",
        mutate_effect
          (change_op 1 (fun op -> { op with Kernel.op_result = wrong_task_result op.op_result })) );
      ( "cancel result",
        mutate_effect
          (change_op 2 (fun op -> { op with Kernel.op_result = List.hd op.Kernel.op_params })) );
      ( "yield parameters",
        mutate_effect (change_op 3 (fun op -> { op with Kernel.op_params = [ op.op_result ] })) );
      ( "yield result",
        mutate_effect
          (change_op 3 (fun op ->
               { op with Kernel.op_result = change_ty op.op_result (Kernel.TVar "a") })) );
    ]
  in
  List.iter
    (fun (label, mutated) ->
      match Store.put_decl store mutated with
      | Error diagnostics -> Eval_support.fail_diags ("put Async mutation " ^ label) diagnostics
      | Ok mutation_hashes ->
          Alcotest.(check bool)
            (label ^ " is not privileged") false
            (Check.is_frozen_async_spawn ctx (Canon.op_hash mutation_hashes.decl_hash 0)))
    mutations

let test_implemented_interfaces_match_prelude () =
  let store = prelude_store () in
  let rings = Corpus_support.parse_rings "../prelude/rings.manifest" in
  rows ()
  |> List.filter (fun row -> String.equal row.status "implemented")
  |> List.iter (fun row ->
      let entry =
        match Store.lookup_kind store row.index_name Resolve.KEffect with
        | Some entry -> entry
        | None -> Alcotest.failf "implemented effect %s missing from prelude" row.effect_name
      in
      Alcotest.(check string)
        (row.effect_name ^ " interface identity")
        row.interface_hash (Hash.to_hex entry.hash);
      (match Store.locate store entry.hash with
      | Ok
          {
            Store.decl_hash;
            decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ };
            role = Store.Whole;
            _;
          } ->
          let expected_ops = resolved_taxonomy_effect store row in
          Alcotest.(check string)
            (row.effect_name ^ " located declaration hash")
            row.interface_hash (Hash.to_hex decl_hash);
          Alcotest.(check (list string))
            (row.effect_name ^ " operation names")
            (implementation_operation_names row)
            (List.map (fun (op : Kernel.opspec) -> op.op_name) ops);
          Alcotest.(check bool)
            (row.effect_name ^ " exact resolved parameter and result schemas")
            true
            (List.equal same_opspec expected_ops ops);
          List.iter
            (fun (op : Kernel.opspec) ->
              Alcotest.(check bool)
                (row.effect_name ^ "." ^ op.op_name ^ " mode")
                true (op.op_mode = row.mode))
            ops
      | Ok _ -> Alcotest.failf "%s does not locate to a whole effect" row.effect_name
      | Error diagnostics -> Eval_support.fail_diags ("locate " ^ row.effect_name) diagnostics);
      match List.assoc_opt row.index_name rings with
      | Some ring -> Alcotest.(check int) (row.effect_name ^ " ring") row.ring ring
      | None -> Alcotest.failf "%s is absent from rings.manifest" row.effect_name)

let test_stale_hash_cannot_mask_schema_drift () =
  let store = prelude_store () in
  let released = find "Net" in
  let drifted = { released with operations = "fetch:(Text)->Response" } in
  Alcotest.(check string)
    "coordinated documentation drift retains the stale frozen hash" released.interface_hash
    drifted.interface_hash;
  let actual_ops =
    match Store.lookup_kind store released.index_name Resolve.KEffect with
    | None -> Alcotest.fail "released Net effect is missing from the prelude"
    | Some entry -> (
        Alcotest.(check string)
          "stale frozen hash still matches the live declaration" drifted.interface_hash
          (Hash.to_hex entry.hash);
        match Store.locate store entry.hash with
        | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Whole; _ }
          ->
            ops
        | Ok _ -> Alcotest.fail "released Net identity is not a whole effect declaration"
        | Error diagnostics -> Eval_support.fail_diags "locate released Net" diagnostics)
  in
  let drifted_ops = resolved_taxonomy_effect store drifted in
  Alcotest.(check bool)
    "stale interface hash cannot excuse a changed parameter type" false
    (List.equal same_opspec drifted_ops actual_ops)

let lowercase = String.lowercase_ascii

let test_governance_and_links () =
  test_self_effect_hash_contract ();
  test_async_privilege_mutations ();
  let doc = Corpus_support.read_file taxonomy_doc in
  let manifest = Corpus_support.read_file taxonomy_file in
  let approval = Corpus_support.read_file approval_fixture in
  let review = Corpus_support.read_file review_doc in
  let stdlib = Corpus_support.read_file stdlib_doc in
  let tutorial = Corpus_support.read_file tutorial_doc in
  Alcotest.(check bool)
    "no unresolved schema marker in taxonomy" false
    (contains_string (lowercase (doc ^ manifest)) "tbd");
  List.iter
    (fun decision ->
      Alcotest.(check bool)
        (decision ^ " indexed") true
        (try
           ignore (Str.search_forward (Str.regexp_string ("| " ^ decision ^ " |")) doc 0);
           true
         with Not_found -> false))
    [ "D56"; "D57"; "D58"; "D59"; "D60"; "D61"; "D62"; "D63" ];
  let concurrency = Corpus_support.read_file concurrency_doc in
  List.iter
    (fun decision ->
      Alcotest.(check bool)
        (decision ^ " concurrency decision indexed")
        true
        (contains_string concurrency ("| " ^ decision ^ " |")))
    [ "D46"; "D47"; "D48"; "D49"; "D50" ];
  List.iter
    (fun phrase ->
      Alcotest.(check bool)
        ("governance contract: " ^ phrase)
        true
        (try
           ignore (Str.search_forward (Str.regexp_string phrase) doc 0);
           true
         with Not_found -> false))
    [
      "no universal stringly `Tool.call`";
      "never `Host`";
      "publisher-scoped";
      "built-in risk color";
      "any change to that structure produces a new declaration hash";
    ];
  Alcotest.(check bool)
    "dry-run Approval escalates with the exact proposal binding" true
    (contains_string approval "approval.dry-run(fn () -> match `op:ask`(proposal-value)");
  Alcotest.(check bool)
    "dry-run Approval never fabricates Approved" false
    (contains_string approval "continue(Approved");
  let implemented =
    rows ()
    |> List.filter (fun row -> String.equal row.status "implemented")
    |> List.map (fun row -> row.effect_name)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "every implemented effect has one canonical boundary contract" implemented
    (handler_contracts
    |> List.map (fun contract -> contract.handled_effect)
    |> List.sort String.compare);
  let store = prelude_store () in
  List.iter
    (fun contract ->
      let expected_row = Printf.sprintf "| `%s` | %s |" contract.handled_effect contract.boundary in
      Alcotest.(check bool)
        (contract.handled_effect ^ " canonical boundary is documented")
        true
        (contains_string doc expected_row);
      List.iter
        (fun term ->
          Alcotest.(check bool)
            (term ^ " canonical handler exists in the prelude")
            true
            (Store.lookup_kind store term Resolve.KTerm <> None))
        contract.terms)
    handler_contracts;
  let root_grants =
    handler_contracts
    |> List.filter_map (fun contract ->
        if contract.root_grant then Some (find contract.handled_effect).index_name else None)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "documented root boundaries exactly match grantable names"
    (List.sort String.compare Prelude.grantable_names)
    root_grants;
  Alcotest.(check bool)
    "async.scope is the only shipped Jacquard scope term" true
    (Store.lookup_kind store "async.scope" Resolve.KTerm <> None);
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " remains an unbound OCaml contract schema")
        true
        (Store.lookup_kind store name Resolve.KTerm = None))
    [ "async.scope-fail-fast"; "async.scope-collect" ];
  let concurrency = normalize_whitespace concurrency in
  List.iter
    (fun phrase ->
      Alcotest.(check bool)
        ("scope reachability contract: " ^ phrase)
        true
        (contains_string concurrency phrase))
    [
      "Jacquard 0.1 binds only `async.scope`";
      "`async.scope-fail-fast` and `async.scope-collect` are contract schemas, not Jacquard term \
       bindings";
      "Collect is explicit only at the OCaml library seam";
    ];
  let reserved =
    rows ()
    |> List.filter (fun row -> String.equal row.status "reserved")
    |> List.map (fun row -> row.effect_name)
  in
  Alcotest.(check (list string))
    "schema-reserved inventory is exact" schema_reserved_effects reserved;
  let reserved_csv =
    String.concat ", " (List.map (fun name -> "`" ^ name ^ "`") unimplemented_reserved_effects)
  in
  let reserved_prose =
    match List.rev unimplemented_reserved_effects with
    | final :: reversed_rest ->
        String.concat ", " (List.rev_map (fun name -> "`" ^ name ^ "`") reversed_rest)
        ^ ", and `" ^ final ^ "`"
    | [] -> Alcotest.fail "reserved inventory unexpectedly empty"
  in
  List.iter
    (fun (label, source) ->
      let source = normalize_whitespace source in
      Alcotest.(check bool)
        (label ^ " labels every future effect reserved/unimplemented")
        true
        (contains_string source reserved_prose
        && contains_string (lowercase source) "reserved"
        && contains_string (lowercase source) "unimplemented"))
    [ ("taxonomy", doc); ("review guide", review); ("tutorial", tutorial) ];
  List.iter
    (fun row ->
      if String.equal row.status "implemented" then
        Alcotest.(check bool)
          (row.effect_name ^ " full hash is pinned in review tooling docs")
          true
          (contains_string review
             (Printf.sprintf "| `%s` | `%s` |" row.effect_name row.interface_hash)))
    (rows ());
  Alcotest.(check bool)
    "stdlib implemented inventory is exact" true
    (contains_string stdlib
       "| implemented (18) | `Abort`, `Throw`, `State`, `Emit`, `Dist`, `Fault`, `Eval`, \
        `Console`, `Clock`, `Fs`, `Net`, `Workspace`, `Infer`, `Approval`, `Audit`, `Secret`, \
        `Judge`, `Channel` |");
  Alcotest.(check bool)
    "stdlib unimplemented reserved inventory is exact" true
    (contains_string stdlib ("| reserved/unimplemented (7) | " ^ reserved_csv ^ " |"));
  Alcotest.(check bool)
    "stdlib published reserved identities are exact" true
    (contains_string stdlib "| reserved with published identity (1) | `Async` |");
  List.iter
    (fun phrase ->
      Alcotest.(check bool)
        ("review caveat: " ^ phrase) true
        (contains_string (normalize_whitespace (doc ^ review ^ tutorial)) phrase))
    [
      "Risk defaults are review-routing metadata, not permissions or guarantees";
      "`Dist` is authority-free but not uncertainty-free";
      "evidence, not consent";
      "Secret opacity is not taint tracking";
      "A reserved schema alone is compatibility vocabulary, not an implementation";
    ];
  let linked =
    [
      "../spec/effect-taxonomy-v1.tsv";
      "effect-review.md";
      "release/structured-concurrency/EVIDENCE.md";
      "release/structured-concurrency/MANIFEST.sha256";
    ]
  in
  List.iter
    (fun path ->
      let resolved = Filename.concat "../docs" path in
      Alcotest.(check bool) ("linked file exists: " ^ path) true (Sys.file_exists resolved))
    linked;

  let open Concurrency_contract in
  let parent = task_id ~scope_path:[ 0 ] ~spawn_index:0 in
  let child = task_id ~scope_path:[ 0 ] ~spawn_index:1 in
  Alcotest.(check bool) "fail-fast is the default" true (default_failure_policy = Fail_fast);
  Alcotest.(check string) "task escape code" "E0907" task_escape_code;
  Alcotest.(check string)
    "self-await diagnostic is exact" "async deadlock: task 0#0 awaited itself"
    (self_await_message parent);
  Alcotest.(check string)
    "wait-cycle diagnostic is exact" "async deadlock: await cycle 0#0 -> 0#1 -> 0#0"
    (wait_cycle_message [ parent; child; parent ]);
  Alcotest.(check int) "child follows parent in stable ID order" (-1) (compare_task_id parent child);
  Alcotest.(check string) "task trace spelling" "0#1" (trace_task_id child);
  Alcotest.(check (list string))
    "OCaml Async and scope schemas"
    [
      "async.spawn:(()->{Async|e}a)->Task a";
      "async.await:(Task a)->TaskResult a";
      "async.cancel:(Task a)->()";
      "async.yield:()->()";
      "async.scope:(()->{Async|e}a)->{|e}TaskResult a";
      "async.scope-fail-fast:(List (()->{Async|e}a))->{|e}TaskResult (List a)";
      "async.scope-collect:(List (()->{Async|e}a))->{|e}List (TaskResult a)";
    ]
    [
      schemas.spawn;
      schemas.await;
      schemas.cancel;
      schemas.yield;
      schemas.scope;
      schemas.scope_fail_fast;
      schemas.scope_collect;
    ];
  let cancellation_point_name = function
    | Await -> "await"
    | Yield -> "yield"
    | Routed_effect -> "routed-effect"
  in
  Alcotest.(check (list string))
    "all cancellation point classes frozen in contract order"
    [ "await"; "yield"; "routed-effect" ]
    (List.map cancellation_point_name cancellation_points);
  Alcotest.(check bool)
    "spawn queues child before suspended parent" true
    (requeue_after_spawn ~runnable:[] ~child ~parent = [ child; parent ]);
  Alcotest.(check bool)
    "runnable may suspend" true
    (valid_transition ~from_:Runnable ~into:Suspended);
  Alcotest.(check bool)
    "suspended may resume" true
    (valid_transition ~from_:Suspended ~into:Runnable);
  Alcotest.(check bool)
    "terminal state is immutable" false
    (valid_transition ~from_:Done_state ~into:Runnable);
  Alcotest.(check bool)
    "waiters wake in registration order" true
    (wake_waiters [ child; parent ] = [ child; parent ]);
  let completions : string completion list =
    [
      { sequence = 3; task = child; result = Failed "later" };
      { sequence = 1; task = parent; result = Done "ok" };
      { sequence = 2; task = child; result = Cancelled };
    ]
  in
  (match first_failure completions with
  | Some completion ->
      Alcotest.(check int) "first failure uses scheduler order" 2 completion.sequence
  | None -> Alcotest.fail "failure ordering lost terminal failure");
  Alcotest.(check bool)
    "self-await is a closed cycle" true
    (detect_wait_cycle [ { waiter = child; target = child } ] = Some [ child; child ]);
  Alcotest.check_raises "empty task path rejected"
    (Bug_invalid_task_id "structured-concurrency task paths must start at root component 0")
    (fun () -> ignore (task_id ~scope_path:[] ~spawn_index:0));
  Alcotest.check_raises "non-root task path rejected"
    (Bug_invalid_task_id "structured-concurrency task paths must start at root component 0")
    (fun () -> ignore (task_id ~scope_path:[ 1 ] ~spawn_index:0));
  Alcotest.check_raises "zero nested ordinal rejected"
    (Bug_invalid_task_id
       "structured-concurrency nested scope components must be one-based positive ordinals")
    (fun () -> ignore (task_id ~scope_path:[ 0; 0 ] ~spawn_index:0));
  Alcotest.check_raises "negative spawn index rejected"
    (Bug_invalid_task_id "structured-concurrency spawn indices must be non-negative") (fun () ->
      ignore (task_id ~scope_path:[ 0 ] ~spawn_index:(-1)));
  ignore (task_id ~scope_path:[ 0; 0xffff_ffff ] ~spawn_index:0xffff_ffff);
  Alcotest.check_raises "uint32 path component overflow rejected"
    (Bug_invalid_task_id
       "structured-concurrency task path components exceed the native uint32 domain") (fun () ->
      ignore (task_id ~scope_path:[ 0; 0x1_0000_0000 ] ~spawn_index:0));
  Alcotest.check_raises "uint32 spawn index overflow rejected"
    (Bug_invalid_task_id "structured-concurrency spawn indices exceed the native uint32 domain")
    (fun () -> ignore (task_id ~scope_path:[ 0 ] ~spawn_index:0x1_0000_0000));
  ignore
    (task_id ~scope_path:(List.init 65532 (fun index -> if index = 0 then 0 else 1)) ~spawn_index:0);
  Alcotest.check_raises "native block depth overflow rejected"
    (Bug_invalid_task_id
       "structured-concurrency task paths exceed the native uint16 block-length domain") (fun () ->
      ignore
        (task_id
           ~scope_path:(List.init 65533 (fun index -> if index = 0 then 0 else 1))
           ~spawn_index:0));
  match decide_round_robin ~sequence:0 [ child; parent ] with
  | Some decision ->
      Alcotest.(check bool) "round-robin chooses FIFO head" true (decision.chosen = child)
  | None -> Alcotest.fail "nonempty runnable queue produced no decision"

let registry_entry display_name =
  match
    List.find_opt
      (fun (entry : Effect_registry.metadata) -> entry.display_name = display_name)
      Effect_registry.catalog
  with
  | Some entry -> entry
  | None -> Alcotest.failf "registry catalog missing %s" display_name

let test_typed_registry_matches_contract () =
  let rows = rows () in
  let entries = Effect_registry.catalog_v1 in
  Alcotest.(check int) "catalog covers every blessed entry" 26 (List.length entries);
  Alcotest.(check int)
    "only live identities enter the canonical registry" 18
    (List.length (Effect_registry.entries Effect_registry.canonical_v1));
  Alcotest.(check (list string))
    "catalog names exactly cover the TSV"
    (rows |> List.map (fun row -> row.effect_name) |> List.sort String.compare)
    (entries
    |> List.map (fun (entry : Effect_registry.metadata) -> entry.display_name)
    |> List.sort String.compare);
  List.iter
    (fun (entry : Effect_registry.metadata) ->
      let row = find entry.display_name in
      Alcotest.(check string) (entry.display_name ^ " index") row.index_name entry.index_name;
      Alcotest.(check string)
        (entry.display_name ^ " tier") row.tier
        (Effect_registry.tier_name entry.tier);
      Alcotest.(check string)
        (entry.display_name ^ " risk") row.risk
        (Effect_registry.risk_name entry.default_risk);
      Alcotest.(check string) (entry.display_name ^ " meaning") row.meaning entry.reviewer_meaning;
      match (row.status, entry.interface) with
      | "implemented", Effect_registry.Released { version; hash } ->
          Alcotest.(check string) (entry.display_name ^ " interface version") "v1" version;
          Alcotest.(check string)
            (entry.display_name ^ " interface hash")
            row.interface_hash (Hash.to_hex hash);
          Alcotest.(check bool)
            (entry.display_name ^ " identity lookup")
            true
            (match Effect_registry.find_canonical hash with
            | Some found -> found.display_name = entry.display_name
            | None -> false)
      | "reserved", Effect_registry.Reserved { first_version } -> (
          Alcotest.(check string)
            (entry.display_name ^ " remains identity-free")
            "first-release" first_version;
          Alcotest.(check bool)
            (entry.display_name ^ " exposes no invented hash")
            true
            (Effect_registry.interface_hash entry = None);
          let retagged =
            {
              entry with
              interface =
                Effect_registry.Released
                  {
                    version = "forged";
                    hash = Hash.of_string ("forged reserved " ^ entry.display_name);
                  };
            }
          in
          match Effect_registry.register Effect_registry.empty retagged with
          | Error (Effect_registry.Reserved_catalog_name _) -> ()
          | _ -> Alcotest.failf "%s accepted a fabricated identity" entry.display_name)
      | status, _ -> Alcotest.failf "%s registry status disagrees with %s" entry.display_name status)
    entries;
  Alcotest.(check int) "TSV and registry counts agree" (List.length rows) (List.length entries)

let test_registration_rejects_duplicates () =
  let net = registry_entry "Net" in
  let registered =
    match Effect_registry.register Effect_registry.empty net with
    | Ok registry -> registry
    | Error error -> Alcotest.fail (Effect_registry.registration_error_to_string error)
  in
  (match Effect_registry.register registered net with
  | Error (Effect_registry.Duplicate_identity _) -> ()
  | _ -> Alcotest.fail "duplicate resolved identity was accepted");
  let different_identity =
    {
      net with
      interface =
        Effect_registry.Released
          { version = "test"; hash = Hash.of_string "different-net-interface" };
    }
  in
  (match Effect_registry.register registered different_identity with
  | Error (Effect_registry.Duplicate_display_name "Net") -> ()
  | _ -> Alcotest.fail "duplicate blessed display name was accepted");
  let different_name = { different_identity with display_name = "OtherNet" } in
  (match Effect_registry.register registered different_name with
  | Error (Effect_registry.Duplicate_index_name "net") -> ()
  | _ -> Alcotest.fail "duplicate official index name was accepted");
  let reserved = registry_entry "Env" in
  (match Effect_registry.register registered reserved with
  | Error (Effect_registry.Missing_resolved_identity "Env") -> ()
  | _ -> Alcotest.fail "reserved interface entered the resolved registry");
  let retagged =
    {
      reserved with
      interface =
        Effect_registry.Released
          { version = "forged"; hash = Hash.of_string "invented env identity" };
    }
  in
  (match Effect_registry.register Effect_registry.empty retagged with
  | Error (Effect_registry.Reserved_catalog_name "Env") -> ()
  | _ -> Alcotest.fail "retagged reserved display name entered the registry");
  let display_renamed = { retagged with display_name = "PretendEnv" } in
  match Effect_registry.register Effect_registry.empty display_renamed with
  | Error (Effect_registry.Reserved_catalog_name "env") -> ()
  | _ -> Alcotest.fail "retagged reserved index name entered the registry"

let test_unknown_identity_is_uncolored_and_unblessed () =
  let fake = Hash.of_string "publisher effect that happens to be named net" in
  let hint = "pk:attacker.example/tools/net" in
  let plain = Effect_registry.render_manifest_requirement ~name_hint:hint fake in
  let styled =
    Effect_registry.render_manifest_requirement ~style:Effect_registry.Ansi ~name_hint:hint fake
  in
  Alcotest.(check string) "styling never colors unknown effects" plain styled;
  Alcotest.(check bool) "publisher hint retained" true (contains_string plain hint);
  Alcotest.(check bool) "full identity retained" true (contains_string plain (Hash.to_hex fake));
  Alcotest.(check bool) "unknown identity is unrated" true (contains_string plain "unrated");
  Alcotest.(check bool)
    "official Net metadata not inherited" false
    (contains_string plain "world/high");
  let unpackaged = Effect_registry.render_manifest_requirement ~name_hint:"net" fake in
  Alcotest.(check bool)
    "missing package metadata gets an honest qualified fallback" true
    (contains_string unpackaged ("unpackaged:" ^ String.sub (Hash.to_hex fake) 0 12 ^ "/net"));
  let official = Effect_registry.render_metadata (registry_entry "Net") in
  Alcotest.(check bool) "plain registry output has no ANSI" false (contains_string official "\027[");
  Alcotest.(check bool) "official risk renders" true (contains_string official "world/high");
  let styled_official =
    Effect_registry.render_metadata ~style:Effect_registry.Ansi (registry_entry "Net")
  in
  Alcotest.(check bool) "ANSI styling is explicit" true (contains_string styled_official "\027[")

let test_registry_order_is_stable () =
  let names =
    Effect_registry.entries Effect_registry.canonical_v1
    |> List.map (fun (entry : Effect_registry.metadata) -> entry.display_name)
  in
  Alcotest.(check (list string)) "stable display ordering" (List.sort String.compare names) names;
  let contract = rows () in
  Alcotest.(check int)
    "catalog and TSV have the same positional extent" (List.length contract)
    (List.length Effect_registry.catalog_v1);
  List.iteri
    (fun position (row, (entry : Effect_registry.metadata)) ->
      Alcotest.(check string)
        (Printf.sprintf "catalog row %d name" position)
        row.effect_name entry.display_name;
      Alcotest.(check string)
        (Printf.sprintf "catalog row %d index" position)
        row.index_name entry.index_name;
      match (row.status, entry.interface) with
      | "implemented", Effect_registry.Released { hash; _ } ->
          Alcotest.(check string)
            (Printf.sprintf "catalog row %d released identity" position)
            row.interface_hash (Hash.to_hex hash);
          Alcotest.(check (option int))
            (Printf.sprintf "catalog row %d canonical position" position)
            (Some position)
            (Effect_registry.canonical_order_v1 hash)
      | "reserved", Effect_registry.Reserved _ ->
          let expected_identity =
            if String.equal row.effect_name "Async" then Concurrency_contract.async_effect_hash
            else if String.equal row.effect_name "Channel" then channel_effect_hash
            else "first-release"
          in
          Alcotest.(check string)
            (Printf.sprintf "catalog row %d reserved identity" position)
            expected_identity row.interface_hash
      | _ -> Alcotest.failf "catalog row %d status/interface mismatch" position)
    (List.combine contract Effect_registry.catalog_v1);
  Alcotest.(check (option int))
    "unknown identity has no blessed position" None
    (Effect_registry.canonical_order_v1 (Hash.of_string "unblessed ordering fallback"))

let test_taxonomy_v2_is_additive () =
  let v1 = rows () and v2 = rows_v2 () in
  let rec split_prefix prefix whole =
    match (prefix, whole) with
    | [], suffix -> suffix
    | expected :: expected_rest, actual :: actual_rest ->
        Alcotest.(check bool) "v2 preserves each v1 row byte-for-byte" true (expected = actual);
        split_prefix expected_rest actual_rest
    | _ :: _, [] -> Alcotest.fail "v2 is shorter than the frozen v1 snapshot"
  in
  let suffix = split_prefix v1 v2 in
  Alcotest.(check int) "v1 remains 26 rows" 26 (List.length v1);
  Alcotest.(check int) "v2 adds exactly one row" 27 (List.length v2);
  let governance_row =
    match suffix with
    | [ row ] -> row
    | rows -> Alcotest.failf "v2 has %d additive rows, expected one" (List.length rows)
  in
  Alcotest.(check string) "additive display name" "GovernanceApprovalV1" governance_row.effect_name;
  Alcotest.(check string) "additive index name" "governance-approval-v1" governance_row.index_name;
  Alcotest.(check string)
    "additive operation" "governance-approval.ask:(GovernanceProposal)->Decision"
    governance_row.operations;
  let expected_hash = "41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed" in
  Alcotest.(check string) "additive interface hash" expected_hash governance_row.interface_hash;
  Alcotest.(check string) "additive governance tier" "governance" governance_row.tier;
  Alcotest.(check string) "additive special risk" "special" governance_row.risk;
  Alcotest.(check bool)
    "registry v2 preserves the exact v1 prefix" true
    (split_prefix Effect_registry.catalog_v1 Effect_registry.catalog_v2
    = [ List.nth Effect_registry.catalog_v2 26 ]);
  let identity =
    match Hash.of_hex expected_hash with
    | Some hash -> hash
    | None -> Alcotest.fail "frozen GovernanceApprovalV1 hash is malformed"
  in
  Alcotest.(check (option int))
    "v1 does not reinterpret the new identity" None
    (Effect_registry.canonical_order_v1 identity);
  Alcotest.(check (option int))
    "v2 appends the new identity" (Some 26)
    (Effect_registry.canonical_order_v2 identity);
  Alcotest.(check (option int))
    "current ordering is v2" (Some 26)
    (Effect_registry.canonical_order identity);
  let metadata = List.nth Effect_registry.catalog_v2 26 in
  Alcotest.(check string)
    "typed additive governance tier" "governance"
    (Effect_registry.tier_name metadata.tier);
  Alcotest.(check string)
    "typed additive special risk" "special"
    (Effect_registry.risk_name metadata.default_risk);
  let store = prelude_store () in
  let entry =
    match Store.lookup_kind store "governance-approval-v1" Resolve.KEffect with
    | Some entry -> entry
    | None -> Alcotest.fail "GovernanceApprovalV1 is absent from the prelude"
  in
  Alcotest.(check string)
    "prelude implements the additive identity" expected_hash (Hash.to_hex entry.hash);
  let expected_ops = resolved_taxonomy_effect store governance_row in
  match Store.locate store entry.hash with
  | Ok { decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Whole; _ } ->
      Alcotest.(check bool)
        "additive schema matches the prelude" true
        (List.equal same_opspec expected_ops ops)
  | Ok _ -> Alcotest.fail "GovernanceApprovalV1 identity is not an effect declaration"
  | Error diagnostics -> Eval_support.fail_diags "locate GovernanceApprovalV1" diagnostics

let test_governed_membrane_charter () =
  let doc = Corpus_support.read_file membrane_doc in
  let fixture = Corpus_support.read_file membrane_fixture in
  let stdout = Corpus_support.read_file membrane_stdout in
  let check_contains label source phrase =
    Alcotest.(check bool) (label ^ ": " ^ phrase) true (contains_string source phrase)
  in
  let check_decision decision = check_contains "indexed decision" doc ("| " ^ decision ^ " |") in
  Alcotest.(check bool)
    "no unresolved choice marker in membrane charter" false
    (contains_string (lowercase doc) "tbd");
  List.iter check_decision
    [
      "D61";
      "D62";
      "D63";
      "D64";
      "D65";
      "D66";
      "D67";
      "D68";
      "D69";
      "D70";
      "D71";
      "D72";
      "D73";
      "D74";
    ];
  List.iter
    (check_contains "membrane contract" doc)
    [
      "GovernanceV0";
      "resources are configured evidence, never row proofs";
      "Result ToolError";
      "missing simulation refuses and never falls back live";
      "`governance.with-sequence` is the sole owner API";
      "ordinary single-tail Jacquard types";
      "G0-G4 phase may replace this disposition-and-local-Resume representation";
      "| Some(simulator) -> Some(fn () -> simulator(path))";
      "transitive raw-authority envelope";
      "parent-call-id = Some(previous-call-id)";
      "other authority exclusions";
      "versioned `SecretRef` values";
      "let secret = secret.read(SecretRef(GovernanceV0, \"workspace\", None))";
      "let exposed = secret.expose(secret)";
      "let result = match exposed { | _ -> Ok(net.fetch(request)) }";
      "The action therefore derives `{Net, Secret}`";
      "Dry simulators continue to receive only safe request";
      "governed bodies carrying `Eval` are rejected";
      "G5 adds posterior judgment only as the separately versioned GM.21 extension";
      "There is no `Tool` or `Host` effect in v0";
    ];
  List.iter
    (check_contains "signature fixture" fixture)
    [
      "workspace.read-file : (Path) -> Result ToolError Text";
      "type AuditSequence";
      "workspace.live-layer : (AuditSequence";
      "workspace.dry-layer : (AuditSequence";
      "workspace.live(policy";
      "workspace.dry-run(policy";
      "| None -> Err(NoSimulation)";
      "secret.read(SecretRef(GovernanceV0";
      "type WorkspaceOperation";
      "Effect(HashValue(\"effect:Fs\"))";
      "Effect(HashValue(\"effect:Net\")), Effect(HashValue(\"effect:Secret\"))";
      "authority-for(operation)";
      "parent-call-id: Option Hash";
      "let handled = state.run";
      "next-sequence(sequence)";
      "governance.with-sequence(body)";
      "PathValue(\"docs/README.md\")";
    ];
  Alcotest.(check bool)
    "fixture never restarts a literal operation sequence" false
    (contains_string fixture "Evaluated(GovernanceV0, 0");
  Alcotest.(check bool)
    "fixture never substitutes an empty authority envelope" false (contains_string fixture "[]");
  Alcotest.(check int)
    "only the run-level owner initializes sequence State" 1
    (count_string fixture "state.run");
  Alcotest.(check bool)
    "charter has no impossible two-tail gate row" false (contains_string doc "| h | e");
  Alcotest.(check bool)
    "normative fetch action is not Net-only" false
    (contains_string doc "let result = Ok(net.fetch(request))");
  List.iter
    (check_contains "checked signature" stdout)
    [
      "agent : () ->{Workspace} Result ToolError Text";
      "next-sequence : (AuditSequence) ->{State} Int";
      "workspace.live-layer :";
      ") ->{Secret, Judge, Approval, State, Audit, Fs, Net} Result ToolError Text";
      "workspace.dry-layer :";
      ") ->{Judge, State, Audit} Result ToolError Text";
      "governance.with-sequence : forall a | e.";
      "workspace.live :";
      ") ->{Secret, Judge, Approval, Audit, Fs, Net} Result ToolError Text";
      "workspace.dry-run :";
      ") ->{Judge, Audit} Result ToolError Text";
    ]

let test_governance_contracts () =
  test_governance_and_links ();
  test_governed_membrane_charter ()

let suite =
  [
    Alcotest.test_case "complete machine contract" `Quick test_complete_contract;
    Alcotest.test_case "reserved schemas resolved" `Quick test_resolved_reserved_schemas;
    Alcotest.test_case "SC.14 Channel interface identity" `Quick
      test_channel_interface_hash_contract;
    Alcotest.test_case "implemented prelude compatibility" `Quick
      test_implemented_interfaces_match_prelude;
    Alcotest.test_case "stale hash cannot mask schema drift" `Quick
      test_stale_hash_cannot_mask_schema_drift;
    Alcotest.test_case "decision and governance index" `Quick test_governance_contracts;
    Alcotest.test_case "typed registry matches contract" `Quick test_typed_registry_matches_contract;
    Alcotest.test_case "duplicate registration rejection" `Quick
      test_registration_rejects_duplicates;
    Alcotest.test_case "unknown identity stays unblessed" `Quick
      test_unknown_identity_is_uncolored_and_unblessed;
    Alcotest.test_case "registry ordering stable" `Quick test_registry_order_is_stable;
    Alcotest.test_case "taxonomy v2 is additive" `Quick test_taxonomy_v2_is_additive;
  ]
