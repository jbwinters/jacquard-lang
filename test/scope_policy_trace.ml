open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics -> failwith (String.concat "\n" (List.map Diag.to_string diagnostics))

let close scope =
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let show_result = function
  | Concurrency_contract.Done value -> Printf.sprintf "done(%d)" value
  | Concurrency_contract.Failed message -> "failed(" ^ message ^ ")"
  | Concurrency_contract.Cancelled -> "cancelled"

let show_fail_fast = function
  | Concurrency_contract.Done values ->
      "done([" ^ String.concat "," (List.map string_of_int values) ^ "])"
  | Concurrency_contract.Failed message -> "failed(" ^ message ^ ")"
  | Concurrency_contract.Cancelled -> "cancelled"

let fail_fast_trace () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let second = Structured_scope.spawn scope ~resume:2 |> ok in
  let third = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy = Scope_policy.create scope ~children:[ first; second; third ] |> ok in
  ignore (Structured_scope.checkout scope second |> ok);
  Structured_scope.suspend_yield scope second ~resume:21 |> ok;
  ignore (Structured_scope.checkout scope third |> ok);
  Structured_scope.suspend_yield scope third ~resume:31 |> ok;
  ignore (Structured_scope.checkout scope first |> ok);
  ignore (Structured_scope.fail scope first "first" |> ok);
  let dropped = ref [] in
  Scope_policy.record_terminal policy ~decision:7 first ~drop:(fun resume ->
      dropped := !dropped @ [ resume ])
  |> ok;
  Scope_policy.record_terminal policy ~decision:8 second ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:9 third ~drop:ignore |> ok;
  let result =
    match Scope_policy.finish policy |> ok with
    | Scope_policy.Fail_fast_result result -> show_fail_fast result
    | Scope_policy.Collect_result _ -> failwith "wrong policy result"
  in
  close scope;
  Printf.printf "fail-fast decision=7 result=%s dropped=%s\n" result
    (String.concat "," (List.map string_of_int !dropped))

let collect_trace () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let second = Structured_scope.spawn scope ~resume:2 |> ok in
  let third = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy =
    Scope_policy.create ~policy:Concurrency_contract.Collect scope
      ~children:[ first; second; third ]
    |> ok
  in
  ignore (Structured_scope.checkout scope third |> ok);
  ignore (Structured_scope.complete scope third 30 |> ok);
  ignore (Structured_scope.checkout scope first |> ok);
  ignore (Structured_scope.complete scope first 10 |> ok);
  ignore (Structured_scope.checkout scope second |> ok);
  ignore (Structured_scope.fail scope second "later" |> ok);
  Scope_policy.record_terminal policy ~decision:0 third ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:1 first ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:2 second ~drop:ignore |> ok;
  let results =
    match Scope_policy.finish policy |> ok with
    | Scope_policy.Collect_result results -> results
    | Scope_policy.Fail_fast_result _ -> failwith "wrong policy result"
  in
  close scope;
  Printf.printf "collect input-order=[%s]\n" (String.concat "," (List.map show_result results))

let () =
  fail_fast_trace ();
  collect_trace ()
