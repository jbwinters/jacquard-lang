let () =
  Alcotest.run "jacquard-host-invoke-preflight"
    [ ("host-invoke-preflight", Test_host_invoke_preflight.suite) ]
