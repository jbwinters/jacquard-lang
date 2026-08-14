open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let runtime_ok label = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s: %s" label (Runtime_err.to_string error)

let surface_expression store path =
  let source = Corpus_support.read_file path in
  let parsed =
    match Surface_parse.strict (Surface_parse.recover_string ~file:path source) with
    | Ok parsed -> parsed
    | Error diagnostics -> fail_diags "parse relational regression fixture" diagnostics
  in
  let tops =
    match Surface_lower.lower_tops parsed with
    | Ok tops -> tops
    | Error diagnostics -> fail_diags "lower relational regression fixture" diagnostics
  in
  let rec install expression = function
    | [] -> (
        match expression with
        | Some expression -> expression
        | None -> Alcotest.fail "relational regression fixture has no expression")
    | top :: rest -> (
        match Resolve.resolve (Store.names_view store) top with
        | Error diagnostics -> fail_diags "resolve relational regression fixture" diagnostics
        | Ok (Kernel.Decl declaration) -> (
            match Store.put_decl store declaration with
            | Ok _ -> install expression rest
            | Error diagnostics -> fail_diags "install relational regression fixture" diagnostics)
        | Ok (Kernel.Expr next) -> (
            match expression with
            | None -> install (Some next) rest
            | Some _ -> Alcotest.fail "relational regression fixture has multiple expressions"))
  in
  install None tops

let bootstrap_expression store ~file source =
  match Reader.parse_one ~file source with
  | Error diagnostics -> fail_diags "parse cancellation regression fixture" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> fail_diags "validate cancellation regression fixture" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics -> fail_diags "resolve cancellation regression fixture" diagnostics))

let demo_path = "../demos/concurrency/task-schedules.jac"

let demo_transcript seed =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let expression = surface_expression store demo_path in
  let recorder = Run_transcript.create () in
  let scheduled =
    Run_transcript.record_expression recorder ctx (fun () ->
        Round_robin.run_expr_scheduled ctx ~policy:Concurrency_contract.Collect
          ~mode:(Round_robin.Seeded_schedule { seed })
          expression
        |> Result.map (fun scheduled -> scheduled.Round_robin.value))
    |> runtime_ok "run task-schedules.jac"
  in
  Alcotest.(check string) "demo result" "0" (Value.show scheduled);
  Run_transcript.transcript recorder |> Run_transcript.serialize

let test_task_schedule_transcripts_are_invariant () =
  match Relate.schedule_seeds ~root_seed:42 ~count:16 with
  | [] -> Alcotest.fail "relational schedule seed derivation returned no seeds"
  | first_seed :: rest ->
      let expected = demo_transcript first_seed in
      List.iteri
        (fun index seed ->
          Alcotest.(check string)
            (Printf.sprintf "task-schedules transcript run %d seed %d" (index + 2) seed)
            expected (demo_transcript seed))
        rest

let regression_gate =
  "(defeffect regression-gate ()\n\
  \  (op regression-gate.ready () (ttuple))\n\
  \  (op regression-gate.wait () (tref int))\n\
  \  (op regression-gate.mark () (ttuple))\n\
  \  (op regression-gate.probe () (tref int))\n\
  \  (op regression-gate.fail () (ttuple)))"

let operation_hash store name =
  match Store.lookup_kind store name Resolve.KOp with
  | Some entry -> entry.hash
  | None -> Alcotest.failf "missing test-only %s operation" name

let direct_cancel_source =
  {|
(let rec (pvar await-ready)
  (lam ()
    (match (app (var regression-gate.wait))
      (clause (plit 1) (tuple))
      (clause (pwild)
        (let nonrec (pwild) (app (var async.yield))
          (app (var await-ready))))))
  (let rec (pvar await-after)
    (lam ()
      (match (app (var regression-gate.probe))
        (clause (plit 1) (app (var print) (lit "orphan-direct")))
        (clause (pwild)
          (let nonrec (pwild) (app (var async.yield))
            (app (var await-after))))))
    (let nonrec (pvar ancestor)
      (app (var async.spawn)
        (lam ()
          (app (var async.scope)
            (lam ()
              (let nonrec (pwild) (app (var regression-gate.ready))
                (app (var await-after)))))))
      (let nonrec (pwild) (app (var await-ready))
        (let nonrec (pwild) (app (var async.cancel) (var ancestor))
          (let nonrec (pwild) (app (var regression-gate.mark))
            (app (var async.await) (var ancestor))))))))
|}

let fail_fast_source =
  {|
(let rec (pvar await-ready)
  (lam ()
    (match (app (var regression-gate.wait))
      (clause (plit 1) (tuple))
      (clause (pwild)
        (let nonrec (pwild) (app (var async.yield))
          (app (var await-ready))))))
  (let rec (pvar await-after)
    (lam ()
      (match (app (var regression-gate.probe))
        (clause (plit 1) (app (var print) (lit "orphan-fail-fast")))
        (clause (pwild)
          (let nonrec (pwild) (app (var async.yield))
            (app (var await-after))))))
    (let nonrec (pvar ancestor)
      (app (var async.spawn)
        (lam ()
          (app (var async.scope)
            (lam ()
              (app (var async.scope)
                (lam ()
                  (let nonrec (pwild) (app (var regression-gate.ready))
                    (app (var await-after)))))))))
      (let nonrec (pwild) (app (var await-ready))
        (let nonrec (pvar failing)
          (app (var async.spawn) (lam () (app (var regression-gate.fail))))
          (tuple (app (var async.await) (var ancestor))
            (app (var async.await) (var failing))))))))
|}

let run_cancellation_world ~label ~policy ~source seed =
  let store, ctx = Eval_support.make_prelude_ctx () in
  ignore (Eval_support.put_src store (Store.names_view store) regression_gate);
  let ready = ref false in
  let after = ref false in
  let printed = Buffer.create 32 in
  Eval.register_root_handler ctx (operation_hash store "regression-gate.ready") (function
    | [] ->
        ready := true;
        Ok Value.unit_v
    | _ -> Error (Runtime_err.Arity "regression-gate.ready expects no arguments"));
  Eval.register_root_handler ctx (operation_hash store "regression-gate.wait") (function
    | [] -> Ok (Value.VInt (if !ready then 1 else 0))
    | _ -> Error (Runtime_err.Arity "regression-gate.wait expects no arguments"));
  Eval.register_root_handler ctx (operation_hash store "regression-gate.mark") (function
    | [] ->
        after := true;
        Ok Value.unit_v
    | _ -> Error (Runtime_err.Arity "regression-gate.mark expects no arguments"));
  Eval.register_root_handler ctx (operation_hash store "regression-gate.probe") (function
    | [] -> Ok (Value.VInt (if !after then 1 else 0))
    | _ -> Error (Runtime_err.Arity "regression-gate.probe expects no arguments"));
  Eval.register_root_handler ctx (operation_hash store "regression-gate.fail") (function
    | [] ->
        after := true;
        Error (Runtime_err.Arithmetic "relational regression injected failure")
    | _ -> Error (Runtime_err.Arity "regression-gate.fail expects no arguments"));
  (match Prelude.install_console ctx ~out:(Buffer.add_string printed) with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install cancellation regression Console" diagnostics);
  let expression = bootstrap_expression store ~file:(label ^ ".jqd") source in
  ignore
    (Round_robin.run_expr_outcome_scheduled ctx ~policy
       ~mode:(Round_robin.Seeded_schedule { seed })
       expression
    |> runtime_ok ("run " ^ label));
  Alcotest.(check bool) (label ^ " reached nested descendant") true !ready;
  Alcotest.(check bool) (label ^ " delivered cancellation decision") true !after;
  let output = Buffer.contents printed in
  if not (String.equal output "") then
    Alcotest.failf "%s leaked sentinel `%s` under schedule seed %d" label output seed

let test_direct_cancel_closes_descendants_across_schedules () =
  Relate.schedule_seeds ~root_seed:42 ~count:64
  |> List.iter
       (run_cancellation_world ~label:"direct cancellation" ~policy:Concurrency_contract.Collect
          ~source:direct_cancel_source)

let test_fail_fast_closes_descendants_across_schedules () =
  Relate.schedule_seeds ~root_seed:42 ~count:64
  |> List.iter
       (run_cancellation_world ~label:"fail-fast cancellation"
          ~policy:Concurrency_contract.Fail_fast ~source:fail_fast_source)

let suite =
  [
    Alcotest.test_case "task-schedules transcripts across 16 seeds" `Quick
      test_task_schedule_transcripts_are_invariant;
    Alcotest.test_case "direct cancellation across 64 seeds" `Quick
      test_direct_cancel_closes_descendants_across_schedules;
    Alcotest.test_case "fail-fast cancellation across 64 seeds" `Quick
      test_fail_fast_closes_descendants_across_schedules;
  ]
