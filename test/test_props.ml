open Jacquard

(* W6.4 (sampling + choice-log shrinking), W6.5 (exhaustive), W6.9 (probabilistic
   assertions): the drivers against hand-enumerated ground truth. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)
let thunk_of src = eval_ok src

(* the doc's example: reverse-is-identity, mutated to compare against take 3 *)
let rev_broken =
  "(lam ()\n\
  \  (app (var prop.for)\n\
  \    (lam () (app (var gen.list) (lam () (app (var sample) (app (var uniform-int) (lit 0) (lit \
   9)))) (lit 8)))\n\
  \    (lam ((pvar xs))\n\
  \      (app (var check.eq)\n\
  \        (app (var list.reverse) (app (var list.reverse) (var xs)))\n\
  \        (app (var list.take) (var xs) (lit 3))\n\
  \        (app (var eq.for-list) (var int.eq))\n\
  \        (app (var show.for-list) (var int.show))\n\
  \        (lit \"rev roundtrip\")))))"

let run_sampling ?(seed = 42) ?(samples = 60) src =
  match Warp.run_prop_sampling ctx ~seed ~samples (thunk_of src) with
  | Ok r -> r
  | Error e -> Alcotest.failf "driver error: %s" e

(* the minimal counterexample, golden-pinned with its seed: the SHORTEST list where
   take 3 diverges is length 4, with all-zero elements — 5 choices [4;0;0;0;0] *)
let test_shrinks_to_documented_minimum () =
  let verdict, note = run_sampling rev_broken in
  Alcotest.(check bool) "falsified" true (Warp.is_fail verdict);
  Alcotest.(check bool)
    ("shrunk note: " ^ note) true
    (String.length note > 0
    && String.sub note (String.length note - 12) 12 = "[4;0;0;0;0]\n" = false
    &&
    let re = "[4;0;0;0;0]" in
    let rec has i =
      i + String.length re <= String.length note
      && (String.sub note i (String.length re) = re || has (i + 1))
    in
    has 0);
  match verdict with
  | Warp.Fail { soft = [ msg ]; _ } ->
      Alcotest.(check string)
        "minimal case rendered" "rev roundtrip: expected [0, 0, 0], got [0, 0, 0, 0]" msg
  | _ -> Alcotest.fail "expected one soft failure"

(* determinism: same seed, identical minimal case and report *)
let test_seeded_determinism () =
  let v1, n1 = run_sampling rev_broken in
  let v2, n2 = run_sampling rev_broken in
  Alcotest.(check bool) "same verdict" true (v1 = v2);
  Alcotest.(check string) "same note" n1 n2

(* Generator validity: every shrink RESULT is generator-reachable — the minimal case
   replays through the generator itself without divergence. Candidates that break
   positional alignment are skipped (counted as diverged), never misreported; whether
   any arise is seed-dependent, so the assertion is on the minimal, not the count. *)
let test_generator_validity_theorem () =
  let battery =
    [
      rev_broken;
      (* fails on any list of length >= 1 *)
      "(lam () (app (var prop.for) (lam () (app (var gen.list) (lam () (app (var sample) (app (var \
       uniform-int) (lit 0) (lit 4)))) (lit 6))) (lam ((pvar xs)) (app (var check.true) (app (var \
       list.empty?) (var xs)) (lit \"empty\")))))";
      (* fails when a sampled pair is unequal *)
      "(lam () (let nonrec (pvar p) (app (var gen.pair) (lam () (app (var sample) (app (var \
       uniform-int) (lit 0) (lit 3)))) (lam () (app (var sample) (app (var uniform-int) (lit 0) \
       (lit 3))))) (match (var p) (clause (ptuple (pvar a) (pvar b)) (app (var check.true) (app \
       (var eq) (var a) (var b)) (lit \"equal pair\"))))))";
      (* fails when an option is some *)
      "(lam () (app (var check.fails) (lam () (app (var option.get!) (app (var gen.option) (lam () \
       (app (var sample) (app (var uniform-int) (lit 0) (lit 5))))))) (lit \"gets abort\")))";
    ]
  in
  List.iter
    (fun src ->
      let thunk = thunk_of src in
      let master = Infer_dist.Rng.make 11 in
      (* find a failing run, then shrink and assert zero divergence *)
      let rec find i =
        if i > 200 then None
        else
          let rng = Infer_dist.Rng.split master in
          match Warp.drive_prop ctx ~rng ~forced:[] thunk with
          | Ok run when Warp.is_fail run.Warp.pr_verdict -> Some (rng, run)
          | Ok _ -> find (i + 1)
          | Error _ -> Alcotest.fail "unforced drive cannot fail"
      in
      match find 0 with
      | None -> Alcotest.fail "battery property never failed"
      | Some (rng, run) -> (
          let minimal, _diverged = Warp.shrink ctx ~rng thunk run in
          (* the minimal case is a real generator output: forcing its full log
             replays without divergence and still fails *)
          let forced = List.map (fun c -> c.Warp.c_index) minimal.Warp.pr_log in
          match Warp.drive_prop ctx ~rng ~forced thunk with
          | Ok replayed ->
              Alcotest.(check bool)
                "minimal replays to the same failure" true
                (Warp.is_fail replayed.Warp.pr_verdict);
              Alcotest.(check bool)
                "replay consumed the whole log" true
                (List.length replayed.Warp.pr_log >= List.length minimal.Warp.pr_log)
          | Error `Diverged -> Alcotest.fail "the minimal case diverged: not generator-reachable"
          | Error (`Runtime e) -> Alcotest.fail e))
    battery

(* W6.5: closed-form case count — two coins = 4 branches, verified exactly *)
let test_exhaustive_closed_form () =
  let two_coins =
    "(lam () (let nonrec (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5))) (let nonrec \
     (pvar b) (app (var sample) (app (var bernoulli) (lit 0.5))) (app (var check.true) (app (var \
     bool.or) (var a) (app (var bool.not) (var a))) (lit \"t\")))))"
  in
  match Warp.run_prop_exhaustive ctx ~budget:1000 (thunk_of two_coins) with
  | Ok (Warp.Pass n, note) ->
      Alcotest.(check int) "2*2 branches" 4 n;
      Alcotest.(check string) "note" "verified exhaustively (4 cases)" note
  | r ->
      Alcotest.failf "expected a proof, got %s"
        (match r with Ok (_, note) -> note | Error d -> Diag.to_string d)

(* zero-weight branches prune WITHOUT counting as verified *)
let test_exhaustive_pruning_not_counted () =
  let conditioned =
    "(lam () (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5))) (let nonrec \
     (pwild) (app (var observe) (app (var bernoulli) (match (var c) (clause (pcon true) (lit 1.0)) \
     (clause (pcon false) (lit 0.0)))) (var true)) (app (var check.true) (var c) (lit \
     \"conditioned true\")))))"
  in
  match Warp.run_prop_exhaustive ctx ~budget:1000 (thunk_of conditioned) with
  | Ok (Warp.Pass n, _) -> Alcotest.(check int) "only the weight>0 branch verifies" 1 n
  | r ->
      Alcotest.failf "expected 1-case proof, got %s"
        (match r with Ok (_, note) -> note | Error d -> Diag.to_string d)

(* the budget refusal is the catalogued diagnostic, not a partial pass *)
let test_budget_refusal_is_clean () =
  let huge =
    "(lam () (let nonrec (pvar x) (app (var sample) (app (var uniform-int) (lit 0) (lit 999))) \
     (app (var check.true) (var true) (lit \"t\"))))"
  in
  match Warp.run_prop_exhaustive ctx ~budget:50 (thunk_of huge) with
  | Error d ->
      let s = Diag.to_string d in
      Alcotest.(check bool)
        ("names the code: " ^ s) true
        (let re = "E0905" in
         let rec has i =
           i + String.length re <= String.length s
           && (String.sub s i (String.length re) = re || has (i + 1))
         in
         has 0)
  | Ok (_, note) -> Alcotest.failf "must refuse, got %s" note

(* --- W6.9 --- *)

(* the doc's sampler-ok example: two-coins vs its hand-optimized reformulation *)
let two_coins_model =
  "(lam () (let nonrec (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5))) (let nonrec \
   (pvar b) (app (var sample) (app (var bernoulli) (lit 0.5))) (match (tuple (var a) (var b)) \
   (clause (ptuple (pcon true) (pcon true)) (lit 2)) (clause (ptuple (pcon false) (pcon false)) \
   (lit 0)) (clause (pwild) (lit 1))))))"

let optimized_model =
  "(lam () (app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (lit 0) \
   (lit 0.25)) (app (var cons) (app (var mk-pair) (lit 1) (lit 0.5)) (app (var cons) (app (var \
   mk-pair) (lit 2) (lit 0.25)) (var nil)))))))"

let test_same_dist_accepts_equivalent () =
  Alcotest.(check string)
    "all pointwise checks pass"
    "mk-report(cons((\"same-dist: P(2) = 0.25, expected 0.25\", true), cons((\"same-dist: P(1) = \
     0.5, expected 0.5\", true), cons((\"same-dist: P(0) = 0.25, expected 0.25\", true), nil))), \
     none)"
    (show
       (Printf.sprintf
          "(app (var test.run) (lam () (app (var check.same-dist) %s %s (var int.eq) (var \
           int.show) (lit 0.000000001))))"
          two_coins_model optimized_model))

(* union-support semantics: an outcome present in one model and absent from the other
   compares against zero — and the diff renders through Show *)
let test_same_dist_union_support () =
  let missing_two =
    "(lam () (app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (lit 0) \
     (lit 0.5)) (app (var cons) (app (var mk-pair) (lit 1) (lit 0.5)) (var nil))))))"
  in
  match
    eval_ok
      (Printf.sprintf
         "(app (var test.run) (lam () (app (var check.same-dist) %s %s (var int.eq) (var int.show) \
          (lit 0.01))))"
         two_coins_model missing_two)
  with
  | Value.VCon { name = "mk-report"; args = [ entries; _ ]; _ } ->
      let rec labels = function
        | Value.VCon
            {
              name = "cons";
              args = [ Value.VTuple [ Value.VText l; Value.VCon { name = ok; _ } ]; rest ];
              _;
            } ->
            (l, ok) :: labels rest
        | _ -> []
      in
      let ls = labels entries in
      Alcotest.(check int) "three union outcomes" 3 (List.length ls);
      (* P(2): model has 0.25, the other has NOTHING -> compared against zero, fails *)
      Alcotest.(check bool)
        "the missing outcome fails against zero" true
        (List.exists (fun (l, ok) -> ok = "false" && l = "same-dist: P(2) = 0.25, expected 0.0") ls)
  | v -> Alcotest.failf "not a report: %s" (Value.show v)

(* the sampled variant is deterministic and NAMES its seed and count in the label *)
let test_posterior_sampled_deterministic () =
  let src =
    Printf.sprintf
      "(app (var test.run) (lam () (app (var check.posterior-sampled) %s (app (var cons) (app (var \
       mk-pair) (lit 1) (lit 0.5)) (app (var cons) (app (var mk-pair) (lit 0) (lit 0.25)) (app \
       (var cons) (app (var mk-pair) (lit 2) (lit 0.25)) (var nil)))) (var int.eq) (var int.show) \
       (lit 0.05) (lit 3000) (lit 11))))"
      two_coins_model
  in
  let a = show src and b = show src in
  Alcotest.(check string) "deterministic" a b;
  let has needle s =
    let nl = String.length needle and hl = String.length s in
    let rec go i = i + nl <= hl && (String.sub s i nl = needle || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "seed and count in the label" true (has "posterior[samples=3000,seed=11]" a);
  Alcotest.(check bool) "all within tolerance" true (not (has "false" a))

(* the flagship refactoring test with NAMED (stored) models: their rows are closed,
   so the documented eta-expansion at the use site is load-bearing — pinned here *)
let test_same_dist_with_stored_models () =
  ignore
    (Eval_support.put_src store (Store.names_view store)
       (Printf.sprintf "(defterm ((binding demo.two-coins () %s)))" two_coins_model));
  ignore
    (Eval_support.put_src store (Store.names_view store)
       (Printf.sprintf "(defterm ((binding demo.two-coins-fast () %s)))" optimized_model));
  let via_eta =
    "(app (var test.run) (lam () (app (var check.same-dist) (lam () (app (var demo.two-coins))) \
     (lam () (app (var demo.two-coins-fast))) (var int.eq) (var int.show) (lit 0.000000001))))"
  in
  let r = show via_eta in
  Alcotest.(check bool)
    ("eta-expanded stored models pass: " ^ r)
    true
    (let has needle s =
       let nl = String.length needle and hl = String.length s in
       let rec go i = i + nl <= hl && (String.sub s i nl = needle || go (i + 1)) in
       go 0
     in
     has "none)" r && not (has "false)" r))

let suite =
  [
    Alcotest.test_case "shrinks to the documented minimum" `Quick test_shrinks_to_documented_minimum;
    Alcotest.test_case "seeded determinism" `Quick test_seeded_determinism;
    Alcotest.test_case "generator validity: the minimal case replays" `Quick
      test_generator_validity_theorem;
    Alcotest.test_case "exhaustive: closed-form case count" `Quick test_exhaustive_closed_form;
    Alcotest.test_case "exhaustive: pruned branches not counted" `Quick
      test_exhaustive_pruning_not_counted;
    Alcotest.test_case "budget refusal is the catalogued diagnostic" `Quick
      test_budget_refusal_is_clean;
    Alcotest.test_case "same-dist accepts an equivalent model" `Quick
      test_same_dist_accepts_equivalent;
    Alcotest.test_case "same-dist union-support semantics" `Quick test_same_dist_union_support;
    Alcotest.test_case "same-dist with stored models (eta-expanded)" `Quick
      test_same_dist_with_stored_models;
    Alcotest.test_case "posterior-sampled: deterministic, seed named" `Quick
      test_posterior_sampled_deterministic;
  ]
