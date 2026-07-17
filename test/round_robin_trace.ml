open Jacquard

let fail diagnostics = failwith (String.concat "\n" (List.map Diag.to_string diagnostics))

let expression store source =
  let form =
    match Reader.parse_one ~file:"trace.jqd" source with Ok form -> form | Error ds -> fail ds
  in
  let expression = match Kernel.expr_of_form form with Ok expr -> expr | Error ds -> fail ds in
  match Resolve.resolve_expr (Store.names_view store) expression with
  | Ok expr -> expr
  | Error ds -> fail ds

let () =
  let prelude = Option.value ~default:"../prelude" (Sys.getenv_opt "JACQUARD_PRELUDE") in
  let store_dir =
    Filename.concat (Sys.getcwd ()) (Printf.sprintf "round-robin-trace-store-%d" (Unix.getpid ()))
  in
  let store = match Store.open_store store_dir with Ok s -> s | Error ds -> fail ds in
  (match Prelude.load ~dir:prelude store with Ok _ -> () | Error ds -> fail ds);
  let ctx = Eval.make_ctx store in
  (match Prelude.wire_builtins ctx with Ok () -> () | Error ds -> fail ds);
  let source =
    if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "nested" then
      "(let nonrec (pwild)\n\
      \   (app (var async.spawn)\n\
      \     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 9))))\n\
      \   (app (var async.scope)\n\
      \     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 42)))))"
    else
      "(let nonrec (pvar child)\n\
      \   (app (var async.spawn)\n\
      \     (lam ()\n\
      \       (let nonrec (pwild) (app (var async.yield))\n\
      \         (let nonrec (pwild) (app (var async.yield)) (lit 10)))))\n\
      \   (app (var async.await) (var child)))"
  in
  let expr = expression store source in
  let cache = Round_robin.create_cache () in
  match Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect expr with
  | Error error -> failwith (Runtime_err.to_string error)
  | Ok (first, first_status) -> (
      match Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect expr with
      | Error error -> failwith (Runtime_err.to_string error)
      | Ok (second, second_status) ->
          print_string first.trace;
          Printf.printf "cache=%s,%s identical=%b tasks=%d max-live=%d zero=%b\n"
            (match first_status with Miss -> "miss" | Hit -> "hit")
            (match second_status with Miss -> "miss" | Hit -> "hit")
            (String.equal first.trace second.trace)
            first.task_count first.max_live
            (first.metrics_after_close
            = Structured_scope.
                { open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 }))
