open Weft

let close a b = Float.abs (a -. b) < 1e-9

let real_lit f =
  let s = Printf.sprintf "%.12g" f in
  if String.contains s '.' || String.contains s 'e' || String.contains s 'E' then s else s ^ ".0"

let list entries =
  List.fold_right
    (fun (v, w) acc ->
      Printf.sprintf "(app (var cons) (app (var mk-pair) %s (lit %s)) %s)" v (real_lit w) acc)
    entries "(var nil)"

let categorical entries = Printf.sprintf "(app (var categorical) %s)" (list entries)

let model_state (store, _ctx) src =
  match Reader.parse_one ~file:"gauntlet-model.wft" src with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> Eval_support.fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr (Store.names_view store) e with
          | Error ds -> Eval_support.fail_diags "resolve" ds
          | Ok e -> Eval.expr_state e))

let enumerate src =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match Infer_dist.enumerate ctx (model_state h src) with
  | Ok p -> p
  | Error ds -> Eval_support.fail_diags "enumerate" ds

let posterior_map p = List.map (fun (v, pr) -> (Value.show v, pr)) p.Infer_dist.entries

let prob key entries =
  match List.assoc_opt key entries with
  | Some p -> p
  | None ->
      Alcotest.failf "posterior missing %s in [%s]" key
        (String.concat "; " (List.map (fun (v, p) -> Printf.sprintf "%s=%.12f" v p) entries))

let test_dynamic_branch_count () =
  let cat = categorical [ ("(lit 1)", 0.5); ("(lit 2)", 0.5) ] in
  let src =
    Printf.sprintf
      "(let nonrec (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5))) (match (var a) \
       (clause (pcon true) (app (var sample) %s)) (clause (pcon false) (lit 0))))"
      cat
  in
  let p = enumerate src |> posterior_map in
  Alcotest.(check int) "one false leaf, two true leaves" 3 (Infer_dist.last_branch_count ());
  Alcotest.(check bool) "P(0)=0.5" true (close (prob "0" p) 0.5);
  Alcotest.(check bool) "P(1)=0.25" true (close (prob "1" p) 0.25);
  Alcotest.(check bool) "P(2)=0.25" true (close (prob "2" p) 0.25)

let test_duplicate_support_mass_merges () =
  let src =
    Printf.sprintf "(app (var sample) %s)"
      (categorical [ ("(var true)", 0.25); ("(var true)", 0.25); ("(var false)", 0.5) ])
  in
  let p = enumerate src |> posterior_map in
  Alcotest.(check int) "three support entries were explored" 3 (Infer_dist.last_branch_count ());
  Alcotest.(check bool) "P(true)=0.5" true (close (prob "true" p) 0.5);
  Alcotest.(check bool) "P(false)=0.5" true (close (prob "false" p) 0.5)

let test_zero_probability_branch_is_not_resumed () =
  let src =
    Printf.sprintf
      "(let nonrec (pvar x) (app (var sample) %s) (match (var x) (clause (plit 0) (app (var div) \
       (lit 1) (lit 0))) (clause (plit 1) (var x))))"
      (categorical [ ("(lit 0)", 0.0); ("(lit 1)", 1.0) ])
  in
  let p = enumerate src |> posterior_map in
  Alcotest.(check int)
    "zero branch counted but pruned before eval" 2 (Infer_dist.last_branch_count ());
  Alcotest.(check bool) "P(1)=1" true (close (prob "1" p) 1.0)

let test_cloudy_sprinkler_rain_by_hand () =
  let src =
    "(let nonrec (pvar cloudy) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
    \  (let nonrec (pvar sprinkler)\n\
    \    (app (var sample)\n\
    \      (app (var bernoulli)\n\
    \        (match (var cloudy)\n\
    \          (clause (pcon true) (lit 0.1))\n\
    \          (clause (pcon false) (lit 0.5)))))\n\
    \    (let nonrec (pvar rain)\n\
    \      (app (var sample)\n\
    \        (app (var bernoulli)\n\
    \          (match (var cloudy)\n\
    \            (clause (pcon true) (lit 0.8))\n\
    \            (clause (pcon false) (lit 0.2)))))\n\
    \      (let nonrec (pvar wet-p)\n\
    \        (match (var sprinkler)\n\
    \          (clause (pcon true)\n\
    \            (match (var rain)\n\
    \              (clause (pcon true) (lit 0.99))\n\
    \              (clause (pcon false) (lit 0.90))))\n\
    \          (clause (pcon false)\n\
    \            (match (var rain)\n\
    \              (clause (pcon true) (lit 0.90))\n\
    \              (clause (pcon false) (lit 0.0)))))\n\
    \        (let nonrec (pwild) (app (var observe) (app (var bernoulli) (var wet-p)) (var true))\n\
    \          (var rain))))))"
  in
  let p = enumerate src |> posterior_map in
  Alcotest.(check bool)
    (Printf.sprintf "P(rain|wet)=0.7079276773, got %.12f" (prob "true" p))
    true
    (Float.abs (prob "true" p -. 0.7079276773296245) < 1e-9)

let suite =
  [
    Alcotest.test_case "dynamic branch count" `Quick test_dynamic_branch_count;
    Alcotest.test_case "duplicate support mass merges" `Quick test_duplicate_support_mass_merges;
    Alcotest.test_case "zero-probability branch is not resumed" `Quick
      test_zero_probability_branch_is_not_resumed;
    Alcotest.test_case "cloudy/sprinkler/rain posterior by hand" `Quick
      test_cloudy_sprinkler_rain_by_hand;
  ]
