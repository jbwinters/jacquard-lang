let test_version_is_nonempty () =
  Alcotest.(check bool) "version is non-empty" true (String.length Jacquard.Version.version > 0)

let () =
  Alcotest.run "jacquard"
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
      ("types", Test_types.suite);
      ("check", Test_check.suite);
      ("tier", Test_tier.suite);
      ("exhaust", Test_exhaust.suite);
      ("fmt", Test_fmt.suite);
      ("diags", Test_diags.suite);
      ("diff", Test_diff.suite);
      ("infer", Test_infer.suite);
      ("gauntlet-handlers", Test_gauntlet_handlers.suite);
      ("gauntlet-hashing", Test_gauntlet_hashing.suite);
      ("gauntlet-dist", Test_gauntlet_dist.suite);
      ("errors-doc", Test_errors_doc.suite);
      ("names", Test_names.suite);
      ("stdlib", Test_stdlib.suite);
      ("text", Test_text.suite);
      ("map", Test_map.suite);
      ("dist-lib", Test_dist_lib.suite);
      ("world", Test_world.suite);
      ("rings", Test_rings.suite);
      ("warp", Test_warp.suite);
      ("props", Test_props.suite);
      ("replay", Test_replay.suite);
    ]
