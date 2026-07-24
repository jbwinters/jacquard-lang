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
  Alcotest.(check int) "exactly 4 branches" 4 (Infer_dist.last_branch_count ());
  let store, ctx = Eval_support.make_prelude_ctx () in
  ignore
    (Eval_support.put_src store (Store.names_view store)
       "(defeffect linear-dist ((tvar a)) (op sample once ((tvar a)) (tvar a)))");
  match
    Infer_dist.enumerate ctx
      (model_state (store, ctx) "(app (var sample) (app (var bernoulli) (lit 0.5)))")
  with
  | Error [ diagnostic ] ->
      Alcotest.(check string)
        "driver reports runtime capture failure" "E0902" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check bool)
        "enumeration cannot duplicate a declared Once sample" true
        (String.starts_with ~prefix:"a once continuation may be resumed" (Diag.cause diagnostic))
  | Error diagnostics ->
      Alcotest.failf "declared Once sample returned unexpected diagnostics: %s"
        (String.concat "; " (List.map Diag.to_string diagnostics))
  | Ok posterior ->
      Alcotest.failf "enumeration duplicated declared Once sample: %s"
        (Infer_dist.show_posterior posterior)

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
  | Error [ d ] -> Alcotest.(check string) "empty posterior code" "E0901" (Diag.code_or_uncoded d)
  | Error _ -> Alcotest.fail "expected one diagnostic"

(* --- GM.21 bounded exact risk-enumeration core --- *)

let expect_exact_risk_error code ctx ~max_branches state =
  match Infer_dist.enumerate_risk_exact ctx ~max_branches state with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "exact risk diagnostic" code (Diag.code_or_uncoded diagnostic)
  | Error diagnostics ->
      Alcotest.failf "expected one %s diagnostic, got: %s" code
        (String.concat "; " (List.map Diag.to_string diagnostics))
  | Ok _ -> Alcotest.failf "expected exact risk enumeration to fail with %s" code

let duplicate_risk_observation_src =
  "(let nonrec (pvar risk-value)\n\
  \  (app (var sample)\n\
  \    (app (var categorical)\n\
  \      (app (var cons) (app (var mk-pair) (var low) (lit 0.2))\n\
  \        (app (var cons) (app (var mk-pair) (var low) (lit 0.3))\n\
  \          (app (var cons) (app (var mk-pair) (var high) (lit 0.5)) (var nil))))))\n\
  \  (let nonrec (pwild)\n\
  \    (app (var observe)\n\
  \      (app (var categorical)\n\
  \        (app (var cons) (app (var mk-pair) (var true) (lit 0.25))\n\
  \          (app (var cons) (app (var mk-pair) (var true) (lit 0.5))\n\
  \            (app (var cons) (app (var mk-pair) (var false) (lit 0.25)) (var nil)))))\n\
  \      (var true))\n\
  \    (var risk-value)))"

let test_exact_risk_duplicate_leaves_and_observation () =
  let harness = Eval_support.make_prelude_ctx () in
  let _, ctx = harness in
  match
    Infer_dist.enumerate_risk_exact ctx ~max_branches:3
      (model_state harness duplicate_risk_observation_src)
  with
  | Error diagnostics -> Eval_support.fail_diags "exact duplicate risk model" diagnostics
  | Ok result ->
      let weights : Infer_dist.risk_weights = result.weights in
      let support : Infer_dist.risk_positive_support = result.positive_support in
      let branches : Infer_dist.risk_branch_accounting = result.branches in
      (* Duplicate low leaves add in support order: (0.2 * 0.75) + (0.3 * 0.75).
         The duplicate observed true entries contribute 0.25 + 0.5 exactly once per path. *)
      Alcotest.(check bool) "raw low weight" true (close weights.low 0.375);
      Alcotest.(check bool) "raw medium weight" true (close weights.medium 0.0);
      Alcotest.(check bool) "raw high weight" true (close weights.high 0.375);
      Alcotest.(check bool) "raw forbidden weight" true (close weights.forbidden 0.0);
      Alcotest.(check bool) "low has positive support" true support.low;
      Alcotest.(check bool) "medium has no positive support" false support.medium;
      Alcotest.(check bool) "high has positive support" true support.high;
      Alcotest.(check bool) "forbidden has no positive support" false support.forbidden;
      Alcotest.(check int) "three duplicate-preserving terminal paths" 3 branches.completed;
      Alcotest.(check int) "all terminal paths theoretically positive" 3 branches.positive;
      Alcotest.(check int) "no explicit-zero paths" 0 branches.zero_weight;
      Alcotest.(check int) "no underflowed paths" 0 branches.underflowed

let four_risk_branches_src =
  "(let nonrec (pvar first) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \  (let nonrec (pvar second) (app (var sample) (app (var bernoulli) (lit 0.5)))\n\
  \    (var low)))"

let test_exact_risk_branch_budget () =
  let harness = Eval_support.make_prelude_ctx () in
  let _, ctx = harness in
  expect_exact_risk_error "E0910" ctx ~max_branches:0 (model_state harness four_risk_branches_src);
  expect_exact_risk_error "E0912" ctx ~max_branches:3 (model_state harness four_risk_branches_src);
  match
    Infer_dist.enumerate_risk_exact ctx ~max_branches:4 (model_state harness four_risk_branches_src)
  with
  | Error diagnostics -> Eval_support.fail_diags "exact risk budget boundary" diagnostics
  | Ok result ->
      Alcotest.(check int) "budget equality accepts all branches" 4 result.branches.completed;
      Alcotest.(check bool) "all low mass retained" true (close result.weights.low 1.0)

let malformed_categorical_src weight =
  Printf.sprintf
    "(app (var sample)\n\
    \  (app (var categorical)\n\
    \    (app (var cons) (app (var mk-pair) (var low) (lit %s)) (var nil))))"
    weight

let test_exact_risk_rejects_malformed_categorical_weights () =
  let harness = Eval_support.make_prelude_ctx () in
  let _, ctx = harness in
  List.iter
    (fun weight ->
      expect_exact_risk_error "E0911" ctx ~max_branches:1
        (model_state harness (malformed_categorical_src weight)))
    [ "-1.0"; "+nan.0"; "+inf.0" ]

let closure_collision_observation_src =
  "(let nonrec (pvar support-fn) (lam ((pvar x)) (var x))\n\
  \  (let nonrec (pwild)\n\
  \    (app (var observe)\n\
  \      (app (var categorical)\n\
  \        (app (var cons) (app (var mk-pair) (var support-fn) (lit 1.0)) (var nil)))\n\
  \      (lam ((pvar x)) (app (var add) (var x) (lit 1))))\n\
  \    (var low)))"

let test_exact_risk_rejects_opaque_observation_values () =
  let harness = Eval_support.make_prelude_ctx () in
  let _, ctx = harness in
  (* Both closures render as [<closure>]. Exact observe must reject them rather than treating
     presentation equality as semantic equality and preserving an impossible branch. *)
  expect_exact_risk_error "E0911" ctx ~max_branches:1
    (model_state harness closure_collision_observation_src)

let test_exact_risk_rejects_wrong_result_unexpected_effect_and_runtime_failure () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let forged_low =
    match Store.lookup_kind store "none" Resolve.KCon with
    | Some { Resolve.hash; _ } -> Value.VCon { con = hash; name = "low"; args = [] }
    | None -> Alcotest.fail "prelude none constructor is unavailable"
  in
  expect_exact_risk_error "E0913" ctx ~max_branches:1 (Eval.SApply (forged_low, []));
  expect_exact_risk_error "E0914" ctx ~max_branches:1
    (model_state (store, ctx) "(app (var throw) (lit \"unexpected\"))");
  expect_exact_risk_error "E0915" ctx ~max_branches:1
    (model_state (store, ctx) "(app (var div) (lit 1) (lit 0))")

let underflowed_high_risk_src =
  "(let nonrec (pwild)\n\
  \  (app (var sample)\n\
  \    (app (var categorical)\n\
  \      (app (var cons) (app (var mk-pair) (var true) (lit 1e-200)) (var nil))))\n\
  \  (app (var sample)\n\
  \    (app (var categorical)\n\
  \      (app (var cons) (app (var mk-pair) (var high) (lit 1e-200)) (var nil)))))"

let test_exact_risk_preserves_underflowed_positive_support () =
  let harness = Eval_support.make_prelude_ctx () in
  let _, ctx = harness in
  match
    Infer_dist.enumerate_risk_exact ctx ~max_branches:1
      (model_state harness underflowed_high_risk_src)
  with
  | Error diagnostics -> Eval_support.fail_diags "underflowed exact risk" diagnostics
  | Ok result ->
      let weights : Infer_dist.risk_weights = result.weights in
      let support : Infer_dist.risk_positive_support = result.positive_support in
      let branches : Infer_dist.risk_branch_accounting = result.branches in
      Alcotest.(check (float 0.0)) "binary64 raw high weight underflowed" 0.0 weights.high;
      Alcotest.(check bool) "high remains theoretically reachable" true support.high;
      Alcotest.(check bool) "forbidden remains unreachable" false support.forbidden;
      Alcotest.(check int) "one completed path" 1 branches.completed;
      Alcotest.(check int) "one theoretically positive path" 1 branches.positive;
      Alcotest.(check int) "one underflowed positive path" 1 branches.underflowed;
      Alcotest.(check int) "no explicit-zero path" 0 branches.zero_weight

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

let test_lw_validates_one_reusable_initial_state () =
  let harness = Eval_support.make () in
  let ctx = harness.Eval_support.ctx in
  let factory_calls = ref 0 in
  let clean_model () =
    incr factory_calls;
    Eval.expr_state Kernel.{ it = Lit (LInt 3); meta = Meta.empty }
  in
  (match Infer_dist.likelihood_weighting ctx ~seed:9 ~samples:5 clean_model with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "clean reusable model" diagnostics);
  Alcotest.(check int) "clean model factory called once" 1 !factory_calls;
  let action_calls = ref 0 in
  let action =
    Value.VBuiltin
      ( "marked-model-action",
        fun _ ->
          incr action_calls;
          Ok (Value.VInt 0) )
  in
  let scope =
    Value.{ empty_scope with env = Env.add "marked-model-action" (ref action) empty_scope.env }
  in
  let marker = Meta.empty |> Meta.with_surface_hole "lw-initial-model" in
  let marked_factory_calls = ref 0 in
  let marked_model () =
    incr marked_factory_calls;
    Eval.SEval
      ( scope,
        Kernel.
          { it = App ({ it = Var "marked-model-action"; meta = Meta.empty }, []); meta = marker },
        [] )
  in
  (match Infer_dist.likelihood_weighting ctx ~seed:9 ~samples:5 marked_model with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "marked initial diagnostic" "E0902" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check bool)
        "marked initial preserves E1202" true
        (String.starts_with ~prefix:"type error: E1202:" (Diag.cause diagnostic))
  | Error diagnostics -> Eval_support.fail_diags "marked reusable model" diagnostics
  | Ok _ -> Alcotest.fail "marked initial model was accepted");
  Alcotest.(check int) "marked model factory called once" 1 !marked_factory_calls;
  Alcotest.(check int) "marked model rejected before action" 0 !action_calls

let test_lw_rejects_zero_argument_continuation_mutation () =
  let harness = Eval_support.make () in
  let ctx = harness.Eval_support.ctx in
  let marker = Meta.empty |> Meta.with_surface_hole "lw-native-continuation-mutation" in
  let marked = Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] } in
  let continuation_cell = ref (Value.VInt 7) in
  let continuation_scope =
    Value.{ empty_scope with env = Env.add "guarded-cell" continuation_cell empty_scope.env }
  in
  let following_calls = ref 0 in
  let following =
    Value.VBuiltin
      ( "lw-following-action",
        fun _ ->
          incr following_calls;
          Ok (Value.VInt 0) )
  in
  let following_scope =
    Value.{ empty_scope with env = Env.add "following" (ref following) empty_scope.env }
  in
  let mutator =
    Value.VBuiltin
      ( "lw-mutate-continuation",
        fun _ ->
          continuation_cell := marked;
          Ok Value.unit_v )
  in
  let continuation =
    [
      Value.FLet
        {
          binder = Kernel.{ it = PWild; meta = Meta.empty };
          body = Kernel.{ it = Var "guarded-cell"; meta = Meta.empty };
          scope = continuation_scope;
        };
      Value.FLet
        {
          binder = Kernel.{ it = PWild; meta = Meta.empty };
          body =
            Kernel.{ it = App ({ it = Var "following"; meta = Meta.empty }, []); meta = Meta.empty };
          scope = following_scope;
        };
    ]
  in
  let factory_calls = ref 0 in
  let model () =
    incr factory_calls;
    Eval.SApply (mutator, Value.FAppFn { args = []; scope = Value.empty_scope } :: continuation)
  in
  (match Infer_dist.likelihood_weighting ctx ~seed:17 ~samples:5 model with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "LW mutation diagnostic" "E0902" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check bool)
        "LW mutation preserves E1202" true
        (String.starts_with ~prefix:"type error: E1202:" (Diag.cause diagnostic))
  | Error diagnostics -> Eval_support.fail_diags "LW continuation mutation" diagnostics
  | Ok _ -> Alcotest.fail "LW accepted a continuation mutation containing a recovery marker");
  Alcotest.(check int) "LW model factory called once" 1 !factory_calls;
  Alcotest.(check int) "LW following action count" 0 !following_calls

let test_lw_samples_restore_mutable_runtime_graph () =
  let harness = Eval_support.make () in
  let ctx = harness.Eval_support.ctx in
  let cell = ref Value.unit_v in
  let scope =
    Value.
      {
        empty_scope with
        env = empty_scope.env |> Env.add "sample-cell" cell |> Env.add "sample-alias" cell;
      }
  in
  let closure =
    Value.VClosure
      { scope; params = []; body = Kernel.{ it = Var "sample-cell"; meta = Meta.empty } }
  in
  cell := closure;
  let sample_calls = ref 0 in
  let mutator =
    Value.VBuiltin
      ( "check-and-mutate-sample-cycle",
        function
        | [ Value.VClosure { scope; _ } ] -> (
            match
              ( Value.Env.find_opt "sample-cell" scope.env,
                Value.Env.find_opt "sample-alias" scope.env )
            with
            | Some primary, Some alias
              when primary == alias && !primary == closure && !alias == closure ->
                incr sample_calls;
                primary := Value.VInt !sample_calls;
                Ok (Value.VInt 1)
            | Some primary, Some alias ->
                Error
                  (Runtime_err.Type_error
                     (Printf.sprintf "broken restored graph: alias=%b cycle=%b" (primary == alias)
                        (!primary == closure && !alias == closure)))
            | None, _ | _, None -> Error (Runtime_err.Unresolved "sample-cell/sample-alias"))
        | args ->
            Error
              (Runtime_err.Arity
                 (Printf.sprintf "check-and-mutate-sample-cycle expects one closure, got %d"
                    (List.length args))) )
  in
  let factory_calls = ref 0 in
  let model () =
    incr factory_calls;
    Eval.SApply
      ( closure,
        [ Value.FAppArgs { fn = mutator; done_rev = []; pending = []; scope = Value.empty_scope } ]
      )
  in
  match Infer_dist.likelihood_weighting ctx ~seed:23 ~samples:5 model with
  | Error diagnostics -> Eval_support.fail_diags "independent LW samples" diagnostics
  | Ok posterior ->
      Alcotest.(check int) "model factory called exactly once" 1 !factory_calls;
      Alcotest.(check int) "all likelihood samples ran" 5 !sample_calls;
      Alcotest.(check string)
        "every sample starts from the validated cyclic alias graph" "1.000000  1"
        (Infer_dist.show_posterior posterior)

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
      | Ok sigs -> Check.register_builtin_signatures cctx sigs
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
                  | Error [ d ] -> Alcotest.(check string) "code" "E0815" (Diag.code_or_uncoded d)
                  | Error _ -> Alcotest.fail "expected one diagnostic"))))

let suite =
  [
    Alcotest.test_case "pmf builtin" `Quick test_pmf;
    Alcotest.test_case "two coins exact (2/3, 1/3)" `Quick test_two_coins_exact;
    Alcotest.test_case "two coins: exactly 4 branches" `Quick test_two_coins_branch_count;
    Alcotest.test_case "sprinkler exact (5/13)" `Quick test_sprinkler_exact;
    Alcotest.test_case "impossible observation" `Quick test_impossible_observation;
    Alcotest.test_case "exact risk merges duplicate leaves and observation support" `Quick
      test_exact_risk_duplicate_leaves_and_observation;
    Alcotest.test_case "exact risk enforces a positive terminal branch budget" `Quick
      test_exact_risk_branch_budget;
    Alcotest.test_case "exact risk rejects malformed categorical weights" `Quick
      test_exact_risk_rejects_malformed_categorical_weights;
    Alcotest.test_case "exact risk rejects opaque observation values" `Quick
      test_exact_risk_rejects_opaque_observation_values;
    Alcotest.test_case "exact risk rejects wrong results, effects, and runtime failures" `Quick
      test_exact_risk_rejects_wrong_result_unexpected_effect_and_runtime_failure;
    Alcotest.test_case "exact risk records underflowed theoretical support" `Quick
      test_exact_risk_preserves_underflowed_positive_support;
    Alcotest.test_case "lw two coins within 0.01" `Slow test_lw_two_coins;
    Alcotest.test_case "lw sprinkler within 0.01" `Slow test_lw_sprinkler;
    Alcotest.test_case "lw seed determinism" `Quick test_lw_determinism;
    Alcotest.test_case "lw validates one reusable initial state" `Quick
      test_lw_validates_one_reusable_initial_state;
    Alcotest.test_case "lw rejects zero-argument continuation mutation" `Quick
      test_lw_rejects_zero_argument_continuation_mutation;
    Alcotest.test_case "lw samples restore mutable runtime graph" `Quick
      test_lw_samples_restore_mutable_runtime_graph;
    Alcotest.test_case "model unchanged between algorithms" `Quick
      test_model_unchanged_between_algorithms;
    Alcotest.test_case "in-language enumeration handler (W4.4)" `Quick test_in_language_enumeration;
    Alcotest.test_case "E0815 blocks effectful top-level bodies in infer" `Quick
      test_effectful_toplevel_blocked_in_infer;
  ]
