open Jacquard

(* INF.1: typed inference outcomes. The prelude's dist.enumerate-v1 and dist.sample-lw-v1 and the
   CLI's Infer_dist drivers share one classification: posterior, impossible, exhausted, or a
   numerical failure (underflow, non-finite, negative mass), with run metadata. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

(* model bodies, as bootstrap expressions over sample/observe *)
let coin_observed =
  "(let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \  (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.7)) (var c)) (var c)))"

let two_coins =
  "(let nonrec (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \  (let nonrec (pvar b) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \    (match (var a) (clause (pcon true) (var b)) (clause (pcon false) (var false)))))"

let impossible =
  "(let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.0)) (var true)) (lit 1))"

(* every support weight is zero: each branch has an exact zero factor *)
let all_zero =
  "(app (var sample) (app (var categorical)\n\
  \  (app (var cons) (app (var mk-pair) (lit 1) (lit 0.0))\n\
  \    (app (var cons) (app (var mk-pair) (lit 2) (lit 0.0)) (var nil)))))"

(* positive observation factors whose product underflows: 1e-200 * 1e-200 = 0 in binary64 (both
   drivers multiply observations; only enumeration also multiplies sample weights) *)
let underflow =
  let observe =
    "(app (var observe) (app (var categorical) (app (var cons) (app (var mk-pair) (lit 1) (lit \
     1e-200)) (var nil))) (lit 1))"
  in
  Printf.sprintf "(let nonrec (pwild) %s (let nonrec (pwild) %s (lit 1)))" observe observe

let weight_model w =
  Printf.sprintf
    "(app (var sample) (app (var categorical)\n\
    \  (app (var cons) (app (var mk-pair) (lit 1) %s)\n\
    \    (app (var cons) (app (var mk-pair) (lit 2) (lit 0.5)) (var nil)))))"
    w

let overflow = weight_model "(app (var real.mul) (lit 1e308) (lit 10.0))"

let not_a_number =
  weight_model
    "(app (var real.sub) (app (var real.mul) (lit 1e308) (lit 10.0)) (app (var real.mul) (lit \
     1e308) (lit 10.0)))"

let negative = weight_model "(lit -0.5)"

(* two finite weights whose sum overflows *)
let total_overflow =
  "(app (var sample) (app (var categorical)\n\
  \  (app (var cons) (app (var mk-pair) (lit 1) (lit 1e308))\n\
  \    (app (var cons) (app (var mk-pair) (lit 2) (lit 1e308)) (var nil)))))"

(* factors whose product is representable only when multiplied in model order: 1e-200 * 3e-124 *
   0.6 is a subnormal, while 0.6 * 3e-124 * 1e-200 rounds to zero *)
let order_sensitive =
  "(let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1e-200)) (var true))\n\
  \  (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 3e-124)) (var true))\n\
  \    (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.6)) (var true)) (lit \
   1))))"

let enumerate_v1 ?(budget = 100) body =
  eval_ok (Printf.sprintf "(app (var dist.enumerate-v1) (lam () %s) (lit %d))" body budget)

let lw_v1 ?(samples = 200) ?(seed = 7) body =
  eval_ok
    (Printf.sprintf "(app (var dist.sample-lw-v1) (lam () %s) (lit %d) (lit %d))" body samples seed)

let thunk body = eval_ok (Printf.sprintf "(lam () %s)" body)

(* the library outcome's classification tag and metadata *)
let tag (v : Value.t) =
  match v with
  | VCon { name = "ok"; args = [ VCon { name = "inference-posterior-v1"; _ } ]; _ } -> "posterior"
  | VCon { name = "err"; args = [ VCon { name = "inference-impossible-v1"; _ } ]; _ } ->
      "impossible"
  | VCon { name = "err"; args = [ VCon { name = "inference-exhausted-v1"; _ } ]; _ } -> "exhausted"
  | VCon
      {
        name = "err";
        args = [ VCon { name = "inference-numeric-failure-v1"; args = [ VCon { name; _ }; _ ]; _ } ];
        _;
      } -> (
      match name with
      | "inference-underflow-v1" -> "underflow"
      | "inference-non-finite-v1" -> "non-finite"
      | "inference-negative-mass-v1" -> "negative-mass"
      | other -> Alcotest.failf "unknown numeric reason %s" other)
  | v -> Alcotest.failf "not an inference outcome: %s" (Value.show v)

let metadata (v : Value.t) =
  let rec find = function
    | Value.VCon { name = "inference-metadata-v1"; args; _ } -> Some args
    | VCon { args; _ } -> List.find_map find args
    | _ -> None
  in
  match find v with
  | Some [ VCon { name = meth; _ }; VCon { name = complete; _ }; seed; VInt bound; VInt explored ]
    ->
      (meth, complete = "true", Value.show seed, bound, explored)
  | _ -> Alcotest.failf "no metadata in %s" (Value.show v)

let entries (v : Value.t) =
  match v with
  | VCon { name = "ok"; args = [ VCon { args = [ list; _ ]; _ } ]; _ } ->
      let rec go = function
        | Value.VCon { name = "cons"; args = [ VCon { args = [ x; VReal p ]; _ }; rest ]; _ } ->
            (Value.show x, p) :: go rest
        | _ -> []
      in
      go list
  | v -> Alcotest.failf "not a posterior: %s" (Value.show v)

(* merge by rendering, as the CLI does *)
let merged es =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun (k, p) -> Hashtbl.replace tbl k (p +. Option.value ~default:0.0 (Hashtbl.find_opt tbl k)))
    es;
  Hashtbl.fold (fun k p acc -> (k, p) :: acc) tbl [] |> List.sort compare

let close a b = Float.abs (a -. b) < 1e-12

let cli_tag (c : Infer_dist.classified) =
  match c.result with
  | Ok _ -> "posterior"
  | Error Infer_dist.Impossible -> "impossible"
  | Error Exhausted -> "exhausted"
  | Error (Numeric Underflow) -> "underflow"
  | Error (Numeric Non_finite) -> "non-finite"
  | Error (Numeric Negative_mass) -> "negative-mass"

let cli_enumerate ?max_branches body =
  match Infer_dist.enumerate_v1 ?max_branches ctx (Eval.apply_state ctx (thunk body) []) with
  | Ok c -> c
  | Error ds -> Alcotest.failf "driver failed: %s" (Diag.to_cause_string (List.hd ds))

let cli_lw ~samples ~seed body =
  match
    Infer_dist.likelihood_weighting_v1 ctx ~seed ~samples (fun () ->
        Eval.apply_state ctx (thunk body) [])
  with
  | Ok c -> c
  | Error ds -> Alcotest.failf "driver failed: %s" (Diag.to_cause_string (List.hd ds))

let cli_code (c : Infer_dist.classified) ~sampled =
  match Infer_dist.classified_to_result ~sampled c with
  | Ok _ -> "ok"
  | Error [ d ] -> Option.value ~default:"" (Diag.code d)
  | Error _ -> "several"

let test_normalized_posterior () =
  let v = enumerate_v1 coin_observed in
  Alcotest.(check string) "classified" "posterior" (tag v);
  let es = entries v in
  Alcotest.(check bool)
    "sums to one" true
    (close 1.0 (List.fold_left (fun a (_, p) -> a +. p) 0. es));
  Alcotest.(check bool)
    "true is 0.7" true
    (close 0.7 (List.assoc "true" es) && close 0.3 (List.assoc "false" es));
  let meth, complete, seed, bound, explored = metadata v in
  Alcotest.(check string) "method" "inference-exact-enumeration-v1" meth;
  Alcotest.(check bool) "complete" true complete;
  Alcotest.(check string) "no seed" "none" seed;
  Alcotest.(check (pair int int)) "bound and explored" (100, 2) (bound, explored)

let test_impossible_evidence () =
  List.iter
    (fun (label, body) ->
      Alcotest.(check string) (label ^ ": library") "impossible" (tag (enumerate_v1 body));
      let c = cli_enumerate body in
      Alcotest.(check string) (label ^ ": driver") "impossible" (cli_tag c);
      Alcotest.(check string) (label ^ ": CLI code") "E0901" (cli_code c ~sampled:false);
      Alcotest.(check string) (label ^ ": sampled") "impossible" (tag (lw_v1 body));
      Alcotest.(check string)
        (label ^ ": sampled CLI code") "E0901"
        (cli_code (cli_lw ~samples:50 ~seed:3 body) ~sampled:true))
    [ ("observation", impossible); ("all-zero support", all_zero) ]

let test_underflow_is_not_impossible () =
  Alcotest.(check string) "library" "underflow" (tag (enumerate_v1 underflow));
  let c = cli_enumerate underflow in
  Alcotest.(check string) "driver" "underflow" (cli_tag c);
  Alcotest.(check string) "CLI code" "E0917" (cli_code c ~sampled:false);
  Alcotest.(check string) "sampled" "underflow" (tag (lw_v1 underflow));
  (* the legacy CLI path pruned underflowed paths and called this impossible *)
  Alcotest.(check bool)
    "complete" true
    (let _, complete, _, _, _ = metadata (enumerate_v1 underflow) in
     complete)

let test_numeric_failures () =
  List.iter
    (fun (label, body, expected) ->
      Alcotest.(check string) (label ^ ": library") expected (tag (enumerate_v1 body));
      let c = cli_enumerate body in
      Alcotest.(check string) (label ^ ": driver") expected (cli_tag c);
      Alcotest.(check string) (label ^ ": CLI code") "E0917" (cli_code c ~sampled:false))
    [
      ("infinite weight", overflow, "non-finite");
      ("NaN weight", not_a_number, "non-finite");
      ("negative weight", negative, "negative-mass");
      ("overflowing total", total_overflow, "non-finite");
    ]

let test_bounded_exploration () =
  (* two coins: four terminal paths *)
  let within = enumerate_v1 ~budget:4 two_coins in
  Alcotest.(check string) "exactly the budget" "posterior" (tag within);
  let _, complete, _, bound, explored = metadata within in
  Alcotest.(check (triple bool int int))
    "complete at the budget" (true, 4, 4) (complete, bound, explored);
  let over = enumerate_v1 ~budget:3 two_coins in
  Alcotest.(check string) "one path too many" "exhausted" (tag over);
  let _, complete, _, bound, explored = metadata over in
  Alcotest.(check (triple bool int int)) "incomplete" (false, 3, 3) (complete, bound, explored);
  Alcotest.(check string) "zero budget" "exhausted" (tag (enumerate_v1 ~budget:0 two_coins));
  (* a non-positive budget is exhausted before the model runs: no runtime failure, no outcome *)
  let failing = "(app (var div) (lit 1) (lit 0))" in
  List.iter
    (fun budget ->
      let v = enumerate_v1 ~budget failing in
      Alcotest.(check string) (Printf.sprintf "budget %d: exhausted" budget) "exhausted" (tag v);
      let _, complete, _, _, explored = metadata v in
      Alcotest.(check (pair bool int)) "nothing explored" (false, 0) (complete, explored))
    [ 0; -3 ];
  Alcotest.(check string)
    "driver, zero budget" "exhausted"
    (cli_tag (cli_enumerate ~max_branches:0 failing));
  let c = cli_enumerate ~max_branches:3 two_coins in
  Alcotest.(check string) "driver" "exhausted" (cli_tag c);
  Alcotest.(check string) "CLI code" "E0918" (cli_code c ~sampled:false);
  Alcotest.(check (pair bool int))
    "driver metadata" (false, 3)
    (c.metadata.complete, c.metadata.explored);
  (* a pruned (zero-factor) path spends budget too *)
  Alcotest.(check string) "pruned paths count" "exhausted" (tag (enumerate_v1 ~budget:1 all_zero))

let test_seeded_sampling () =
  let a = lw_v1 ~samples:300 ~seed:11 coin_observed in
  let b = lw_v1 ~samples:300 ~seed:11 coin_observed in
  Alcotest.(check string) "same seed, same outcome" (Value.show a) (Value.show b);
  Alcotest.(check bool)
    "another seed differs" true
    (Value.show a <> Value.show (lw_v1 ~samples:300 ~seed:12 coin_observed));
  let meth, complete, seed, bound, explored = metadata a in
  Alcotest.(check string) "method" "inference-likelihood-weighting-v1" meth;
  Alcotest.(check bool) "sampling is never complete" false complete;
  Alcotest.(check string) "seed" "some(11)" seed;
  Alcotest.(check (pair int int)) "bound and runs" (300, 300) (bound, explored);
  (* the posterior agrees with the released dist.sample-lw on the same stream *)
  let legacy =
    match
      eval_ok
        (Printf.sprintf "(app (var dist.sample-lw) (lam () %s) (lit 300) (lit 11))" coin_observed)
    with
    | v ->
        let rec go = function
          | Value.VCon { name = "cons"; args = [ VCon { args = [ x; VReal p ]; _ }; rest ]; _ } ->
              (Value.show x, p) :: go rest
          | _ -> []
        in
        List.sort compare (go v)
  in
  List.iter2
    (fun (k1, p1) (k2, p2) ->
      Alcotest.(check string) "value" k1 k2;
      Alcotest.(check bool) (Printf.sprintf "%s: %g vs %g" k1 p1 p2) true (close p1 p2))
    legacy
    (merged (entries a));
  (* impossible runs are dropped, not weighted zero *)
  let half_impossible =
    "(let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
    \  (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1.0)) (var c)) (var c)))"
  in
  let v = lw_v1 ~samples:100 ~seed:5 half_impossible in
  Alcotest.(check bool)
    "only possible runs remain" true
    (List.for_all (fun (x, _) -> x = "true") (entries v))

(* the library and the CLI driver classify every model alike and agree on the posterior *)
let test_library_cli_agreement () =
  List.iter
    (fun (label, body) ->
      let lib = enumerate_v1 body in
      let c = cli_enumerate body in
      Alcotest.(check string) (label ^ ": enumeration") (tag lib) (cli_tag c);
      (match c.result with
      | Ok p ->
          let cli = List.sort compare (List.map (fun (v, p) -> (Value.show v, p)) p.entries) in
          List.iter2
            (fun (k1, p1) (k2, p2) ->
              Alcotest.(check string) (label ^ ": value") k1 k2;
              Alcotest.(check bool) (label ^ ": probability") true (close p1 p2))
            (merged (entries lib))
            cli
      | Error _ -> ());
      let lib = lw_v1 ~samples:64 ~seed:9 body in
      let c = cli_lw ~samples:64 ~seed:9 body in
      Alcotest.(check string) (label ^ ": sampling") (tag lib) (cli_tag c))
    [
      ("observed coin", coin_observed);
      ("two coins", two_coins);
      ("impossible", impossible);
      ("all zero", all_zero);
      ("underflow", underflow);
      ("overflow", overflow);
      ("NaN", not_a_number);
      ("negative", negative);
      ("overflowing total", total_overflow);
      ("factor order", order_sensitive);
    ];
  (* both multiply path factors in model order, so both find the subnormal posterior *)
  Alcotest.(check string) "order-sensitive product" "posterior" (tag (enumerate_v1 order_sensitive))

(* the released identities keep their behaviour: dist.enumerate still yields NaN weights *)
let test_legacy_identities_unchanged () =
  match eval_ok (Printf.sprintf "(app (var dist.enumerate) (lam () %s))" impossible) with
  | VCon { name = "cons"; args = [ VCon { args = [ _; VReal p ]; _ }; _ ]; _ } ->
      Alcotest.(check bool) "NaN weight" true (Float.is_nan p)
  | v -> Alcotest.failf "unexpected legacy result %s" (Value.show v)

let suite =
  [
    Alcotest.test_case "a normalized posterior with metadata" `Quick test_normalized_posterior;
    Alcotest.test_case "impossible evidence" `Quick test_impossible_evidence;
    Alcotest.test_case "underflow is not impossibility" `Quick test_underflow_is_not_impossible;
    Alcotest.test_case "non-finite and negative mass" `Quick test_numeric_failures;
    Alcotest.test_case "bounded exploration" `Quick test_bounded_exploration;
    Alcotest.test_case "seeded sampling" `Quick test_seeded_sampling;
    Alcotest.test_case "library and CLI agree" `Quick test_library_cli_agreement;
    Alcotest.test_case "released identities unchanged" `Quick test_legacy_identities_unchanged;
  ]
