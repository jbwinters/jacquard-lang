let () =
  Alcotest.run "jacquard-scoped-instances"
    [ ("scoped-instances", Test_scoped_instances_model.suite) ]
