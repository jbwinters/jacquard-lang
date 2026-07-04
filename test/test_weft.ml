let test_version_is_nonempty () =
  Alcotest.(check bool) "version is non-empty" true (String.length Weft.Version.version > 0)

let () =
  Alcotest.run "weft"
    [
      ("version", [ Alcotest.test_case "non-empty" `Quick test_version_is_nonempty ]);
      ("diag", Test_diag.suite);
      ("hash", Test_hash.suite);
      ("form", Test_form.suite);
      ("reader", Test_reader.suite);
      ("printer", Test_printer.suite);
      ("kernel", Test_kernel.suite);
      ("resolve", Test_resolve.suite);
      ("canon", Test_canon.suite);
      ("store", Test_store.suite);
      ("corpus", Test_corpus.suite);
      ("eval", Test_eval.suite);
      ("patmatch", Test_patmatch.suite);
      ("handlers", Test_handlers.suite);
      ("quote", Test_quote.suite);
      ("prelude", Test_prelude.suite);
    ]
