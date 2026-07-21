let () =
  Alcotest.run "jacquard-gm17c" [ ("governance-review-diff", Test_governance_review_diff.suite) ]
