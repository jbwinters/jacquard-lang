open Jacquard

(* W4.1-W4.4: the Dist layer — pmf, exact enumeration, likelihood weighting, and the
   in-language enumeration handler (stretch). *)

let two_coins_src =
  (* Two fair coins; observe at least one heads; posterior of the first coin.
     Derivation: joint = {TT:1/4, TF:1/4, FT:1/4, FF:1/4}; the observation
     or(c1,c2)=true keeps TT, TF, FT (mass 3/4). P(c1=true | obs) =
     (1/4 + 1/4) / (3/4) = 2/3; P(false) = 1/3. *)
  "(let nonrec (pvar c1) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \  (let nonrec (pvar c2) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \    (let nonrec (pwild)\n\
  \      (app (var observe) (app (var bernoulli) (lit 1.0)) (app (var bool.or) (var c1) (var c2)))\n\
  \      (var c1))))"

let sprinkler_src =
  (* Sprinkler: rain ~ B(0.2); sprinkler ~ B(0.4); grass wet if rain or sprinkler
     (deterministic or). Observe wet; posterior of rain.
     Derivation: P(wet) = 1 - P(!r)P(!s) = 1 - 0.8*0.6 = 0.52.
     P(rain & wet) = 0.2. P(rain | wet) = 0.2/0.52 = 5/13 = 0.384615...;
     P(!rain | wet) = 0.32/0.52 = 8/13. *)
  "(let nonrec (pvar rain) (app (var sample) (app (var bernoulli) (lit 0.2)))\n\
  \  (let nonrec (pvar sprinkler) (app (var sample) (app (var bernoulli) (lit 0.4)))\n\
  \    (let nonrec (pvar wet) (app (var bool.or) (var rain) (var sprinkler))\n\
  \      (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1.0)) (var wet))\n\
  \        (var rain)))))"

let impossible_src =
  (* observing an event of probability zero: empty posterior, not a crash *)
  "(let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \  (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.0)) (var true))\n\
  \    (var c)))"

let model_state (store, ctx) src =
  ignore ctx;
  match Reader.parse_one ~file:"model.jqd" src with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> Eval_support.fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr (Store.names_view store) e with
          | Error ds -> Eval_support.fail_diags "resolve" ds
          | Ok e -> Eval.expr_state e))

let posterior_alist p = List.map (fun (v, pr) -> (Value.show v, pr)) p.Infer_dist.entries
let close a b = Float.abs (a -. b) < 1e-9

let test_pmf () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let eval src =
    match Eval_support.eval_with ctx store src with
    | Ok v -> v
    | Error e -> Alcotest.failf "eval failed: %s" (Runtime_err.to_string e)
  in
  (match eval "(app (var pmf) (app (var bernoulli) (lit 0.3)) (var true))" with
  | Value.VReal p -> Alcotest.(check bool) "bernoulli true" true (close p 0.3)
  | v -> Alcotest.failf "expected real, got %s" (Value.show v));
  (match eval "(app (var pmf) (app (var bernoulli) (lit 0.3)) (var false))" with
  | Value.VReal p -> Alcotest.(check bool) "bernoulli false" true (close p 0.7)
  | v -> Alcotest.failf "expected real, got %s" (Value.show v));
  (* categorical, including a zero-probability value *)
  let cat =
    "(app (var categorical) (app (var cons) (app (var mk-pair) (lit 1) (lit 0.25)) (app (var cons) \
     (app (var mk-pair) (lit 2) (lit 0.75)) (var nil))))"
  in
  (match eval (Printf.sprintf "(app (var pmf) %s (lit 2))" cat) with
  | Value.VReal p -> Alcotest.(check bool) "categorical hit" true (close p 0.75)
  | v -> Alcotest.failf "expected real, got %s" (Value.show v));
  match eval (Printf.sprintf "(app (var pmf) %s (lit 9))" cat) with
  | Value.VReal p -> Alcotest.(check bool) "off support is 0" true (close p 0.0)
  | v -> Alcotest.failf "expected real, got %s" (Value.show v)

(* --- W4.2 enumeration --- *)

let test_two_coins_exact () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match Infer_dist.enumerate ctx (model_state h two_coins_src) with
  | Error ds -> Eval_support.fail_diags "enumerate" ds
  | Ok p -> (
      match posterior_alist p with
      | [ ("true", pt); ("false", pf) ] ->
          Alcotest.(check bool) "P(true) = 2/3" true (close pt (2. /. 3.));
          Alcotest.(check bool) "P(false) = 1/3" true (close pf (1. /. 3.))
      | other ->
          Alcotest.failf "unexpected posterior: %s"
            (String.concat "; " (List.map (fun (v, p) -> Printf.sprintf "%s=%f" v p) other)))

let test_two_coins_branch_count () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  (match Infer_dist.enumerate ctx (model_state h two_coins_src) with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "enumerate" ds);
  (* 2 coins x 2 outcomes = exactly 4 leaves: no duplicate resumption *)
  Alcotest.(check int) "exactly 4 branches" 4 (Infer_dist.last_branch_count ())

let test_sprinkler_exact () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match Infer_dist.enumerate ctx (model_state h sprinkler_src) with
  | Error ds -> Eval_support.fail_diags "enumerate" ds
  | Ok p -> (
      match posterior_alist p with
      | [ ("false", pf); ("true", pt) ] ->
          Alcotest.(check bool) "P(rain|wet) = 5/13" true (close pt (5. /. 13.));
          Alcotest.(check bool) "P(!rain|wet) = 8/13" true (close pf (8. /. 13.))
      | other ->
          Alcotest.failf "unexpected posterior: %s"
            (String.concat "; " (List.map (fun (v, p) -> Printf.sprintf "%s=%f" v p) other)))

let test_impossible_observation () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match Infer_dist.enumerate ctx (model_state h impossible_src) with
  | Ok _ -> Alcotest.fail "impossible observation must not produce a posterior"
  | Error [ d ] -> Alcotest.(check string) "empty posterior code" "E0901" d.Diag.code
  | Error _ -> Alcotest.fail "expected one diagnostic"

(* --- W4.3 likelihood weighting --- *)

let test_lw_two_coins () =
  (* seed fixed, K = 100000: within 0.01 of the exact 2/3 (the estimator's stderr at
     K=100k is ~0.0015, so 0.01 is a 6-sigma bound) *)
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match
    Infer_dist.likelihood_weighting ctx ~seed:42 ~samples:100000 (fun () ->
        model_state h two_coins_src)
  with
  | Error ds -> Eval_support.fail_diags "lw" ds
  | Ok p -> (
      match posterior_alist p with
      | [ ("true", pt); ("false", pf) ] ->
          Alcotest.(check bool)
            (Printf.sprintf "P(true) ~= 2/3 (got %f)" pt)
            true
            (Float.abs (pt -. (2. /. 3.)) < 0.01);
          Alcotest.(check bool) "P(false) ~= 1/3" true (Float.abs (pf -. (1. /. 3.)) < 0.01)
      | other ->
          Alcotest.failf "unexpected posterior: %s"
            (String.concat "; " (List.map (fun (v, p) -> Printf.sprintf "%s=%f" v p) other)))

let test_lw_sprinkler () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  match
    Infer_dist.likelihood_weighting ctx ~seed:7 ~samples:100000 (fun () ->
        model_state h sprinkler_src)
  with
  | Error ds -> Eval_support.fail_diags "lw" ds
  | Ok p -> (
      match List.assoc_opt "true" (posterior_alist p) with
      | Some pt ->
          Alcotest.(check bool)
            (Printf.sprintf "P(rain|wet) ~= 5/13 (got %f)" pt)
            true
            (Float.abs (pt -. (5. /. 13.)) < 0.01)
      | None -> Alcotest.fail "true missing from posterior")

let test_lw_determinism () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  let run seed =
    match
      Infer_dist.likelihood_weighting ctx ~seed ~samples:2000 (fun () ->
          model_state h two_coins_src)
    with
    | Ok p -> Infer_dist.show_posterior p
    | Error ds -> Eval_support.fail_diags "lw" ds
  in
  Alcotest.(check string) "same seed, identical output" (run 123) (run 123);
  Alcotest.(check bool) "different seeds differ" true (run 123 <> run 124)

(* the M3 thesis: the model FILE is byte-identical between the two algorithms — here the
   same source string and the same parsed hash drive both *)
let test_model_unchanged_between_algorithms () =
  let h = Eval_support.make_prelude_ctx () in
  let _, ctx = h in
  let hash_of src =
    match Reader.parse_one ~file:"m.jqd" src with
    | Ok f -> (
        let store, _ = h in
        match Kernel.expr_of_form f with
        | Ok e -> (
            match Resolve.resolve_expr (Store.names_view store) e with
            | Ok e -> (
                match Canon.hash_expr e with
                | Ok hh -> Hash.to_hex hh
                | Error _ -> Alcotest.fail "hash failed")
            | Error _ -> Alcotest.fail "resolve failed")
        | Error _ -> Alcotest.fail "validate failed")
    | Error _ -> Alcotest.fail "parse failed"
  in
  let h_enum = hash_of two_coins_src in
  (match Infer_dist.enumerate ctx (model_state h two_coins_src) with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "enumerate" ds);
  let h_lw = hash_of two_coins_src in
  (match
     Infer_dist.likelihood_weighting ctx ~seed:1 ~samples:100 (fun () ->
         model_state h two_coins_src)
   with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "lw" ds);
  Alcotest.(check string)
    "the model does not change between algorithms; only the handler does" h_enum h_lw

(* --- W4.4 (stretch): the enumeration handler written in Jacquard itself --- *)

let test_in_language_enumeration () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  (* enum-run over a thunk of the two-coins model, normalized in Jacquard *)
  let src =
    Printf.sprintf "(app (var normalize) (app (var enum-run) (lam () %s)))"
      (String.concat " " (String.split_on_char '\n' two_coins_src))
  in
  match Eval_support.eval_with ctx store src with
  | Error e -> Alcotest.failf "in-language handler failed: %s" (Runtime_err.to_string e)
  | Ok v ->
      (* collect the weighted list and merge duplicates natively for comparison *)
      let rec entries = function
        | Value.VCon { name = "nil"; _ } -> []
        | Value.VCon
            {
              name = "cons";
              args = [ Value.VCon { name = "mk-pair"; args = [ x; Value.VReal w ]; _ }; rest ];
              _;
            } ->
            (Value.show x, w) :: entries rest
        | v -> Alcotest.failf "unexpected result shape: %s" (Value.show v)
      in
      let merged = Hashtbl.create 4 in
      List.iter
        (fun (k, w) ->
          Hashtbl.replace merged k (w +. Option.value ~default:0.0 (Hashtbl.find_opt merged k)))
        (entries v);
      let p k = Option.value ~default:0.0 (Hashtbl.find_opt merged k) in
      Alcotest.(check bool)
        (Printf.sprintf "P(true) = 2/3 within 1e-9 (got %.12f)" (p "true"))
        true
        (close (p "true") (2. /. 3.));
      Alcotest.(check bool) "P(false) = 1/3 within 1e-9" true (close (p "false") (1. /. 3.))

(* E0815 keeps effectful top-level bodies out of models: the checker blocks them before the
   capturing driver could truncate their continuations (review regression). *)
let test_effectful_toplevel_blocked_in_infer () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  ignore
    (Eval_support.put_src store (Store.names_view store)
       "(defterm ((binding leaked () (app (var sample) (app (var bernoulli) (lit 0.5))))))");
  (* referencing the leaked term from a model must be rejected by the checker (the CLI runs
     infer_check first); here we assert the checker rejects it *)
  match Check.make_ctx store with
  | Error ds -> Eval_support.fail_diags "make_ctx" ds
  | Ok cctx -> (
      (match Prelude.builtin_signatures store with
      | Ok sigs -> List.iter (fun (h, s) -> Hashtbl.replace cctx.Check.builtin_sigs h s) sigs
      | Error _ -> ());
      ignore ctx;
      match Reader.parse_one ~file:"leak.jqd" "(var leaked)" with
      | Error ds -> Eval_support.fail_diags "parse" ds
      | Ok f -> (
          match Kernel.expr_of_form f with
          | Error ds -> Eval_support.fail_diags "validate" ds
          | Ok e -> (
              match Resolve.resolve_expr (Store.names_view store) e with
              | Error ds -> Eval_support.fail_diags "resolve" ds
              | Ok e -> (
                  match Check.check_top cctx (Kernel.Expr e) with
                  | Ok _ -> Alcotest.fail "effectful top-level body must be rejected"
                  | Error [ d ] -> Alcotest.(check string) "code" "E0815" d.Diag.code
                  | Error _ -> Alcotest.fail "expected one diagnostic"))))

let suite =
  [
    Alcotest.test_case "pmf builtin" `Quick test_pmf;
    Alcotest.test_case "two coins exact (2/3, 1/3)" `Quick test_two_coins_exact;
    Alcotest.test_case "two coins: exactly 4 branches" `Quick test_two_coins_branch_count;
    Alcotest.test_case "sprinkler exact (5/13)" `Quick test_sprinkler_exact;
    Alcotest.test_case "impossible observation" `Quick test_impossible_observation;
    Alcotest.test_case "lw two coins within 0.01" `Slow test_lw_two_coins;
    Alcotest.test_case "lw sprinkler within 0.01" `Slow test_lw_sprinkler;
    Alcotest.test_case "lw seed determinism" `Quick test_lw_determinism;
    Alcotest.test_case "model unchanged between algorithms" `Quick
      test_model_unchanged_between_algorithms;
    Alcotest.test_case "in-language enumeration handler (W4.4)" `Quick test_in_language_enumeration;
    Alcotest.test_case "E0815 blocks effectful top-level bodies in infer" `Quick
      test_effectful_toplevel_blocked_in_infer;
  ]
