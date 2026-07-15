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
  Alcotest.(check int) "current prelude operation inventory size" 24 (List.length declared);
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
      ("infer.scripted", "forall a | e. (() ->{Infer, Throw | e} a, List Text) ->{Throw | e} a");
      ("net.record", "forall a | e. (() ->{Net | e} a) ->{Net | e} (a, Code)");
      ("test.replay", "forall a. (Code, () ->{Net, Throw} a) ->{Throw} a");
      ("net.scripted", "forall a | e. (() ->{Net, Throw | e} a, List Response) ->{Throw | e} a");
      ("console.scripted", "forall a | e. (() ->{Console, Throw | e} a, List Text) ->{Throw | e} a");
      ( "fs.in-memory",
        "forall a | e. (() ->{Fs, Throw | e} a, `type:map.t` Text Text) ->{Throw | e} (a, \
         `type:map.t` Text Text)" );
      ("test.replay-loose", "forall a. (Code, () ->{Net, Check, Throw} a) ->{Check, Throw} a");
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
  | Error [ d ] -> Alcotest.(check string) "ungrantable" "E0703" d.Diag.code
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

(* Hostile host-value tests intentionally forge the private payload representation with [Obj.magic].
   Ordinary library code cannot name [Task_handle.t], and Eval exposes no Task constructor. *)
let foreign_task ~scope_path ~spawn_index =
  Value.VTask (Obj.magic (ref (), scope_path, spawn_index))

let hostile_task_for_ctx ctx ~scope_path ~spawn_index =
  let payload = Obj.new_block 0 3 in
  Obj.set_field payload 0 (Obj.field (Obj.repr ctx) 1);
  Obj.set_field payload 1 (Obj.repr scope_path);
  Obj.set_field payload 2 (Obj.repr spawn_index);
  Value.VTask (Obj.obj payload)

let test_sc3_task_declarations_and_values () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let pinned name kind expected =
    match Store.lookup_kind store name kind with
    | Some entry ->
        Alcotest.(check string) (name ^ " identity") expected (Hash.to_hex entry.hash);
        let declaration =
          match Store.get store entry.hash with
          | Ok declaration -> declaration
          | Error diagnostics -> Eval_support.fail_diags ("load " ^ name) diagnostics
        in
        let printed = Printer.print_all [ Kernel.decl_to_form declaration ] in
        let reparsed =
          match Reader.parse_one ~file:(name ^ "-roundtrip.jqd") printed with
          | Error diagnostics -> Eval_support.fail_diags ("parse " ^ name) diagnostics
          | Ok form -> (
              match Kernel.decl_of_form form with
              | Ok declaration -> declaration
              | Error diagnostics -> Eval_support.fail_diags ("validate " ^ name) diagnostics)
        in
        let actual =
          match Canon.hash_decl reparsed with
          | Ok hashes -> (
              match List.assoc_opt name hashes.named with
              | Some hash -> Hash.to_hex hash
              | None -> Hash.to_hex hashes.decl_hash)
          | Error diagnostics -> Eval_support.fail_diags ("hash " ^ name) diagnostics
        in
        Alcotest.(check string) (name ^ " print/read/kernel roundtrip") expected actual
    | None -> Alcotest.failf "missing SC.3 prelude name %s" name
  in
  pinned "task" Resolve.KType Concurrency_contract.task_type_hash;
  pinned "task-result" Resolve.KType Concurrency_contract.task_result_type_hash;
  pinned "async" Resolve.KEffect Concurrency_contract.async_effect_hash;
  List.iter
    (fun (name, expected) -> pinned name Resolve.KOp expected)
    Concurrency_contract.async_operation_hashes;
  Alcotest.(check bool)
    "Task opaque carrier has no public constructor" true
    (Store.lookup_kind store "task-opaque" Resolve.KCon = None);
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not published") true
        (Store.lookup_kind store name Resolve.KTerm = None))
    [ "task.show"; "show.task"; "codec.task" ];
  let expect_value source expected =
    match Eval_support.eval_with ctx store source with
    | Ok value -> Alcotest.(check string) source expected (Value.show value)
    | Error error -> Alcotest.failf "%s failed: %s" source (Runtime_err.to_string error)
  in
  expect_value "(app (var done) (lit 42))" "done(42)";
  expect_value "(app (var failed) (lit \"stable\"))" "failed(\"stable\")";
  expect_value "(var cancelled)" "cancelled";
  let id = Concurrency_contract.task_id ~scope_path:[ 0; 2 ] ~spawn_index:3 in
  Alcotest.(check string)
    "deterministic scheduler ID" "0/2#3"
    (Concurrency_contract.trace_task_id id);
  let root_task = hostile_task_for_ctx ctx ~scope_path:[ 0 ] ~spawn_index:1 in
  Alcotest.(check string) "internal rendering stays opaque" "<task>" (Value.show root_task);
  (match Eval.validate_task_value ctx ~scope_path:[ 0 ] root_task with
  | Ok root_id ->
      Alcotest.(check string) "owned root ID" "0#1" (Concurrency_contract.trace_task_id root_id)
  | Error diagnostics -> Eval_support.fail_diags "validate hostile owned Task" diagnostics);
  let cross_scope = hostile_task_for_ctx ctx ~scope_path:[ 0; 2 ] ~spawn_index:3 in
  (match Eval.validate_task_value ctx ~scope_path:[ 0 ] cross_scope with
  | Error [ diagnostic ] -> Alcotest.(check string) "cross-scope code" "E0907" diagnostic.Diag.code
  | Error diagnostics -> Eval_support.fail_diags "unexpected cross-scope diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "same-run cross-scope Task was accepted");
  let task = foreign_task ~scope_path:[ 0; 2 ] ~spawn_index:3 in
  let other_store, other_ctx = Eval_support.make_prelude_ctx () in
  ignore other_store;
  (match Eval.validate_task_value other_ctx ~scope_path:[ 0; 2 ] task with
  | Error [ diagnostic ] -> Alcotest.(check string) "cross-run code" "E0907" diagnostic.code
  | Error diagnostics -> Eval_support.fail_diags "unexpected cross-run diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "cross-run Task reuse was accepted");
  let expect_invalid label result =
    match result with
    | Error (Runtime_err.Invalid_task_handle _) -> ()
    | Error error -> Alcotest.failf "%s wrong runtime error: %s" label (Runtime_err.to_string error)
    | Ok value -> Alcotest.failf "%s accepted foreign Task graph: %s" label (Value.show value)
  in
  let tuple_builtin =
    Value.VBuiltin ("foreign-tuple", function [] -> Ok (Value.VTuple [ task ]) | _ -> assert false)
  in
  expect_invalid "internal apply/builtin tuple" (Eval.call ctx tuple_builtin []);
  let done_hash =
    match Store.lookup_kind store "done" Resolve.KCon with
    | Some entry -> entry.hash
    | None -> Alcotest.fail "missing Done constructor"
  in
  let declaration =
    Eval_support.put_src store (Store.names_view store)
      "(defterm ((binding foreign-task-result () (lit 0))))"
  in
  let member = List.assoc "foreign-task-result" declaration.Canon.named in
  Eval.register_builtin ctx member
    (Value.VBuiltin
       ( "foreign-task-result",
         function
         | [] -> Ok (Value.VCon { con = done_hash; name = "done"; args = [ task ] })
         | _ -> assert false ));
  expect_invalid "run_expr constructor result"
    (Eval_support.eval_with ctx store "(app (var foreign-task-result))");
  expect_invalid "terminal tuple state"
    (match Eval.run_state_capturing ctx (Eval.SApply (Value.VTuple [ task ], [])) with
    | Ok (Eval.CValue value) -> Ok value
    | Ok (Eval.COp _) -> Alcotest.fail "foreign terminal state unexpectedly performed"
    | Error error -> Error error);
  let malformed = foreign_task ~scope_path:[] ~spawn_index:(-1) in
  match Eval.validate_task_value ctx ~scope_path:[ 0 ] malformed with
  | Error [ diagnostic ] -> Alcotest.(check string) "malformed handle code" "E0907" diagnostic.code
  | Error diagnostics -> Eval_support.fail_diags "unexpected malformed diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "malformed Task handle was accepted"

let test_sc3_task_opaque_checker_and_unhandled_async () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let opaque_source =
    Printf.sprintf "(ref #%s con)" Concurrency_contract.task_opaque_constructor_hash
  in
  let expression =
    match Reader.parse_one ~file:"private-task.jqd" opaque_source with
    | Ok form -> Result.get_ok (Kernel.expr_of_form form)
    | Error diagnostics -> Eval_support.fail_diags "parse private Task ref" diagnostics
  in
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make Task checker" diagnostics
  in
  (match Check.check_top checker (Kernel.Expr expression) with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "private constructor code" "E0907" diagnostic.code
  | Error diagnostics -> Eval_support.fail_diags "unexpected private Task diagnostics" diagnostics
  | Ok _ -> Alcotest.fail "checker accepted the scheduler-private Task carrier");
  (match Eval.run_expr ctx expression with
  | Error (Runtime_err.Invalid_task_handle _) -> ()
  | Error error ->
      Alcotest.failf "private Task wrong runtime error: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "runtime constructed private Task carrier: %s" (Value.show value));
  let lit = Kernel.{ it = Lit (LInt 1); meta = Meta.empty } in
  let thunk = Value.VClosure { scope = Value.empty_scope; params = []; body = lit } in
  let task = hostile_task_for_ctx ctx ~scope_path:[ 0 ] ~spawn_index:1 in
  let cases =
    [
      ("async.spawn", [ thunk ]);
      ("async.await", [ task ]);
      ("async.cancel", [ task ]);
      ("async.yield", []);
    ]
  in
  List.iter
    (fun (name, args) ->
      let operation =
        match Eval_support.eval_with ctx store (Printf.sprintf "(var %s)" name) with
        | Ok operation -> operation
        | Error error -> Alcotest.failf "load %s: %s" name (Runtime_err.to_string error)
      in
      match Eval.call ctx operation args with
      | Error (Runtime_err.Unhandled { effect_; op }) ->
          Alcotest.(check string) (name ^ " unhandled effect") "async" effect_;
          Alcotest.(check string) (name ^ " unhandled op") name op
      | Error error -> Alcotest.failf "%s wrong error: %s" name (Runtime_err.to_string error)
      | Ok value -> Alcotest.failf "%s unexpectedly returned %s" name (Value.show value))
    cases

let test_sc3_validated_state_context_binding () =
  let store_a, ctx_a = Eval_support.make_prelude_ctx () in
  let _store_b, ctx_b = Eval_support.make_prelude_ctx () in
  let task = hostile_task_for_ctx ctx_a ~scope_path:[ 0 ] ~spawn_index:7 in
  let expect_e0907 label = function
    | Error (Runtime_err.Invalid_task_handle _) -> ()
    | Error error ->
        Alcotest.failf "%s returned the wrong error: %s" label (Runtime_err.to_string error)
    | Ok _ -> Alcotest.failf "%s accepted an artifact from another evaluator context" label
  in
  let validate label state =
    match Eval.validate_state_once ctx_a state with
    | Ok validated -> validated
    | Error error ->
        Alcotest.failf "%s failed validation in its owning context: %s" label
          (Runtime_err.to_string error)
  in
  let terminal = validate "terminal state" (Eval.SApply (Value.VTuple [ task ], [])) in
  expect_e0907 "validated state executed under B"
    (Eval.run_validated_state_capturing ctx_b terminal);
  expect_e0907 "validated state freshened and executed under B"
    (Eval.run_validated_state_capturing ctx_b (Eval.fresh_validated_state ctx_b terminal));
  let await =
    match Eval_support.eval_with ctx_a store_a "(var async.await)" with
    | Ok operation -> operation
    | Error error -> Alcotest.failf "load async.await: %s" (Runtime_err.to_string error)
  in
  let operation_state =
    Eval.SApply
      ( task,
        [
          Value.FAppArgs { fn = await; done_rev = []; pending = []; scope = Value.empty_scope };
          Value.FTuple { done_rev = [ task ]; pending = []; scope = Value.empty_scope };
        ] )
  in
  let validated_operation = validate "operation state" operation_state in
  expect_e0907 "validated operation captured under B"
    (Eval.run_validated_state_capturing ctx_b validated_operation);
  let args, validated_kont =
    match Eval.run_validated_state_capturing ctx_a validated_operation with
    | Ok (Eval.VCOp { name = "async.await"; args; kont; _ }) -> (args, kont)
    | Ok (Eval.VCOp { name; _ }) -> Alcotest.failf "captured unexpected operation %s" name
    | Ok (Eval.VCValue value) ->
        Alcotest.failf "operation state returned instead of capturing: %s" (Value.show value)
    | Error error ->
        Alcotest.failf "owning-context capture failed: %s" (Runtime_err.to_string error)
  in
  (match args with
  | [ Value.VTask _ ] -> ()
  | _ -> Alcotest.fail "captured async.await arguments lost their Task payload");
  expect_e0907 "captured operation arguments reused under B"
    (Eval.run_state_capturing ctx_b (Eval.SApply (Value.VTuple args, [])));
  expect_e0907 "validated continuation resumed under B"
    (Eval.resume_validated_state ctx_b validated_kont (Value.VInt 11));
  let resumed_in_a =
    match Eval.resume_validated_state ctx_a validated_kont (Value.VInt 11) with
    | Ok state -> state
    | Error error ->
        Alcotest.failf "foreign resume consumed the validated Once budget: %s"
          (Runtime_err.to_string error)
  in
  (match Eval.run_validated_state_capturing ctx_a resumed_in_a with
  | Ok (Eval.VCValue value) ->
      Alcotest.(check string)
        "validated continuation remains usable in A" "(<task>, 11)" (Value.show value)
  | Ok (Eval.VCOp _) -> Alcotest.fail "validated resume unexpectedly captured another operation"
  | Error error -> Alcotest.failf "validated resumed run failed: %s" (Runtime_err.to_string error));
  let ordinary_kont =
    match Eval.run_state_capturing ctx_a operation_state with
    | Ok (Eval.COp { name = "async.await"; kont; _ }) -> kont
    | Ok (Eval.COp { name; _ }) -> Alcotest.failf "captured unexpected operation %s" name
    | Ok (Eval.CValue value) ->
        Alcotest.failf "ordinary operation state returned: %s" (Value.show value)
    | Error error ->
        Alcotest.failf "ordinary owning-context capture failed: %s" (Runtime_err.to_string error)
  in
  expect_e0907 "ordinary continuation resumed under B"
    (Eval.resume_captured_state ctx_b ordinary_kont (Value.VInt 12));
  let resumed_in_a =
    match Eval.resume_captured_state ctx_a ordinary_kont (Value.VInt 12) with
    | Ok state -> state
    | Error error ->
        Alcotest.failf "foreign resume consumed the ordinary Once budget: %s"
          (Runtime_err.to_string error)
  in
  (match Eval.run_state_capturing ctx_a resumed_in_a with
  | Ok (Eval.CValue value) ->
      Alcotest.(check string)
        "ordinary continuation remains usable in A" "(<task>, 12)" (Value.show value)
  | Ok (Eval.COp _) -> Alcotest.fail "ordinary resume unexpectedly captured another operation"
  | Error error -> Alcotest.failf "ordinary resumed run failed: %s" (Runtime_err.to_string error));
  let yield_operation =
    match Eval_support.eval_with ctx_a store_a "(var async.yield)" with
    | Ok operation -> operation
    | Error error -> Alcotest.failf "load async.yield: %s" (Runtime_err.to_string error)
  in
  let once_resume =
    let state =
      Eval.SApply (yield_operation, [ Value.FAppFn { args = []; scope = Value.empty_scope } ])
    in
    match Eval.run_state_capturing_once ctx_a state with
    | Ok (Eval.OCOp { name = "async.yield"; resume; _ }) -> resume
    | Ok (Eval.OCOp { name; _ }) -> Alcotest.failf "captured unexpected operation %s" name
    | Ok (Eval.OCValue value) ->
        Alcotest.failf "async.yield returned instead of capturing: %s" (Value.show value)
    | Error error -> Alcotest.failf "async.yield capture failed: %s" (Runtime_err.to_string error)
  in
  expect_e0907 "low-level Once resume invoked under B"
    (Eval.call ctx_b once_resume [ Value.unit_v ]);
  match Eval.call ctx_a once_resume [ Value.unit_v ] with
  | Ok value -> Alcotest.(check string) "low-level Once remains usable in A" "()" (Value.show value)
  | Error error ->
      Alcotest.failf "foreign low-level resume consumed the Once budget: %s"
        (Runtime_err.to_string error)

let suite =
  [
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
    Alcotest.test_case "SC.3 Task declarations and values" `Quick
      test_sc3_task_declarations_and_values;
    Alcotest.test_case "SC.3 private Task and unhandled Async" `Quick
      test_sc3_task_opaque_checker_and_unhandled_async;
    Alcotest.test_case "SC.3 validated state context binding" `Quick
      test_sc3_validated_state_context_binding;
  ]
