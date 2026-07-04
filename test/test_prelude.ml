open Weft

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

let test_bool_functions () =
  Alcotest.(check string) "not" "false" (eval_ok "(app (var not) (var true))");
  Alcotest.(check string) "and" "false" (eval_ok "(app (var and) (var true) (var false))");
  Alcotest.(check string) "or" "true" (eval_ok "(app (var or) (var false) (var true))")

(* the plan's map (add 1) [1,2,3] program, straight from the corpus *)
let test_map_program_from_corpus () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let src = Corpus_support.read_file "../corpus/valid/prelude-map.wft" in
  match Reader.parse_string ~file:"prelude-map.wft" src with
  | Ok [ f ] -> (
      let e = Result.get_ok (Kernel.expr_of_form f) in
      match Resolve.resolve_expr (Store.names_view store) e with
      | Error ds -> Eval_support.fail_diags "resolve" ds
      | Ok e -> (
          match Eval.run_expr ctx e with
          | Ok v ->
              Alcotest.(check string) "mapped list" "cons(2, cons(3, cons(4, nil)))" (Value.show v)
          | Error e -> Alcotest.failf "run failed: %s" (Runtime_err.to_string e)))
  | _ -> Alcotest.fail "prelude-map.wft should hold one expression"

let test_fold () =
  Alcotest.(check string)
    "fold add over [1,2,3]" "6"
    (eval_ok
       "(app (var fold) (var add) (lit 0) (app (var cons) (lit 1) (app (var cons) (lit 2) (app \
        (var cons) (lit 3) (var nil)))))");
  (* non-commutative op pins the LEFT fold direction: ((0-1)-2)-3 = -6 *)
  Alcotest.(check string)
    "fold sub over [1,2,3] is a left fold" "-6"
    (eval_ok
       "(app (var fold) (var sub) (lit 0) (app (var cons) (lit 1) (app (var cons) (lit 2) (app \
        (var cons) (lit 3) (var nil)))))")

(* a program using console prints only under the grant *)
let test_console_gated () =
  let program = "(let nonrec (pwild) (app (var print) (lit \"hi weft\")) (lit 0))" in
  (* with the grant: output captured, program completes *)
  let store, ctx = Eval_support.make_prelude_ctx () in
  let buf = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string buf) with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_console" ds);
  (match Eval_support.eval_with ctx store program with
  | Ok v -> Alcotest.(check string) "completed" "0" (Value.show v)
  | Error e -> Alcotest.failf "granted run failed: %s" (Runtime_err.to_string e));
  Alcotest.(check string) "printed" "hi weft" (Buffer.contents buf);
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
  (match Prelude.grant ctx "Console" ~out:ignore with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "grant is case-insensitive");
  (match Prelude.grant ctx "EVAL" ~out:ignore with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "grant EVAL");
  (match Prelude.grant ctx "net" ~out:ignore with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "net has a stub grant");
  match Prelude.grant ctx "filesystem" ~out:ignore with
  | Error [ d ] -> Alcotest.(check string) "ungrantable" "E0703" d.Diag.code
  | _ -> Alcotest.fail "unknown effect must not be grantable"

(* a handler written in Weft can still intercept a granted effect (interposition) *)
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
    Alcotest.test_case "bool functions" `Quick test_bool_functions;
    Alcotest.test_case "map program from corpus" `Quick test_map_program_from_corpus;
    Alcotest.test_case "fold" `Quick test_fold;
    Alcotest.test_case "console gated" `Quick test_console_gated;
    Alcotest.test_case "grant mapping" `Quick test_grant_mapping;
    Alcotest.test_case "handler overrides grant" `Quick test_handler_overrides_grant;
  ]
