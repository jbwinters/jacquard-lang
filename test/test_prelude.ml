open Jacquard

(* W2.6: the real prelude — loads clean, hashes pinned, library functions work, and the
   console effect prints only under a grant. *)

let golden_file = "../corpus/golden/prelude-hashes.golden"
let modes_file = "../prelude/operation-modes.manifest"

type reviewed_mode = { effect_name : string; op_name : string; mode : Kernel.op_mode }

let reviewed_modes () =
  Corpus_support.read_file modes_file
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      let line = String.trim line in
      if String.equal line "" || String.starts_with ~prefix:"#" line then None
      else
        match String.split_on_char ' ' line with
        | [ qualified; mode ] -> (
            match String.index_opt qualified '.' with
            | Some separator ->
                let effect_name = String.sub qualified 0 separator in
                let op_name =
                  String.sub qualified (separator + 1) (String.length qualified - separator - 1)
                in
                Some
                  {
                    effect_name;
                    op_name;
                    mode =
                      (match mode with
                      | "once" -> Kernel.Once
                      | "multi" -> Kernel.Multi
                      | other -> Alcotest.failf "unknown reviewed operation mode %s" other);
                  }
            | None -> Alcotest.failf "malformed reviewed operation name %s" qualified)
        | _ -> Alcotest.failf "malformed reviewed operation-mode row %s" line)

let mode_name = function Kernel.Once -> "once" | Kernel.Multi -> "multi"

let prelude_source_modes () =
  Corpus_support.jqd_files "../prelude"
  |> List.concat_map (fun file ->
      let path = Filename.concat "../prelude" file in
      let tops =
        match Corpus_support.bootstrap_tops ~file:path (Corpus_support.read_file path) with
        | Ok tops -> tops
        | Error (_, diagnostics) ->
            Eval_support.fail_diags ("parse prelude operation inventory " ^ file) diagnostics
      in
      tops
      |> List.concat_map (function
        | Kernel.Decl { it = Kernel.DefEffect { ename; ops; _ }; _ } ->
            List.map
              (fun (operation : Kernel.opspec) ->
                { effect_name = ename; op_name = operation.op_name; mode = operation.op_mode })
              ops
        | Kernel.Decl _ | Kernel.Expr _ -> []))

let operation_inventory store =
  let one_effect effect_name =
    match Store.lookup_kind store effect_name Resolve.KEffect with
    | None -> Alcotest.failf "reviewed effect %s is absent from the prelude" effect_name
    | Some { Resolve.hash; _ } -> (
        match Store.locate store hash with
        | Ok
            {
              Store.decl_hash;
              decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ };
              role = Store.Whole;
              _;
            } ->
            List.mapi
              (fun ordinal (operation : Kernel.opspec) ->
                ( operation.op_name,
                  operation.op_mode,
                  Canon.op_hash decl_hash ordinal,
                  List.length operation.op_params ))
              ops
        | Ok _ -> Alcotest.failf "%s did not locate to a whole effect declaration" effect_name
        | Error diagnostics -> Eval_support.fail_diags ("locate " ^ effect_name) diagnostics)
  in
  reviewed_modes ()
  |> List.map (fun reviewed ->
      let operations = one_effect reviewed.effect_name in
      match
        List.find_opt (fun (name, _, _, _) -> String.equal name reviewed.op_name) operations
      with
      | None ->
          Alcotest.failf "reviewed operation %s.%s is absent" reviewed.effect_name reviewed.op_name
      | Some (_, actual, hash, arity) ->
          Alcotest.(check bool)
            (reviewed.effect_name ^ "." ^ reviewed.op_name ^ " reviewed mode")
            true (actual = reviewed.mode);
          (reviewed, hash, arity))

let test_retained_multi_hashes store =
  let identities =
    [
      ("state", Resolve.KEffect, "44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9");
      ("get", Resolve.KOp, "436ac521990b98f781d2b940ae7411d495bcabbabfd5212d71f6a3803d11e4af");
      ("put", Resolve.KOp, "5c6c06f1338db14e6651a830a3598cf369da2a2ec53a17b091116da3b6640e70");
      ("dist", Resolve.KEffect, "5a31778adb668e471820541428a4d809f40206b231b2f9d40aeb36d5684415f0");
      ("sample", Resolve.KOp, "6a5da9e5bd03d63ee37665097c6cb472fde25578e7d8dbabf388a9f3a46a8a76");
      ("observe", Resolve.KOp, "5d699ff1e147617ccc1c12bfa921370432618a63fa3cdf5ccdd330f83e446872");
      ("check", Resolve.KEffect, "d0fd20ea4725129d5b5de718e7332164ca504247793c21454533cbcf81112336");
      ("check", Resolve.KOp, "4e4065ee81b87920edd760a835a52be10b105f25f3a6a41a6a3bbbc8930126d5");
      ("fail", Resolve.KOp, "32a7abbad63368d57a2d08265658ac27bff7bfd6f4f25377b9006d3402adc944");
      ("fault", Resolve.KEffect, "0b7297f7a38573108de121c794c6be6471d9c43bd4749d435a3cd247e7d5f008");
      ("flaky", Resolve.KOp, "d28d10d5ddd39a0d9f456a22007acc6d84ffd3497000d5cefbda3ef159b54416");
    ]
  in
  List.iter
    (fun (name, kind, expected) ->
      match Store.lookup_kind store name kind with
      | Some { Resolve.hash; _ } ->
          Alcotest.(check string) (name ^ " retained hash") expected (Hash.to_hex hash)
      | None -> Alcotest.failf "missing retained Multi identity %s" name)
    identities

let test_reviewed_operation_modes store =
  let reviewed = reviewed_modes () in
  let row ({ effect_name; op_name; mode } : reviewed_mode) =
    Printf.sprintf "%s.%s %s" effect_name op_name (mode_name mode)
  in
  let declared = prelude_source_modes () |> List.map row |> List.sort String.compare in
  let frozen = reviewed |> List.map row |> List.sort String.compare in
  Alcotest.(check int) "current prelude operation inventory size" 37 (List.length declared);
  Alcotest.(check (list string))
    "every operation from every prelude DefEffect has an exact reviewed mode" declared frozen;
  test_retained_multi_hashes store;
  let ctx = Eval.make_ctx store in
  operation_inventory store
  |> List.iter (fun (reviewed, op, arity) ->
      let meta = Meta.empty in
      let arg = Kernel.{ it = Lit (LInt 0); meta } in
      let perform =
        Kernel.{ it = App ({ it = Ref (op, Op); meta }, List.init arity (fun _ -> arg)); meta }
      in
      let expression = Kernel.{ it = Tuple [ perform; { it = Lit (LInt 7); meta } ]; meta } in
      let captured =
        match Eval.run_state_capturing ctx (Eval.expr_state expression) with
        | Ok (Eval.COp { kont; _ }) -> kont
        | Ok (Eval.CValue value) ->
            Alcotest.failf "%s.%s unexpectedly returned %s" reviewed.effect_name reviewed.op_name
              (Value.show value)
        | Error error ->
            Alcotest.failf "%s.%s capture failed: %s" reviewed.effect_name reviewed.op_name
              (Runtime_err.to_string error)
      in
      let resume value =
        Result.bind (Eval.resume_captured_state ctx captured (Value.VInt value)) (fun state ->
            Eval.run_state_capturing ctx state)
      in
      (match resume 11 with
      | Ok (Eval.CValue _) -> ()
      | Ok (Eval.COp _) -> Alcotest.fail "first resume unexpectedly performed another operation"
      | Error error -> Alcotest.failf "first resume failed: %s" (Runtime_err.to_string error));
      match (reviewed.mode, resume 12) with
      | Kernel.Once, Error Runtime_err.Once_resumed_twice -> ()
      | Kernel.Multi, Ok (Eval.CValue _) -> ()
      | Kernel.Once, Error error | Kernel.Multi, Error error ->
          Alcotest.failf "%s.%s wrong second-resume error: %s" reviewed.effect_name reviewed.op_name
            (Runtime_err.to_string error)
      | Kernel.Once, Ok _ ->
          Alcotest.failf "%s.%s allowed a second once resume" reviewed.effect_name reviewed.op_name
      | Kernel.Multi, Ok (Eval.COp _) ->
          Alcotest.failf "%s.%s second multi resume performed another operation"
            reviewed.effect_name reviewed.op_name)

let test_loads_with_zero_diagnostics () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "prelude checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "prelude builtin signatures" diagnostics);
  let forced = Hashtbl.create 256 in
  (Store.names_view store).Resolve.all_names ()
  |> List.iter (fun name ->
      match Store.lookup_kind store name Resolve.KTerm with
      | None -> ()
      | Some { Resolve.hash; _ } when Hashtbl.mem forced hash -> ()
      | Some { Resolve.hash; _ } -> (
          Hashtbl.add forced hash ();
          match Check.force_term checker hash with
          | Ok _ -> ()
          | Error diagnostics -> Eval_support.fail_diags ("force prelude term " ^ name) diagnostics));
  let expected_world_handlers =
    [
      ("infer.scripted", "forall a | e. (() ->{Infer | e} a, List Text) ->{Throw | e} a");
      ("net.record", "forall a | e. (() ->{Net | e} a) ->{Net | e} (a, Code)");
      ("test.replay", "forall a | e. (Code, () ->{Net | e} a) ->{Throw | e} a");
      ("net.scripted", "forall a | e. (() ->{Net | e} a, List Response) ->{Throw | e} a");
      ("console.scripted", "forall a | e. (() ->{Console | e} a, List Text) ->{Throw | e} a");
      ( "fs.in-memory",
        "forall a | e. (() ->{Fs | e} a, `type:map.t` Text Text) ->{Throw | e} (a, `type:map.t` \
         Text Text)" );
      ("test.replay-loose", "forall a | e. (Code, () ->{Net | e} a) ->{Check, Throw | e} a");
      ("audit.in-memory", "forall a | e. (() ->{Audit | e} a) ->{| e} (a, List AuditEntry)");
      ( "audit.line-log",
        "forall a | e. (() ->{Audit | e} a, (Text) ->{| e} Result Text ()) ->{| e} Result Text a" );
      ("hash.parse", "(Text) ->{} Result Text Hash");
      ("hash.to-text", "(Hash) ->{} Text");
      ("code.of-hash", "(Hash) ->{} Code");
      ("code.of-real", "(Real) ->{} Code");
      ("code.render", "(Code) ->{} Text");
      ("code.hash", "(Code) ->{} Hash");
      ( "approval.make-proposal",
        "(Hash, Hash, Hash, List Authority, Code, Text, Option OutcomeSummary) ->{} Proposal" );
      ( "approval.before-action",
        "forall a | e. (Proposal, Decision, () ->{| e} a) ->{| e} Result Text a" );
      ( "judge.rules",
        "forall a | e. (() ->{Judge, Throw | e} a, (GovernanceCall) ->{} GovernanceAssessment) \
         ->{Throw | e} a" );
      ( "judge.fixed",
        "forall a | e. (() ->{Judge, Throw | e} a, GovernanceAssessment) ->{Throw | e} a" );
      ( "judge.scripted",
        "forall a | e. (() ->{Judge, Throw | e} a, List GovernanceAssessment) ->{Throw | e} a" );
      ( "judge.model",
        "forall a | e. (() ->{Infer, Judge, Throw | e} a, (GovernanceCall) ->{Infer} \
         GovernanceAssessment) ->{Infer, Throw | e} a" );
      ("approval.console", "forall a | e. (() ->{Approval | e} a) ->{Console, Throw | e} a");
      ("approval.scripted", "forall a | e. (() ->{Approval | e} a, List Decision) ->{Throw | e} a");
      ("approval.dry-run", "forall a | e. (() ->{Approval | e} a) ->{Throw | e} a");
      ( "approval.policy-auto",
        "forall a | e. (() ->{Approval | e} a, (Proposal) ->{| e} Verdict) ->{Throw | e} a" );
    ]
  in
  List.iter
    (fun (name, expected) ->
      match Store.lookup_kind store name Resolve.KTerm with
      | None -> Alcotest.failf "missing world handler %s" name
      | Some { Resolve.hash; _ } -> (
          match Check.force_term checker hash with
          | Error diagnostics -> Eval_support.fail_diags ("force world handler " ^ name) diagnostics
          | Ok scheme ->
              Alcotest.(check string)
                (name ^ " exact signature") expected
                (Check.show_scheme checker scheme)))
    expected_world_handlers

let test_prelude_hashes_golden () =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "open_store" ds
  in
  match Prelude.load ~dir:"../prelude" store with
  | Error ds -> Eval_support.fail_diags "load" ds
  | Ok files ->
      let actual =
        List.concat_map
          (fun (file, hashes) ->
            List.concat
              (List.mapi
                 (fun i { Canon.decl_hash; named } ->
                   Printf.sprintf "%s:%d %s" file i (Hash.to_hex decl_hash)
                   :: List.map
                        (fun (n, h) -> Printf.sprintf "%s:%d:%s %s" file i n (Hash.to_hex h))
                        named)
                 hashes))
          files
      in
      let expected =
        Corpus_support.read_file golden_file
        |> String.split_on_char '\n'
        |> List.filter (fun l -> l <> "")
      in
      Alcotest.(check (list string))
        "prelude hashes match corpus/golden/prelude-hashes.golden (regenerate with `dune exec \
         test/gen_prelude_goldens.exe` and review the diff)"
        expected actual;
      test_reviewed_operation_modes store

let eval_ok src =
  let store, ctx = Eval_support.make_prelude_ctx () in
  match Eval_support.eval_with ctx store src with
  | Ok v -> Value.show v
  | Error e -> Alcotest.failf "%s failed: %s" src (Runtime_err.to_string e)

let test_builtins_work () =
  Alcotest.(check string) "add" "3" (eval_ok "(app (var add) (lit 1) (lit 2))");
  Alcotest.(check string) "eq true" "true" (eval_ok "(app (var eq) (lit 2) (lit 2))");
  Alcotest.(check string) "lt false" "false" (eval_ok "(app (var lt) (lit 3) (lit 2))")

let test_ss22_real_builtin_identity () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  let identities =
    [
      ("add-real", "real.add", "d2c5dfae79852c3b7c2d8426df692b04fb8549fd4b400a3ee3c2be5f04a0f76e");
      ("sub-real", "real.sub", "eba25d96c355d541e1beab4c94bf2b2c4e0d39118e937024b6093a2d89295978");
      ("mul-real", "real.mul", "da578d1fb2e56f6670c2cfd6dff60e73c190e66895e30b7152d84713cd1e34bb");
      ("div-real", "real.div", "f31ba01c161dfff1da955403edc8ff03e7d23b92df9d8dd50a5e9bd82b4a0678");
      ("lt-real", "real.lt?", "01a2e8cf101a6e0ae1f64a6df1f12a19c8ba98b674407d5125721133f9b112fb");
    ]
  in
  List.iter
    (fun (old_name, public_name, expected_hex) ->
      Alcotest.(check bool)
        (old_name ^ " removed from name index")
        true
        (Store.lookup_kind store old_name Resolve.KTerm = None);
      match Store.lookup_kind store public_name Resolve.KTerm with
      | None -> Alcotest.failf "missing public builtin %s" public_name
      | Some { Resolve.hash; _ } -> (
          Alcotest.(check string) (public_name ^ " preserves hash") expected_hex (Hash.to_hex hash);
          match Store.locate store hash with
          | Ok
              {
                Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ };
                role = Store.Member index;
                _;
              } -> (
              match List.nth_opt bindings index with
              | Some
                  {
                    Kernel.value =
                      {
                        Kernel.it =
                          Kernel.Quote
                            { Form.head = "builtin-marker"; args = [ Form.Sym intrinsic_id ]; _ };
                        _;
                      };
                    _;
                  } ->
                  Alcotest.(check string)
                    (public_name ^ " stable intrinsic ID")
                    old_name intrinsic_id
              | _ -> Alcotest.failf "%s has no builtin marker body" public_name)
          | Ok _ -> Alcotest.failf "%s does not locate to a term member" public_name
          | Error ds -> Eval_support.fail_diags ("locate " ^ public_name) ds))
    identities

let test_ss22_text_join_identity () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  let locate_marker public_name =
    match Store.lookup_kind store public_name Resolve.KTerm with
    | None -> Alcotest.failf "missing public builtin %s" public_name
    | Some { Resolve.hash; _ } -> (
        match Store.locate store hash with
        | Ok
            {
              Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ };
              role = Store.Member index;
              _;
            } -> (
            match List.nth_opt bindings index with
            | Some
                {
                  Kernel.value =
                    {
                      Kernel.it =
                        Kernel.Quote { Form.head = "builtin-marker"; args = [ Form.Sym marker ]; _ };
                      _;
                    };
                  _;
                } ->
                (hash, marker)
            | _ -> Alcotest.failf "%s has no builtin marker body" public_name)
        | Ok _ -> Alcotest.failf "%s does not locate to a term member" public_name
        | Error diagnostics -> Eval_support.fail_diags ("locate " ^ public_name) diagnostics)
  in
  let old_hash, old_marker = locate_marker "text.join-list" in
  let new_hash, new_marker = locate_marker "text.join" in
  Alcotest.(check string)
    "historical compatibility hash"
    "b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd" (Hash.to_hex old_hash);
  Alcotest.(check string) "historical compatibility marker" "text.join" old_marker;
  Alcotest.(check string)
    "new variadic hash" "c6b3e1429d584f14e81f4b1dd46b314ae038170bafc8ac0abdfb0162ed54141d"
    (Hash.to_hex new_hash);
  Alcotest.(check string) "new variadic marker" "text.join-variadic-v1" new_marker;
  Alcotest.(check bool) "canonical identities are distinct" false (Hash.equal old_hash new_hash)

let test_ss22_numeric_predicates () =
  let expect name expected source = Alcotest.(check string) name expected (eval_ok source) in
  expect "int.gt?" "true" "(app (var int.gt?) (lit 2) (lit 1))";
  expect "int.gte? boundary" "true"
    "(app (var int.gte?) (lit 4611686018427387903) (lit 4611686018427387903))";
  expect "int.lt? boundary" "true"
    "(app (var int.lt?) (lit -4611686018427387904) (lit 4611686018427387903))";
  expect "int.lte?" "false" "(app (var int.lte?) (lit 2) (lit 1))";
  expect "real.gt?" "true" "(app (var real.gt?) (lit 2.0) (lit 1.0))";
  expect "real.gte?" "true" "(app (var real.gte?) (lit 2.0) (lit 2.0))";
  expect "real.lt?" "true" "(app (var real.lt?) (lit -1.0) (lit 0.0))";
  expect "real.lte?" "false" "(app (var real.lte?) (lit 2.0) (lit 1.0))";
  List.iter
    (fun predicate ->
      expect (predicate ^ " NaN") "false"
        (Printf.sprintf
           "(let nonrec (pvar nan) (app (var real.div) (lit 0.0) (lit 0.0)) (app (var %s) (var \
            nan) (lit 0.0)))"
           predicate))
    [ "real.gt?"; "real.gte?"; "real.lt?"; "real.lte?" ]

let test_text_join () =
  Alcotest.(check string) "zero" "\"\"" (eval_ok "(app (var text.join))");
  Alcotest.(check string) "one" "\"one\"" (eval_ok "(app (var text.join) (lit \"one\"))");
  Alcotest.(check string)
    "many in order" "\"abc\""
    (eval_ok "(app (var text.join) (lit \"a\") (lit \"b\") (lit \"c\"))");
  Alcotest.(check string)
    "eight" "\"abcdefgh\""
    (eval_ok
       "(app (var text.join) (lit \"a\") (lit \"b\") (lit \"c\") (lit \"d\") (lit \"e\") (lit \
        \"f\") (lit \"g\") (lit \"h\"))");
  Alcotest.(check string)
    "UTF-8 and empty text" "\"hé👍\""
    (eval_ok "(app (var text.join) (lit \"hé\") (lit \"\") (lit \"👍\"))");
  let large = String.make 131072 'x' in
  Alcotest.(check string)
    "large text"
    (Value.show (Value.VText (large ^ large)))
    (eval_ok (Printf.sprintf "(app (var text.join) (lit %S) (lit %S))" large large));
  Alcotest.(check string)
    "first-class zero/one/many/eight" "(\"\", \"one\", \"abc\", \"abcdefgh\")"
    (eval_ok
       "(let nonrec (pvar join) (var text.join) (tuple (app (var join)) (app (var join) (lit \
        \"one\")) (app (var join) (lit \"a\") (lit \"b\") (lit \"c\")) (app (var join) (lit \"a\") \
        (lit \"b\") (lit \"c\") (lit \"d\") (lit \"e\") (lit \"f\") (lit \"g\") (lit \"h\"))))");
  Alcotest.(check string)
    "deprecated list compatibility" "\"a-b-c\""
    (eval_ok
       "(app (var text.join-list) (app (var cons) (lit \"a\") (app (var cons) (lit \"b\") (app \
        (var cons) (lit \"c\") (var nil)))) (lit \"-\"))");
  let store, ctx = Eval_support.make_prelude_ctx () in
  match Eval_support.eval_with ctx store "(app (var text.join) (lit \"ok\") (lit 1))" with
  | Error (Runtime_err.Type_error message) ->
      Alcotest.(check string)
        "strict indexed diagnostic" "text.join expects Text at argument 2, got 1" message
  | Ok value -> Alcotest.failf "bad join unexpectedly returned %s" (Value.show value)
  | Error error -> Alcotest.failf "wrong join error: %s" (Runtime_err.to_string error)

let test_bool_functions () =
  Alcotest.(check string) "not" "false" (eval_ok "(app (var bool.not) (var true))");
  Alcotest.(check string) "and" "false" (eval_ok "(app (var bool.and) (var true) (var false))");
  Alcotest.(check string) "or" "true" (eval_ok "(app (var bool.or) (var false) (var true))")

(* the plan's map (add 1) [1,2,3] program, straight from the corpus *)
let test_map_program_from_corpus () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let src = Corpus_support.read_file "../corpus/valid/prelude-map.jqd" in
  match Reader.parse_string ~file:"prelude-map.jqd" src with
  | Ok [ f ] -> (
      let e = Result.get_ok (Kernel.expr_of_form f) in
      match Resolve.resolve_expr (Store.names_view store) e with
      | Error ds -> Eval_support.fail_diags "resolve" ds
      | Ok e -> (
          match Eval.run_expr ctx e with
          | Ok v ->
              Alcotest.(check string) "mapped list" "cons(2, cons(3, cons(4, nil)))" (Value.show v)
          | Error e -> Alcotest.failf "run failed: %s" (Runtime_err.to_string e)))
  | _ -> Alcotest.fail "prelude-map.jqd should hold one expression"

let test_fold () =
  Alcotest.(check string)
    "fold add over [1,2,3]" "6"
    (eval_ok
       "(app (var list.fold) (app (var cons) (lit 1) (app (var cons) (lit 2) (app (var cons) (lit \
        3) (var nil)))) (lit 0) (var add))");
  (* non-commutative op pins the LEFT fold direction: ((0-1)-2)-3 = -6 *)
  Alcotest.(check string)
    "fold sub over [1,2,3] is a left fold" "-6"
    (eval_ok
       "(app (var list.fold) (app (var cons) (lit 1) (app (var cons) (lit 2) (app (var cons) (lit \
        3) (var nil)))) (lit 0) (var sub))")

(* a program using console prints only under the grant *)
let test_console_gated () =
  let program = "(let nonrec (pwild) (app (var print) (lit \"hi jacquard\")) (lit 0))" in
  (* with the grant: output captured, program completes *)
  let store, ctx = Eval_support.make_prelude_ctx () in
  let buf = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string buf) with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_console" ds);
  (match Eval_support.eval_with ctx store program with
  | Ok v -> Alcotest.(check string) "completed" "0" (Value.show v)
  | Error e -> Alcotest.failf "granted run failed: %s" (Runtime_err.to_string e));
  Alcotest.(check string) "printed" "hi jacquard" (Buffer.contents buf);
  (* without: Unhandled naming console.print *)
  let store2, ctx2 = Eval_support.make_prelude_ctx () in
  match Eval_support.eval_with ctx2 store2 program with
  | Error (Runtime_err.Unhandled { effect_; op }) ->
      Alcotest.(check string) "effect" "console" effect_;
      Alcotest.(check string) "op" "print" op
  | Ok v -> Alcotest.failf "ungated print should fail, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Unhandled, got %s" (Runtime_err.to_string e)

let test_grant_mapping () =
  let _store, ctx = Eval_support.make_prelude_ctx () in
  (match Prelude.grant ctx "Console" ~out:ignore ~seed:0 ~infer_cache:None with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "grant is case-insensitive");
  (match Prelude.grant ctx "EVAL" ~out:ignore ~seed:0 ~infer_cache:None with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "grant EVAL");
  (match Prelude.grant ctx "net" ~out:ignore ~seed:0 ~infer_cache:None with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "net has a stub grant");
  match Prelude.grant ctx "filesystem" ~out:ignore ~seed:0 ~infer_cache:None with
  | Error [ d ] -> Alcotest.(check string) "ungrantable" "E0703" (Diag.code_or_uncoded d)
  | _ -> Alcotest.fail "unknown effect must not be grantable"

(* a handler written in Jacquard can still intercept a granted effect (interposition) *)
let test_handler_overrides_grant () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let buf = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string buf) with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_console" ds);
  (match
     Eval_support.eval_with ctx store
       "(handle (app (var print) (lit \"secret\")) (ret (pvar x) (var x)) (opclause print ((pvar \
        t)) k (app (var k) (tuple))))"
   with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "interposed run failed: %s" (Runtime_err.to_string e));
  Alcotest.(check string) "handler swallowed the print" "" (Buffer.contents buf)

(* APP.4: loading the prelude into a store that already holds it is idempotent, hidden derived
   members stay hidden from the public resolver view, and only the trusted loading view can name
   them. *)
let read_bytes path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let test_reload_is_idempotent () =
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-prelude-reload-%d" (Unix.getpid ()))
  in
  let load () =
    match Store.open_store root with
    | Error diagnostics ->
        Alcotest.failf "open store: %s" (String.concat "; " (List.map Diag.to_string diagnostics))
    | Ok store -> (
        match Prelude.load ~dir:"../prelude" store with
        | Ok _ -> store
        | Error diagnostics ->
            Alcotest.failf "prelude load: %s"
              (String.concat "; " (List.map Diag.to_string diagnostics)))
  in
  let objects () = Array.length (Sys.readdir (Filename.concat root "objects")) in
  let names_path = Filename.concat root "names.jqd" in
  ignore (load ());
  let first_names = read_bytes names_path and first_objects = objects () in
  let store = load () in
  Alcotest.(check string)
    "name index unchanged by a second load" first_names (read_bytes names_path);
  Alcotest.(check int) "object count unchanged by a second load" first_objects (objects ());
  List.iter
    (fun (name, kind) ->
      Alcotest.(check bool)
        (name ^ " stays hidden from the public view")
        true
        (Store.lookup_kind store name kind = None
        && (Store.names_view store).Resolve.lookup name = []);
      Alcotest.(check bool)
        (name ^ " resolves through the trusted loading view")
        true
        (List.exists
           (fun (entry : Resolve.entry) -> entry.Resolve.kind = kind)
           ((Store.trusted_names_view store).Resolve.lookup name)))
    [
      ("governance.fresh-audit-run-id", Resolve.KTerm);
      ("governance.require-audit-run-id", Resolve.KTerm);
      ("audit-sequence-v0", Resolve.KCon);
    ];
  Alcotest.(check bool)
    "public names are identical in both views" true
    ((Store.names_view store).Resolve.lookup "mul"
    = (Store.trusted_names_view store).Resolve.lookup "mul");
  (* the identical prelude reloads as a manifest no-op *)
  (match Prelude.load ~dir:"../prelude" store with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "an identical prelude must reload without installing anything"
  | Error diagnostics ->
      Alcotest.failf "reload: %s" (String.concat "; " (List.map Diag.to_string diagnostics)));
  (* a different prelude is refused before any mutation *)
  let edited = root ^ "-prelude" in
  Sys.mkdir edited 0o755;
  Array.iter
    (fun file ->
      if Filename.check_suffix file ".jqd" then begin
        let bytes = read_bytes (Filename.concat "../prelude" file) in
        let channel = open_out_bin (Filename.concat edited file) in
        output_string channel bytes;
        if String.equal file "02-data.jqd" then output_string channel "\n; edited\n";
        close_out channel
      end)
    (Sys.readdir "../prelude");
  (match Prelude.load ~dir:edited store with
  | Error (diagnostic :: _) ->
      Alcotest.(check string) "mismatch diagnostic" "E0705" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check bool)
        "mismatch names the changed file" true
        (Str.string_match (Str.regexp ".*changed: 02-data.jqd") (Diag.cause diagnostic) 0)
  | Error [] -> Alcotest.fail "mismatch produced no diagnostic"
  | Ok _ -> Alcotest.fail "a different prelude must be refused");
  Alcotest.(check string)
    "name index unchanged by a refused load" first_names (read_bytes names_path);
  Alcotest.(check int) "object count unchanged by a refused load" first_objects (objects ());
  (* a user binding that reuses a hidden member's name never displaces the prelude's identity,
     neither on the manifest fast path nor on a legacy store without a manifest *)
  let fail_diags label diagnostics =
    Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  let shadow =
    match
      Reader.parse_one ~file:"shadow.jqd"
        "(defterm ((binding governance.fresh-audit-run-id () (lit 7))))"
    with
    | Error diagnostics -> fail_diags "parse shadow" diagnostics
    | Ok form -> (
        match Kernel.decl_of_form form with
        | Error diagnostics -> fail_diags "shadow declaration" diagnostics
        | Ok declaration -> (
            match Resolve.resolve_decl (Store.names_view store) declaration with
            | Error diagnostics -> fail_diags "resolve shadow" diagnostics
            | Ok declaration -> (
                match Store.put_decl store declaration with
                | Error diagnostics -> fail_diags "put shadow" diagnostics
                | Ok hashes -> List.assoc "governance.fresh-audit-run-id" hashes.Canon.named)))
  in
  let objects_with_shadow = objects () and hidden_before = store.Store.hidden in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok [] -> ()
  | _ -> Alcotest.fail "fast path must still apply after a user install");
  Alcotest.(check bool)
    "fast path keeps the user's public binding" true
    (match Store.lookup_kind store "governance.fresh-audit-run-id" Resolve.KTerm with
    | Some { Resolve.hash; _ } -> Hash.equal hash shadow
    | None -> false);
  Sys.remove (Store.prelude_manifest_file store);
  let store = load () in
  Alcotest.(check int)
    "legacy reload installs no substituted objects" objects_with_shadow (objects ());
  Alcotest.(check bool)
    "legacy reload hides the same derived members" true
    (List.equal Hash.equal hidden_before store.Store.hidden);
  Alcotest.(check bool)
    "trusted view prefers the hidden member over the user binding" true
    (match (Store.trusted_names_view store).Resolve.lookup "governance.fresh-audit-run-id" with
    | { Resolve.hash; _ } :: _ -> List.exists (Hash.equal hash) store.Store.hidden
    | [] -> false);
  Alcotest.(check bool)
    "manifest restored by the legacy reload" true
    (Sys.file_exists (Store.prelude_manifest_file store));
  (* the builtin-wiring seam must also prefer the hidden member, or the user's binding would be
     wired to the audit-run-id builtin on reopen *)
  Alcotest.(check bool)
    "internal lookup prefers the hidden member over the user binding" true
    (match Store.lookup_internal_kind store "governance.fresh-audit-run-id" Resolve.KTerm with
    | Some { Resolve.hash; _ } ->
        List.exists (Hash.equal hash) store.Store.hidden && not (Hash.equal hash shadow)
    | None -> false);
  let rec remove_tree path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Sys.remove path
    | exception Unix.Unix_error _ -> ()
  in
  remove_tree root;
  remove_tree edited

let suite =
  [
    Alcotest.test_case "prelude reload is idempotent" `Quick test_reload_is_idempotent;
    Alcotest.test_case "prelude loads with zero diagnostics" `Quick test_loads_with_zero_diagnostics;
    Alcotest.test_case "prelude hashes golden-pinned" `Quick test_prelude_hashes_golden;
    Alcotest.test_case "builtins work" `Quick test_builtins_work;
    Alcotest.test_case "SS.22 real builtin identity" `Quick test_ss22_real_builtin_identity;
    Alcotest.test_case "SS.22 text.join identities" `Quick test_ss22_text_join_identity;
    Alcotest.test_case "SS.22 numeric predicates" `Quick test_ss22_numeric_predicates;
    Alcotest.test_case "SS.22 text.join" `Quick test_text_join;
    Alcotest.test_case "bool functions" `Quick test_bool_functions;
    Alcotest.test_case "map program from corpus" `Quick test_map_program_from_corpus;
    Alcotest.test_case "fold" `Quick test_fold;
    Alcotest.test_case "console gated" `Quick test_console_gated;
    Alcotest.test_case "grant mapping" `Quick test_grant_mapping;
    Alcotest.test_case "handler overrides grant" `Quick test_handler_overrides_grant;
  ]
