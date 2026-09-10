let () = Alcotest.run "jacquard-host-worker" [ ("host-worker", Test_host_worker.suite) ]
