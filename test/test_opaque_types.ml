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
  (* Only `top_item_ahead` stops an empty constructor list at the marker. *)
  let stopped =
    Surface_parse.recover_string ~file:"opaque.jac" "type Side =\nopaque type Coin = | Heads\n"
  in
  Alcotest.(check (list string))
    "an empty constructor list stops at the marker" [ "E1225" ]
    (List.filter_map Diag.code stopped.diagnostics);
  Alcotest.(check bool)
    "and the opaque declaration after it survives" true
    (List.exists
       (fun (top : Surface_ast.top) ->
         match top.it with Surface_ast.TypeDecl { opaque; _ } -> opaque | _ -> false)
       stopped.items);
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

(* --- S2a: single-file sealing, the public projection and setters --- *)

let walk store ?(syntax = Frontend.Surface) source =
  Frontend.walk ~syntax ~file:"opaque.jac" store source

let codes = function Ok () -> [] | Error ds -> List.filter_map Diag.code ds

let coin_source =
  "opaque type Coin = | Heads | Tails\nflip(c) = match c { | Heads -> Tails | Tails -> Heads }\n"

let test_single_file_seal () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  Alcotest.(check (list string))
    "the declaring source constructs" []
    (codes (walk store coin_source));
  Alcotest.(check (list string))
    "re-running the same source stays in scope" []
    (codes (walk store coin_source));
  Alcotest.(check (list string))
    "another source is refused by name" [ "E0315" ]
    (codes (walk store "forged = Heads\n"));
  Alcotest.(check (list string))
    "and in a pattern" [ "E0315" ]
    (codes (walk store "peek(c) = match c { | Heads -> 1 | _ -> 0 }\n"));
  let heads =
    match Store.lookup_kind store "heads" Resolve.KCon with
    | Some { Resolve.hash; _ } -> Hash.to_hex hash
    | None -> Alcotest.fail "heads is not bound"
  in
  Alcotest.(check (list string))
    "and by explicit identity" [ "E0315" ]
    (codes
       (walk store ~syntax:Frontend.Bootstrap
          (Printf.sprintf "(defterm ((binding forged () (ref #%s con))))\n" heads)));
  Alcotest.(check (list string))
    "a labelled owner" []
    (codes (walk store "opaque type Meter = Meter(reading: Int)\nmeter.make(n) = Meter(n)\n"));
  Alcotest.(check (list string))
    "and a `with` update outside it" [ "E0315" ]
    (codes (walk store "bump(m) = Meter(m with reading: 1)\n"));
  Alcotest.(check (list string))
    "functions the owner provides stay usable" []
    (codes (walk store "again(c) = flip(flip(c))\n"));
  Alcotest.(check (list string))
    "quoted data is not a use" []
    (codes
       (walk store ~syntax:Frontend.Bootstrap
          (Printf.sprintf "(defterm ((binding code () (quote (ref #%s con)))))\n" heads)));
  Alcotest.(check (list string))
    "but a live splice is" [ "E0315" ]
    (codes
       (walk store ~syntax:Frontend.Bootstrap
          (Printf.sprintf "(defterm ((binding code () (quote (unquote (ref #%s con))))))\n" heads)))

let test_projection_and_setters () =
  let tops = surface_tops "opaque type Box = Box(size: Int)\ntype Bag = Bag(size: Int)\n" in
  let names =
    List.concat_map
      (function
        | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } ->
            List.map (fun (b : Kernel.binding) -> b.bname) bindings
        | _ -> [])
      tops
  in
  Alcotest.(check (list string))
    "an opaque type gets accessors but no setters"
    [ "box.size"; "bag.size"; "bag.with-size" ]
    names;
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-opaque-projection-%d" (Unix.getpid ()))
  in
  let interface =
    Fun.protect
      ~finally:(fun () -> ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; root ])))
      (fun () ->
        match
          Frontend.check ~prelude_dir:"../prelude" ~root ~syntax:Frontend.Auto ~file:"opaque.jac"
            coin_source
        with
        | Ok (Frontend.Checked artifact) -> Frontend.Checked.interface artifact
        | Ok (Frontend.Recovered _) -> Alcotest.fail "a strict source produced a recovery report"
        | Error diagnostics -> fail_diags "check" diagnostics)
  in
  let exported kind name =
    List.exists
      (fun (e : Interface.export) -> e.Interface.name = name && e.kind = kind)
      interface.Interface.exports
  in
  Alcotest.(check bool) "the type is public" true (exported Resolve.KType "coin");
  Alcotest.(check bool) "its functions are public" true (exported Resolve.KTerm "flip");
  Alcotest.(check bool) "its constructors are not" false (exported Resolve.KCon "heads");
  Alcotest.(check int) "they are hidden members" 2 (List.length interface.Interface.hidden)

(* TYPE.1 S2c: builtins build frozen prelude identities, so a source that rebinds `true`/`false` to
   its own (opaque) constructors never receives its own values from them *)
let test_frozen_builtin_identities () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let prelude_true =
    match Prelude_identity.lookup_kind store "true" Resolve.KCon with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "no prelude true"
  in
  Alcotest.(check (list string))
    "a file rebinds the boolean constructors" []
    (codes (walk store "opaque type Bool = | False | True\n"));
  (match Store.lookup_kind store "true" Resolve.KCon with
  | Some { Resolve.hash; _ } ->
      Alcotest.(check bool) "the name is rebound" false (Hash.equal hash prelude_true)
  | None -> Alcotest.fail "true is unbound");
  let value =
    match
      Eval_support.eval_with ctx store "(app (var support) (app (var bernoulli) (lit 0.5)))"
    with
    | Ok v -> v
    | Error e -> Alcotest.failf "support failed: %s" (Runtime_err.to_string e)
  in
  let rec booleans (v : Value.t) =
    match v with
    | Value.VCon { con; name = "true" | "false"; _ } -> [ con ]
    | Value.VCon { args; _ } -> List.concat_map booleans args
    | Value.VTuple items -> List.concat_map booleans items
    | _ -> []
  in
  let seen = booleans value in
  Alcotest.(check bool) "support returns booleans" true (seen <> []);
  Alcotest.(check bool)
    "every one is the prelude's" true
    (List.for_all
       (fun con ->
         match Store.locate store con with
         | Ok { Store.decl = { Kernel.it = Kernel.DefType { opaque; _ }; _ }; _ } -> not opaque
         | _ -> false)
       seen)

(* the same holds in a project: a root without a namespace that rebinds the boolean constructors
   still receives prelude booleans from builtins *)
let test_frozen_identities_in_projects () =
  let work =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-opaque-frozen-%d" (Unix.getpid ()))
  in
  let cleanup () = ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; work ])) in
  Fun.protect ~finally:cleanup (fun () ->
      List.iter (fun d -> Unix.mkdir d 0o755) [ work; Filename.concat work ".git" ];
      let write name text =
        Out_channel.with_open_bin (Filename.concat work name) (fun oc ->
            Out_channel.output_string oc text)
      in
      write "project.jqd" "(project-v1 (name \"root\") (requires (core \"0.2\")) (units \"r.jac\"))";
      write "r.jac" "opaque type Bool = | False | True\n";
      let session, _ =
        match
          Project_frontend.open_graph ~prelude_dir:"../prelude" ~root:(Filename.concat work "store")
            (Filename.concat work "project.jqd")
        with
        | Ok s -> s
        | Error ds -> fail_diags "open" ds
      in
      let store = Project_frontend.store session and ctx = Project_frontend.eval_ctx session in
      (match
         ( Store.lookup_kind store "true" Resolve.KCon,
           Prelude_identity.lookup_kind store "true" Resolve.KCon )
       with
      | Some { Resolve.hash = bound; _ }, Some { Resolve.hash = frozen; _ } ->
          Alcotest.(check bool) "the root rebinds the name" false (Hash.equal bound frozen)
      | _ -> Alcotest.fail "true is unbound");
      let value =
        match
          Eval_support.eval_with ctx store "(app (var support) (app (var bernoulli) (lit 0.5)))"
        with
        | Ok v -> v
        | Error e -> Alcotest.failf "support failed: %s" (Runtime_err.to_string e)
      in
      let rec opaque_booleans (v : Value.t) =
        match v with
        | Value.VCon { con; name = "true" | "false"; _ } -> (
            match Store.locate store con with
            | Ok { Store.decl = { Kernel.it = Kernel.DefType { opaque; _ }; _ }; _ } ->
                if opaque then 1 else 0
            | _ -> 0)
        | Value.VCon { args; _ } -> List.fold_left (fun n a -> n + opaque_booleans a) 0 args
        | Value.VTuple items -> List.fold_left (fun n a -> n + opaque_booleans a) 0 items
        | _ -> 0
      in
      Alcotest.(check int) "no root-owned boolean" 0 (opaque_booleans value))

(* the store remembers a confirmed pin only until it hides or removes an object *)
let test_confirmed_pins_follow_the_store () =
  let fresh label =
    let root =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-opaque-visible-%s-%d" label (Unix.getpid ()))
    in
    at_exit (fun () -> ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; root ])));
    match Store.open_store root with Ok s -> s | Error ds -> fail_diags "open" ds
  in
  let bool_decl = kernel_decl "(deftype bool () (con false) (con true))" in
  let pinned_true store = Prelude_identity.lookup_kind store "true" Resolve.KCon in
  (* a transaction installs the prelude's bool, a lookup confirms its pin, and the rollback removes it *)
  let store = fresh "rollback" in
  let result =
    Store.transaction store (fun () ->
        ignore (Store.put_decl store bool_decl);
        Alcotest.(check bool) "confirmed inside" true (Option.is_some (pinned_true store));
        Error ())
  in
  Alcotest.(check bool) "the transaction rolled back" true (Result.is_error result);
  Alcotest.(check bool) "the pin is forgotten" true (Option.is_none (pinned_true store));
  (* a confirmed member that the store then hides is not returned either *)
  let store = fresh "hide" in
  ignore (Store.put_decl store bool_decl);
  let hash =
    match pinned_true store with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "the prelude's true is not pinned"
  in
  Store.hide_derived store hash;
  Alcotest.(check bool) "a hidden pin is not returned" true (Option.is_none (pinned_true store))

(* TYPE.1 S3a: dynamic code constructs or matches no opaque type, the owner's included *)
let test_eval_code_refuses_sealed () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  (match Prelude.install_eval ctx with Ok () -> () | Error ds -> fail_diags "install eval" ds);
  Alcotest.(check (list string)) "the owner declares the type" [] (codes (walk store coin_source));
  let run payload =
    Eval_support.eval_with ctx store (Printf.sprintf "(app (var eval-code) (quote %s))" payload)
  in
  let refused label payload =
    match run payload with
    | Error (Runtime_err.Eval_error message) ->
        Alcotest.(check bool)
          label true
          (let needle = "dynamic code may not construct or match" in
           let n = String.length needle and m = String.length message in
           let rec go i = i + n <= m && (String.sub message i n = needle || go (i + 1)) in
           go 0)
    | Error e -> Alcotest.failf "%s: unexpected %s" label (Runtime_err.to_string e)
    | Ok v -> Alcotest.failf "%s: ran to %s" label (Value.show v)
  in
  refused "constructing" "(var heads)";
  Alcotest.(check (list string))
    "an owner helper supplies a coin" []
    (codes (walk store (coin_source ^ "start() = Heads\n")));
  (* the pattern is the payload's only reference to a sealed constructor *)
  refused "matching"
    "(match (app (var start)) (clause (pcon heads) (lit 1)) (clause (pwild) (lit 0)))";
  refused "a live splice" "(app (lam ((pvar x)) (var x)) (quote (unquote (var heads))))";
  match run "(quote (var heads))" with
  | Ok (Value.VCode _) -> ()
  | Ok v -> Alcotest.failf "quoted data: unexpected %s" (Value.show v)
  | Error e -> Alcotest.failf "quoted data is not a use: %s" (Runtime_err.to_string e)

let suite =
  [
    Alcotest.test_case "kernel marker" `Quick test_kernel_marker;
    Alcotest.test_case "canonical identity" `Quick test_canonical_identity;
    Alcotest.test_case "surface syntax" `Quick test_surface_syntax;
    Alcotest.test_case "parser boundaries" `Quick test_parser_boundaries;
    Alcotest.test_case "printing and formatting" `Quick test_printing;
    Alcotest.test_case "single-file sealing" `Quick test_single_file_seal;
    Alcotest.test_case "public projection and setters" `Quick test_projection_and_setters;
    Alcotest.test_case "frozen builtin identities" `Quick test_frozen_builtin_identities;
    Alcotest.test_case "frozen identities in projects" `Quick test_frozen_identities_in_projects;
    Alcotest.test_case "confirmed pins follow the store" `Quick test_confirmed_pins_follow_the_store;
    Alcotest.test_case "eval-code refuses sealed constructors" `Quick test_eval_code_refuses_sealed;
  ]
