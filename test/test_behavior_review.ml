open Jacquard
module R = Behavior_review

let con name args =
  Observation.Constructor { identity = Hash.of_string name; name; arguments = args }

let test_decode_first_parameter_outermost () =
  Alcotest.(check (list (list int)))
    "2 x 3 product order"
    [ [ 0; 0 ]; [ 0; 1 ]; [ 0; 2 ]; [ 1; 0 ]; [ 1; 1 ]; [ 1; 2 ] ]
    (List.init 6 (R.decode [ 2; 3 ]));
  Alcotest.(check (list int)) "single domain" [ 4 ] (R.decode [ 7 ] 4)

(* atoms of a case: priority constructor plus availability fields *)
let case_atoms priority avail =
  R.value_atoms "arg0" (con priority [])
  @ R.value_atoms "arg1" (con "availability" (List.map (fun s -> con s []) avail))

let test_grouping_exact_conjunctions () =
  let cases =
    [
      (0, "high", [ "up"; "down" ]);
      (1, "low", [ "up"; "down" ]);
      (2, "low", [ "down"; "down" ]);
      (3, "high", [ "down"; "down" ]);
    ]
  in
  let atoms_of n =
    match List.find (fun (i, _, _) -> i = n) cases with _, p, a -> case_atoms p a
  in
  (* only case 1 differs: its shared atoms reduce to a condition no agreeing case satisfies *)
  let verdicts = [ (0, R.Agree); (1, R.Differ R.Decision); (2, R.Agree); (3, R.Agree) ] in
  (match R.groups ~atoms_of ~verdicts with
  | [ { R.condition = `Atoms atoms; members = [ 1 ]; _ } ] ->
      Alcotest.(check bool)
        "condition excludes every agreeing case" true
        (List.for_all
           (fun c -> not (List.for_all (fun a -> List.mem a (atoms_of c)) atoms))
           [ 0; 2; 3 ]);
      Alcotest.(check bool)
        "condition holds for the member" true
        (List.for_all (fun a -> List.mem a (atoms_of 1)) atoms)
  | _ -> Alcotest.fail "expected one atom-conditioned group");
  (* cases 1 and 3 share no atom that excludes the agreeing cases 0 and 2: ungrouped *)
  let verdicts =
    [ (0, R.Agree); (1, R.Differ R.Decision); (2, R.Agree); (3, R.Differ R.Decision) ]
  in
  (match R.groups ~atoms_of ~verdicts with
  | [ { R.condition = `Ungrouped; members = [ 1; 3 ]; _ } ] -> ()
  | _ -> Alcotest.fail "expected an ungrouped group");
  (* nothing agrees: the empty conjunction, distinct from ungrouped *)
  let verdicts = List.map (fun (i, _, _) -> (i, R.Differ R.Effect)) cases in
  match R.groups ~atoms_of ~verdicts with
  | [ { R.condition = `All; group_kind = R.Effect; _ } ] -> ()
  | _ -> Alcotest.fail "expected condition=all"

let element data w = { R.value = Value.VInt 0; observed = Observation.Int 0; data; weight = Some w }

let test_support_merges_and_drops_zero () =
  let merged =
    R.merge_support [ element "a" 0.25; element "b" 0.; element "a" 0.25; element "c" 0.5 ]
  in
  Alcotest.(check (list (pair string (float 1e-12))))
    "first-position merge, zero weight dropped"
    [ ("a", 0.5); ("c", 0.5) ]
    (List.map (fun e -> (e.R.data, Option.get e.R.weight)) merged)

let test_sampling_is_seeded () =
  let domain = [ element "x" 0.9; element "y" 0.1 ] in
  let draw seed = R.sample_indices [ domain; domain ] ~count:50 ~seed in
  Alcotest.(check (list (list int))) "same seed, same cases" (draw 7) (draw 7);
  Alcotest.(check bool) "another seed, other cases" true (draw 7 <> draw 8);
  Alcotest.(check bool)
    "draws stay inside the support" true
    (List.for_all (List.for_all (fun i -> i = 0 || i = 1)) (draw 7))

let suite =
  [
    Alcotest.test_case "cases: first parameter outermost" `Quick
      test_decode_first_parameter_outermost;
    Alcotest.test_case "grouping: exact conjunctions" `Quick test_grouping_exact_conjunctions;
    Alcotest.test_case "domains: support merge" `Quick test_support_merges_and_drops_zero;
    Alcotest.test_case "sampling: seeded streams" `Quick test_sampling_is_seeded;
  ]
