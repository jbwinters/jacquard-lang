open Jacquard

(* W2.6: the real prelude — loads clean, hashes pinned, library functions work, and the
   console effect prints only under a grant. *)

let golden_file = "../corpus/golden/prelude-hashes.golden"

let test_loads_with_zero_diagnostics () =
  let _store, _ctx = Eval_support.make_prelude_ctx () in
  (* make_prelude_ctx fails the test on any diagnostic *)
  ()

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
        expected actual

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
  ]
