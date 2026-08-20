let () =
  Alcotest.run "jacquard-host-protocol-codec"
    [ ("host-protocol-codec", Test_host_protocol_codec.suite) ]
