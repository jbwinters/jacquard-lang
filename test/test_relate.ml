open Jacquard

let test_schedule_seed_law () =
  let expected =
    [
      42;
      4_456_085_495_900_499_605;
      2_949_826_092_126_892_291;
      -4_084_088_288_392_011_950;
      -2_874_173_976_596_520_044;
      701_532_786_141_963_250;
      -2_430_762_948_046_562_554;
      4_028_864_712_777_624_925;
    ]
  in
  let first = Relate.schedule_seeds ~root_seed:42 ~count:8 in
  let second = Relate.schedule_seeds ~root_seed:42 ~count:8 in
  Alcotest.(check (list int)) "exact SplitMix64 vector" expected first;
  Alcotest.(check (list int)) "repeated derivation is identical" first second;
  Alcotest.(check int) "requested cardinality" 8 (List.length first);
  Alcotest.(check int) "pairwise uniqueness" 8 (List.length (List.sort_uniq Int.compare first));
  Alcotest.(check (list int))
    "zero count is empty" []
    (Relate.schedule_seeds ~root_seed:42 ~count:0);
  Alcotest.(check (list int))
    "negative count is empty" []
    (Relate.schedule_seeds ~root_seed:42 ~count:(-1))

let suite = [ Alcotest.test_case "schedule seed vector and laws" `Quick test_schedule_seed_law ]
