open Jacquard

(* Composition of several source units (the project format's composition parse mode): the composed
   program must be exactly the concatenated program, with each item keeping its own file. *)

let fail_diags label ds =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string ds))

let lower label tops =
  match Surface_lower.lower_tops tops with Ok tops -> tops | Error ds -> fail_diags label ds

let forms tops =
  List.map
    (function Kernel.Decl d -> Kernel.decl_to_form d | Kernel.Expr e -> Kernel.expr_to_form e)
    tops

let same_program label units =
  let composed =
    match Surface_parse.compose_units units with
    | Ok tops -> lower "composed" tops
    | Error ds -> fail_diags "compose" ds
  in
  let concatenated =
    match Surface_parse.parse_string ~file:"cat.jac" (String.concat "\n" (List.map snd units)) with
    | Ok tops -> lower "concatenated" tops
    | Error ds -> fail_diags "concatenate" ds
  in
  Alcotest.(check int)
    (label ^ ": same number of tops") (List.length concatenated) (List.length composed);
  List.iter2
    (fun a b -> Alcotest.(check bool) (label ^ ": same kernel") true (Form.equal_ignoring_meta a b))
    (forms concatenated) (forms composed)

let codes = function Ok _ -> [] | Error ds -> List.map Diag.code_or_uncoded ds

let test_signature_across_units () =
  same_program "signature then definition"
    [ ("sig.jac", "a.f : () ->{} Int\n"); ("def.jac", "a.f() = 1\n") ]

let test_comment_only_units_are_transparent () =
  same_program "signature, comment-only unit, definition"
    [
      ("sig.jac", "a.f : () ->{} Int\n");
      ("notes.jac", "-- only a comment\n");
      ("empty.jac", "");
      ("def.jac", "a.f() = 1\n");
    ]

let test_split_expressions_are_refused () =
  Alcotest.(check bool)
    "an expression continued in the next unit is refused" true
    (Result.is_error
       (Surface_parse.compose_units [ ("a.jac", "a.x = int.add(1,\n"); ("b.jac", "2)\n") ]))

let test_recursion_across_units () =
  same_program "mutual recursion"
    [
      ("even.jac", "a.even?(n) = if int.lte?(n, 0) then True else a.odd?(int.sub(n, 1))\n");
      ("odd.jac", "a.odd?(n) = if int.lte?(n, 0) then False else a.even?(int.sub(n, 1))\n");
    ]

let test_items_keep_their_files () =
  match Surface_parse.compose_units [ ("one.jac", "a.x = 1\n"); ("two.jac", "a.y = 2\n") ] with
  | Error ds -> fail_diags "compose" ds
  | Ok tops ->
      Alcotest.(check (list string))
        "files" [ "one.jac"; "two.jac" ]
        (List.map
           (fun (top : Surface_ast.top) ->
             match Meta.span top.meta with Some span -> span.Span.file | None -> "?")
           tops)

let test_detached_signatures () =
  Alcotest.(check (list string))
    "signature ending the last unit" [ "E1224" ]
    (codes
       (Surface_parse.compose_units [ ("a.jac", "a.x = 1\n"); ("b.jac", "a.f : () ->{} Int\n") ]));
  Alcotest.(check (list string))
    "signature followed by another definition" [ "E1224" ]
    (codes
       (Surface_parse.compose_units [ ("a.jac", "a.f : () ->{} Int\n"); ("b.jac", "a.g() = 1\n") ]));
  match Surface_parse.compose_units [ ("good.jac", "a.x = 1\n"); ("bad.jac", "a.y = (\n") ] with
  | Ok _ -> Alcotest.fail "a damaged unit must fail"
  | Error ds ->
      Alcotest.(check bool)
        "diagnostics name the damaged unit" true
        (List.for_all
           (fun d -> match Diag.span d with Some s -> s.Span.file = "bad.jac" | None -> true)
           ds)

let test_cross_file_span_merge () =
  let pos n = { Span.line = 1; col = n; offset = n } in
  let a = Span.make ~file:"a.jac" ~start_pos:(pos 5) ~end_pos:(pos 9) in
  let b = Span.make ~file:"b.jac" ~start_pos:(pos 1) ~end_pos:(pos 40) in
  Alcotest.(check bool) "different files keep the first origin" true (Span.equal (Span.merge a b) a);
  let c = Span.make ~file:"a.jac" ~start_pos:(pos 1) ~end_pos:(pos 12) in
  Alcotest.(check (pair int int))
    "one file still merges" (1, 12)
    (let m = Span.merge a c in
     (m.Span.start_pos.offset, m.Span.end_pos.offset))

let suite =
  [
    Alcotest.test_case "a signature may precede its definition across units" `Quick
      test_signature_across_units;
    Alcotest.test_case "comment-only and empty units are transparent" `Quick
      test_comment_only_units_are_transparent;
    Alcotest.test_case "an expression split across units is refused" `Quick
      test_split_expressions_are_refused;
    Alcotest.test_case "recursive groups span units as in concatenation" `Quick
      test_recursion_across_units;
    Alcotest.test_case "composed items keep their own files" `Quick test_items_keep_their_files;
    Alcotest.test_case "detached signatures and damaged units are refused" `Quick
      test_detached_signatures;
    Alcotest.test_case "spans from different files are never merged" `Quick
      test_cross_file_span_merge;
  ]
