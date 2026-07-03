let test_version_is_nonempty () =
  Alcotest.(check bool) "version is non-empty" true (String.length Weft.Version.version > 0)

let () =
  Alcotest.run "weft"
    [
      ("version", [ Alcotest.test_case "non-empty" `Quick test_version_is_nonempty ]);
      ("diag", Test_diag.suite);
    ]
