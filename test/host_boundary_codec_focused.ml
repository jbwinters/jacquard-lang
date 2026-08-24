let () =
  Alcotest.run "jacquard-host-boundary-codec"
    [ ("host-boundary-codec", Test_host_boundary_codec.suite) ]
