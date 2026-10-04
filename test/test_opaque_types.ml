open Jacquard

(* TYPE.1 S1: the `opaque` marker in the kernel form, the canonical encoding and the surface
   syntax. Sealing is enforced by later slices; these tests pin representation only. *)

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let kernel_decl source =
  match Reader.parse_one ~file:"opaque.jqd" source with
  | Error diagnostics -> fail_diags "kernel parse" diagnostics
  | Ok form -> (
      match Kernel.decl_of_form form with
      | Ok decl -> decl
      | Error diagnostics -> fail_diags "kernel validate" diagnostics)

let kernel_error_codes source =
  match Reader.parse_one ~file:"opaque.jqd" source with
  | Error diagnostics -> fail_diags "kernel parse" diagnostics
  | Ok form -> (
      match Kernel.decl_of_form form with
      | Ok _ -> Alcotest.failf "expected validation to fail:\n%s" source
      | Error diagnostics -> List.filter_map Diag.code diagnostics)

let decl_hash label decl =
  match Canon.hash_decl decl with
  | Ok hashes -> Hash.to_hex hashes.Canon.decl_hash
  | Error diagnostics -> fail_diags label diagnostics

let opacity (decl : Kernel.decl) =
  match decl.it with
  | Kernel.DefType { opaque; _ } -> opaque
  | _ -> Alcotest.fail "expected a type declaration"

let opaque_coin = "(deftype coin () (opaque) (con heads) (con tails))"
let transparent_coin = "(deftype coin () (con heads) (con tails))"

let test_kernel_marker () =
  let opaque = kernel_decl opaque_coin and transparent = kernel_decl transparent_coin in
  Alcotest.(check bool) "marker read" true (opacity opaque);
  Alcotest.(check bool) "no marker" false (opacity transparent);
  let round_trip decl =
    match Kernel.decl_of_form (Kernel.decl_to_form decl) with
    | Ok decl -> decl
    | Error diagnostics -> fail_diags "round trip" diagnostics
  in
  Alcotest.(check bool) "marker survives printing" true (opacity (round_trip opaque));
  Alcotest.(check bool) "no marker is printed" false (opacity (round_trip transparent));
  Alcotest.(check (list string))
    "marker takes no arguments" [ "E0202" ]
    (kernel_error_codes "(deftype coin () (opaque heads) (con heads))");
  Alcotest.(check (list string))
    "marker needs a constructor" [ "E0202" ]
    (kernel_error_codes "(deftype coin () (opaque))");
  (* An older reader sees the marker as a malformed constructor spec; so does a misplaced one. *)
  Alcotest.(check (list string))
    "misplaced marker" [ "E0201" ]
    (kernel_error_codes "(deftype coin () (con heads) (opaque))")

let test_canonical_identity () =
  let opaque = decl_hash "opaque" (kernel_decl opaque_coin)
  and transparent = decl_hash "transparent" (kernel_decl transparent_coin) in
  Alcotest.(check bool) "opacity is part of the identity" false (String.equal opaque transparent);
  (* A golden pins the 0x47 encoding; the transparent twin is pinned by the corpus goldens. *)
  Alcotest.(check string)
    "opaque identity golden" "574eaa5584672a44918771dc4e6ba4cc4fd1eabcb1b253c04c01b14665974057"
    opaque

let surface_tops source =
  match Surface_parse.parse_string ~file:"opaque.jac" source with
  | Error diagnostics -> fail_diags "surface parse" diagnostics
  | Ok tops -> (
      match Surface_lower.lower_tops tops with
      | Ok tops -> tops
      | Error diagnostics -> fail_diags "surface lower" diagnostics)

let only_type_decl tops =
  match List.filter_map (function Kernel.Decl d -> Some d | Kernel.Expr _ -> None) tops with
  | decl :: _ when match decl.Kernel.it with Kernel.DefType _ -> true | _ -> false -> decl
  | _ -> Alcotest.fail "expected a type declaration first"

let test_surface_syntax () =
  let decl = only_type_decl (surface_tops "opaque type Coin = | Heads | Tails\n") in
  Alcotest.(check bool) "surface marker" true (opacity decl);
  Alcotest.(check string)
    "surface and kernel forms agree"
    (decl_hash "kernel" (kernel_decl opaque_coin))
    (decl_hash "surface" decl);
  Alcotest.(check bool)
    "plain type stays transparent" false
    (opacity (only_type_decl (surface_tops "type Coin = | Heads | Tails\n")));
  (* `opaque` is contextual: elsewhere it is an ordinary name. *)
  let names =
    List.concat_map
      (function
        | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } ->
            List.map (fun (b : Kernel.binding) -> b.bname) bindings
        | _ -> [])
      (surface_tops "opaque = 1\nopaque-twice(x) = opaque\nuse = opaque-twice(opaque)\n")
  in
  Alcotest.(check (list string)) "ordinary names" [ "opaque"; "opaque-twice"; "use" ] names

let top_shapes source =
  List.map
    (function
      | Kernel.Expr _ -> "expr"
      | Kernel.Decl { Kernel.it = Kernel.DefType { opaque = true; _ }; _ } -> "opaque type"
      | Kernel.Decl { Kernel.it = Kernel.DefType _; _ } -> "type"
      | Kernel.Decl { Kernel.it = Kernel.DefTerm _; _ } -> "term"
      | Kernel.Decl { Kernel.it = Kernel.DefEffect _; _ } -> "effect")
    (surface_tops source)

let test_parser_boundaries () =
  let check label expected source =
    Alcotest.(check (list string)) label expected (top_shapes source)
  in
  (* The marker must be directly before `type`; otherwise `opaque` is an ordinary expression. *)
  check "newline separates" [ "expr"; "type" ] "opaque\ntype Coin = | Heads | Tails\n";
  check "comment separates" [ "expr"; "type" ] "opaque -- note\ntype Coin = | Heads | Tails\n";
  check "ends a multi-line definition" [ "term"; "opaque type" ]
    "pick(x) =\n  x\nopaque type Coin = | Heads | Tails\n";
  check "ends a constructor list" [ "type"; "opaque type" ]
    "type Side = | Left | Right\nopaque type Coin = | Heads | Tails\n";
  let recovered =
    Surface_parse.recover_string ~file:"opaque.jac"
      "opaque type = | Heads\nopaque type Coin = | Heads | Tails\n"
  in
  Alcotest.(check bool) "malformed declaration is reported" true (recovered.diagnostics <> []);
  Alcotest.(check bool)
    "the next declaration survives" true
    (List.exists
       (fun (top : Surface_ast.top) ->
         match top.it with
         | Surface_ast.TypeDecl { opaque = true; name = "coin"; _ } -> true
         | _ -> false)
       recovered.items)

let print_surface source =
  match Surface_parse.parse_file ~file:"opaque.jac" source with
  | Error diagnostics -> fail_diags "surface parse" diagnostics
  | Ok file -> (
      match Surface_lower.lower_file file with
      | Error diagnostics -> fail_diags "surface lower" diagnostics
      | Ok lowered -> (
          match Surface_print.print_file_with_trivia ~file_meta:lowered.meta lowered.tops with
          | Ok text -> text
          | Error diagnostics -> fail_diags "surface print" diagnostics))

let test_printing () =
  let canonical source =
    match Surface_print.print_file (surface_tops source) with
    | Ok text -> text
    | Error diagnostics -> fail_diags "canonical print" diagnostics
  in
  Alcotest.(check string)
    "canonical printing" "opaque type Coin = | Heads | Tails\n"
    (canonical "opaque type Coin = | Heads | Tails\n");
  (* The marker counts toward the width: this declaration fits flat only without it. *)
  let narrow source =
    match Surface_print.print_file ~width:30 (surface_tops source) with
    | Ok text -> text
    | Error diagnostics -> fail_diags "narrow print" diagnostics
  in
  Alcotest.(check string)
    "transparent fits" "type Coin = | Heads | Tails\n"
    (narrow "type Coin = | Heads | Tails\n");
  Alcotest.(check string)
    "marker forces lines" "opaque type Coin =\n  | Heads\n  | Tails\n"
    (narrow "opaque type Coin = | Heads | Tails\n");
  (* A header comment is placed exactly as for the transparent twin. *)
  let header = "type Coin = -- the sides\n  | Heads\n  | Tails\n" in
  Alcotest.(check string)
    "header comment"
    ("opaque " ^ print_surface header)
    (print_surface ("opaque " ^ header));
  let source = "-- a coin\nopaque type Coin =\n  | Heads -- one side\n  | Tails\n" in
  Alcotest.(check string) "formatting keeps the marker and comments" source (print_surface source);
  Alcotest.(check string) "formatting is idempotent" source (print_surface (print_surface source))

let suite =
  [
    Alcotest.test_case "kernel marker" `Quick test_kernel_marker;
    Alcotest.test_case "canonical identity" `Quick test_canonical_identity;
    Alcotest.test_case "surface syntax" `Quick test_surface_syntax;
    Alcotest.test_case "parser boundaries" `Quick test_parser_boundaries;
    Alcotest.test_case "printing and formatting" `Quick test_printing;
  ]
