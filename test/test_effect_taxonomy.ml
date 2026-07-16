open Jacquard

let taxonomy_file = "../spec/effect-taxonomy-v1.tsv"
let taxonomy_doc = "../docs/effect-taxonomy.md"
let membrane_doc = "../docs/effect-membranes.md"
let concurrency_doc = "../docs/concurrency.md"
let schema_fixture = "docs-doctest/fixtures/effect-taxonomy-schemas.jac"
let approval_fixture = "docs-doctest/fixtures/stdlib-handler-policy.jac"
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

type effect_shape = { ename : string; evars : string list; ops : Kernel.opspec list }

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

let rows () =
  Corpus_support.read_file taxonomy_file
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      let line = String.trim line in
      if String.equal line "" || String.starts_with ~prefix:"#" line then None
      else Some (parse_row line))

let operation_names operations =
  String.split_on_char ';' operations
  |> List.map (fun schema ->
      match String.index_opt schema ':' with
      | Some index -> String.sub schema 0 index
      | None -> Alcotest.failf "operation schema lacks a colon: %s" schema)

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
  | Kernel.TArrow _ | Kernel.TForall _ -> "(" ^ schema_ty ty ^ ")"
  | _ -> schema_ty ty

let operation_schemas (ops : Kernel.opspec list) =
  ops
  |> List.map (fun (op : Kernel.opspec) ->
      op.op_name ^ ":("
      ^ String.concat "," (List.map schema_ty op.op_params)
      ^ ")->" ^ schema_ty op.op_result)
  |> String.concat ";"

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

let markdown_row row =
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
  Alcotest.(check int) "blessed effect count" 25 (List.length rows);
  Alcotest.(check int)
    "implemented count" 12
    (List.length (List.filter (fun row -> String.equal row.status "implemented") rows));
  Alcotest.(check int)
    "reserved count" 13
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

let test_resolved_reserved_schemas () =
  let expected =
    [
      ("Env", [ "env.get" ]);
      ("Pg", [ "pg.query" ]);
      ("Blob", [ "blob.get"; "blob.put-if-absent"; "blob.exists?" ]);
      ("Serve", [ "serve.next"; "serve.respond" ]);
      ("Crypto", [ "crypto.verify"; "crypto.random" ]);
      ("Log", [ "log.emit" ]);
      ("Approval", [ "approval.ask" ]);
      ("Audit", [ "audit.record" ]);
      ("Secret", [ "secret.read"; "secret.expose" ]);
      ("Judge", [ "judge.assess" ]);
      ("Async", [ "async.spawn"; "async.await"; "async.cancel"; "async.yield" ]);
      ("Channel", [ "channel.open"; "channel.send"; "channel.recv"; "channel.close" ]);
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
    "Async self-row schema is executable after SC.0" true
    (List.exists
       (function
         | { Kernel.it = Kernel.DefEffect { ename; _ }; _ } -> String.equal ename "async"
         | _ -> false)
       declarations);
  let doc = Corpus_support.read_file taxonomy_doc in
  let normalized_doc = normalize_whitespace doc in
  List.iter
    (fun obligation ->
      Alcotest.(check bool)
        ("Async implementation obligation: " ^ obligation)
        true
        (contains_string normalized_doc obligation))
    [
      "direct resolved `async.spawn` application";
      "narrow special typing rule";
      "higher-order aliases, wrappers, and returned closures";
      "does not implement Task values, a scheduler, scopes, or a root handler";
    ];
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
    | None -> Alcotest.failf "%s is missing from the executable schema fixture" type_name
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
      ("channel-error", [ "channel-closed" ]);
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
      Alcotest.(check string) "type used as effect rejected by resolver" "E0302" diagnostic.code
  | Error diagnostics ->
      Eval_support.fail_diags "unexpected malformed-context diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "type used as an effect unexpectedly resolved");
  (match Canon.hash_decl malformed with
  | Error [ diagnostic ] ->
      Alcotest.(check string)
        "Named row outside enclosing effect rejected by canon" "E0501" diagnostic.code
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
          Alcotest.(check string)
            (row.effect_name ^ " located declaration hash")
            row.interface_hash (Hash.to_hex decl_hash);
          Alcotest.(check (list string))
            (row.effect_name ^ " operation names")
            (operation_names row.operations)
            (List.map (fun (op : Kernel.opspec) -> op.op_name) ops);
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

let lowercase = String.lowercase_ascii

let test_governance_and_links () =
  test_self_effect_hash_contract ();
  test_async_privilege_mutations ();
  let doc = Corpus_support.read_file taxonomy_doc in
  let manifest = Corpus_support.read_file taxonomy_file in
  let approval = Corpus_support.read_file approval_fixture in
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
    (contains_string approval "continue(Escalate(proposal-hash, \"dry-run cannot consent\"))");
  Alcotest.(check bool)
    "dry-run Approval never fabricates Approved" false
    (contains_string approval "continue(Approved");
  let linked =
    [
      "../spec/effect-taxonomy-v1.tsv";
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
  let entries = Effect_registry.catalog in
  Alcotest.(check int) "catalog covers every blessed entry" 25 (List.length entries);
  Alcotest.(check int)
    "only live identities enter the canonical registry" 12
    (List.length (Effect_registry.entries Effect_registry.canonical));
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
  let reserved = registry_entry "Audit" in
  (match Effect_registry.register registered reserved with
  | Error (Effect_registry.Missing_resolved_identity "Audit") -> ()
  | _ -> Alcotest.fail "reserved interface entered the resolved registry");
  let retagged =
    {
      reserved with
      interface =
        Effect_registry.Released
          { version = "forged"; hash = Hash.of_string "invented audit identity" };
    }
  in
  (match Effect_registry.register Effect_registry.empty retagged with
  | Error (Effect_registry.Reserved_catalog_name "Audit") -> ()
  | _ -> Alcotest.fail "retagged reserved display name entered the registry");
  let display_renamed = { retagged with display_name = "PretendAudit" } in
  match Effect_registry.register Effect_registry.empty display_renamed with
  | Error (Effect_registry.Reserved_catalog_name "audit") -> ()
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
    Effect_registry.entries Effect_registry.canonical
    |> List.map (fun (entry : Effect_registry.metadata) -> entry.display_name)
  in
  Alcotest.(check (list string)) "stable display ordering" (List.sort String.compare names) names

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
    [ "D61"; "D62"; "D63"; "D64"; "D65"; "D66"; "D67"; "D68"; "D69"; "D70"; "D71"; "D72"; "D73" ];
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
      "G5 may add posterior judgment";
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
      ") ->{Secret, Approval, Judge, State, Fs, Net, Audit} Result ToolError Text";
      "workspace.dry-layer :";
      ") ->{Judge, State, Audit} Result ToolError Text";
      "governance.with-sequence : forall a | e.";
      "workspace.live :";
      ") ->{Secret, Approval, Judge, Fs, Net, Audit} Result ToolError Text";
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
    Alcotest.test_case "implemented prelude compatibility" `Quick
      test_implemented_interfaces_match_prelude;
    Alcotest.test_case "decision and governance index" `Quick test_governance_contracts;
    Alcotest.test_case "typed registry matches contract" `Quick test_typed_registry_matches_contract;
    Alcotest.test_case "duplicate registration rejection" `Quick
      test_registration_rejects_duplicates;
    Alcotest.test_case "unknown identity stays unblessed" `Quick
      test_unknown_identity_is_uncolored_and_unblessed;
    Alcotest.test_case "registry ordering stable" `Quick test_registry_order_is_stable;
  ]
