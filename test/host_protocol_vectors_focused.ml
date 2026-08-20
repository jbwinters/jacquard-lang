let () = Alcotest.run "host-protocol-v0" [ ("vectors", Test_host_protocol_vectors.suite) ]
