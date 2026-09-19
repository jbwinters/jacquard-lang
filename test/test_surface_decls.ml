open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse source =
  match Surface_parse.parse_string ~file:"decls.jac" source with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower source =
  match Surface_lower.lower_tops (parse source) with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let bootstrap source =
  match Reader.parse_string ~file:"decls.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok forms ->
      List.map
        (fun form ->
          match Kernel.of_form form with
          | Ok top -> top
          | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)
        forms

let resolve names top =
  match Resolve.resolve names top with
  | Ok top -> top
  | Error diagnostics -> fail_diags "resolve" diagnostics

let hash top =
  match Canon.hash_top top with
  | Ok hashes -> hashes.Canon.decl_hash
  | Error diagnostics -> fail_diags "hash" diagnostics

let check_equivalent label ?(names = Resolve.empty_names) surface_source bootstrap_source =
  (* generated D36 accessors have their own kernel-twin test; these twins omit them *)
  let actual =
    lower surface_source
    |> List.filter (function
      | Kernel.Decl declaration ->
          Meta.surface_generated declaration.meta <> Some "constructor-accessor"
      | Kernel.Expr _ -> true)
    |> List.map (resolve names)
  in
  let expected = List.map (resolve names) (bootstrap bootstrap_source) in
  Alcotest.(check int) (label ^ " top count") (List.length expected) (List.length actual);
  List.iter2
    (fun actual expected ->
      Alcotest.(check bool)
        (label ^ " resolved AST") true
        (Form.equal_ignoring_meta (Kernel.to_form expected) (Kernel.to_form actual));
      Alcotest.(check bool) (label ^ " hash") true (Hash.equal (hash expected) (hash actual)))
    actual expected

let only_decl = function
  | [ Kernel.Decl declaration ] -> declaration
  | tops -> Alcotest.failf "expected one declaration, got %d tops" (List.length tops)

let is_generated_accessor = function
  | Kernel.Decl declaration -> Meta.surface_generated declaration.meta = Some "constructor-accessor"
  | Kernel.Expr _ -> false

(* A labeled type lowers to its declaration followed by its generated D36 accessors (SX.27). *)
let declared_type = function
  | Kernel.Decl declaration :: accessors when List.for_all is_generated_accessor accessors ->
      declaration
  | tops ->
      Alcotest.failf "expected one type declaration and its accessors, got %d tops"
        (List.length tops)

let term_groups tops =
  List.map
    (function
      | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } -> bindings
      | _ -> Alcotest.fail "expected only term declarations")
    tops

let binding_names groups = List.map (List.map (fun binding -> binding.Kernel.bname)) groups

let error_codes source =
  match Surface_parse.parse_string ~file:"bad-decls.jac" source with
  | Ok _ -> Alcotest.failf "expected this source to fail:\n%s" source
  | Error diagnostics -> List.map (fun diagnostic -> Diag.code_or_uncoded diagnostic) diagnostics

let has_code code source = Alcotest.(check bool) source true (List.mem code (error_codes source))

let expected_diagnostic span code summary cause next_step =
  Printf.sprintf "%s: error[%s]: %s\n  Cause: %s\n  Next step: %s" span code summary cause next_step

let e1221 span cause =
  expected_diagnostic span "E1221" "A delimited construct is not closed" cause
    "Close the construct with the expected delimiter."

let e1225 span cause =
  expected_diagnostic span "E1225" "A type or effect declaration is incomplete" cause
    "Complete the declaration structure shown at this location."

let e1236 span cause =
  expected_diagnostic span "E1236" "An effect operation mode is invalid" cause
    "Give each operation exactly one compatible `once` or `multi` mode."

let lower_errors source =
  match Surface_lower.lower_tops (parse source) with
  | Ok _ -> Alcotest.failf "expected lowering to fail:\n%s" source
  | Error diagnostics -> diagnostics

let test_definition_forms () =
  match parse "answer = 42\nid(x) = x\nzero() = 0\n" with
  | [
   { Surface_ast.it = Definition { name = "answer"; equation = false; params = []; _ }; _ };
   { it = Definition { name = "id"; equation = true; params = [ _ ]; _ }; _ };
   { it = Definition { name = "zero"; equation = true; params = []; _ }; _ };
  ] -> (
      let groups = term_groups (lower "answer = 42\nid(x) = x\nzero() = 0\n") in
      match List.concat groups with
      | [
       { Kernel.value = { it = Kernel.Lit (Kernel.LInt 42); _ }; _ };
       { value = { it = Kernel.Lam ([ _ ], _); _ }; _ };
       { value = { it = Kernel.Lam ([], _); _ }; _ };
      ] ->
          ()
      | _ -> Alcotest.fail "value and equation definitions lowered to the wrong shapes")
  | _ -> Alcotest.fail "definition parser did not preserve value/equation syntax"

let test_signature_adjacency () =
  let source = "id : (a) ->{} a\n\n-- annotation survives comments\nid(x) = x\n" in
  let declaration = only_decl (lower source) in
  (match declaration.Kernel.it with
  | Kernel.DefTerm [ { Kernel.bname = "id"; annot = Some _; _ } ] -> ()
  | _ -> Alcotest.fail "the adjacent signature was not attached to id");
  List.iter (has_code "E1224")
    [
      "x : T; x = 1\n";
      "x : T\ny = 1\n";
      "x : T\ny : U\ny = 1\n";
      "x : T\ntype Unitish = Unitish\n";
      "x : T\n42\n";
      "x : T";
    ]

let test_scc_grouping_and_resolution () =
  let self = only_decl (lower "loop(x) = loop(x)\n") |> Resolve.resolve_decl Resolve.empty_names in
  (match self with
  | Ok
      {
        Kernel.it =
          Kernel.DefTerm
            [
              {
                value =
                  {
                    it = Kernel.Lam (_, { it = Kernel.App ({ it = Kernel.GroupRef 0; _ }, _); _ });
                    _;
                  };
                _;
              };
            ];
        _;
      } ->
      ()
  | Ok _ -> Alcotest.fail "self recursion did not resolve through GroupRef 0"
  | Error diagnostics -> fail_diags "resolve self SCC" diagnostics);
  let mutual = only_decl (lower "even(n) = odd(n)\nodd(n) = even(n)\n") in
  (match Resolve.resolve_decl Resolve.empty_names mutual with
  | Ok { Kernel.it = Kernel.DefTerm [ even; odd ]; _ } ->
      Alcotest.(check string) "source order in SCC" "even" even.bname;
      Alcotest.(check string) "source order in SCC" "odd" odd.bname;
      let referenced_index binding =
        match binding.Kernel.value.it with
        | Kernel.Lam (_, { it = Kernel.App ({ it = Kernel.GroupRef index; _ }, _); _ }) -> index
        | _ -> Alcotest.fail "mutual member did not resolve to a GroupRef"
      in
      Alcotest.(check int) "even -> odd" 1 (referenced_index even);
      Alcotest.(check int) "odd -> even" 0 (referenced_index odd)
  | Ok _ -> Alcotest.fail "mutual recursion was not one two-member SCC"
  | Error diagnostics -> fail_diags "resolve mutual SCC" diagnostics);
  Alcotest.(check (list (list string)))
    "independent source order" [ [ "first" ]; [ "second" ] ]
    (binding_names (term_groups (lower "first = 1\nsecond = 2\n")));
  let one_way = term_groups (lower "dependent = dependency\ndependency = 1\n") in
  Alcotest.(check (list (list string)))
    "dependency first"
    [ [ "dependency" ]; [ "dependent" ] ]
    (binding_names one_way);
  match one_way with
  | [ dependency; [ dependent ] ] -> (
      let dependency_hash = Hash.of_string "surface-dependency" in
      let names =
        Resolve.of_alist
          [ ("dependency", { Resolve.hash = dependency_hash; kind = Resolve.KTerm }) ]
      in
      ignore dependency;
      match Resolve.resolve_decl names Kernel.{ it = DefTerm [ dependent ]; meta = Meta.empty } with
      | Ok
          {
            Kernel.it = Kernel.DefTerm [ { value = { it = Kernel.Ref (hash, Kernel.Term); _ }; _ } ];
            _;
          } ->
          Alcotest.(check bool)
            "cross-SCC reference is global" true (Hash.equal dependency_hash hash)
      | Ok _ -> Alcotest.fail "one-way dependency became an in-group reference"
      | Error diagnostics -> fail_diags "resolve one-way SCC" diagnostics)
  | _ -> Alcotest.fail "one-way fixture did not produce two singleton SCCs"

let test_scc_binders_and_quotes () =
  Alcotest.(check (list (list string)))
    "lambda binder is not an edge"
    [ [ "captures" ]; [ "shadowed" ] ]
    (binding_names (term_groups (lower "captures = fn (shadowed) -> shadowed\nshadowed = 1\n")));
  Alcotest.(check (list (list string)))
    "let binder is not an edge" [ [ "local" ]; [ "inside" ] ]
    (binding_names (term_groups (lower "local = { let inside = 1; inside }\ninside = 2\n")));
  let payload =
    match
      Reader.parse_one ~file:"quote.jqd"
        "(tuple (var quoted) (unquote (var live)) (quote (unquote (var nested))))"
    with
    | Ok form -> form
    | Error diagnostics -> fail_diags "quote fixture" diagnostics
  in
  let expression = Kernel.{ it = Quote payload; meta = Meta.empty } in
  Alcotest.(check (list string))
    "only live unquotes make edges" [ "live" ]
    (Surface_lower.String_set.elements (Surface_lower.free_names expression))

let test_duplicate_definition_names () =
  List.iter
    (fun source ->
      match lower_errors source with
      | [ diagnostic ]
        when Diag.code diagnostic = Some "E0303" && Option.is_some (Diag.span diagnostic) ->
          let span = Option.get (Diag.span diagnostic) in
          Alcotest.(check int)
            (source ^ " duplicate starts at second definition")
            (String.index source ';' + 1)
            span.Span.start_pos.offset
      | diagnostics -> fail_diags "duplicate definition diagnostics" diagnostics)
    [ "x=1;x=2"; "x=x;x=1"; "x=x;x=x" ]

let test_type_declarations () =
  let no_initial_bar = only_decl (lower "type Unitish = Unitish\n") in
  let positional = only_decl (lower "type Pair a b = | Pair a b\n") in
  let labeled = declared_type (lower "type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood)\n") in
  let labeled_trailing =
    declared_type (lower "type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood,)\n")
  in
  let mixed = declared_type (lower "type Mixed = | MkMixed(left: SvcMood, SvcMood)\n") in
  let labels declaration =
    match declaration.Kernel.it with
    | Kernel.DefType { cons = [ { fields; _ } ]; _ } ->
        List.map (fun field -> field.Kernel.label) fields
    | _ -> Alcotest.fail "type declaration had the wrong kernel shape"
  in
  Alcotest.(check (list (option string))) "optional initial bar" [] (labels no_initial_bar);
  Alcotest.(check (list (option string))) "positional labels" [ None; None ] (labels positional);
  Alcotest.(check (list (option string)))
    "labeled fields" [ Some "inv"; Some "pay" ] (labels labeled);
  Alcotest.(check (list (option string)))
    "labeled fields trailing comma" (labels labeled) (labels labeled_trailing);
  Alcotest.(check (list (option string))) "mixed fields" [ Some "left"; None ] (labels mixed);
  (match
     (declared_type (lower "type Wrapped a = | MkWrapped(value:\n  List\n    a\n)\n")).Kernel.it
   with
  | Kernel.DefType
      {
        cons =
          [
            {
              fields =
                [
                  {
                    label = Some "value";
                    fty =
                      { it = TApp ({ it = TRef (Named "list"); _ }, [ { it = TVar "a"; _ } ]); _ };
                    _;
                  };
                ];
              _;
            };
          ];
        _;
      } ->
      ()
  | _ -> Alcotest.fail "valid multiline labeled field type was weakened by recovery lookahead");
  has_code "E1225" "type Bad a = | Some(a)\n"

let test_effect_declarations () =
  let declaration =
    only_decl (lower "multi effect Choice a where {\n  choose : (a, Text,) -> Bool\n}\n")
  in
  (match declaration.Kernel.it with
  | Kernel.DefEffect
      {
        ename = "choice";
        evars = [ "a" ];
        ops =
          [ { op_name = "choose"; op_mode = Multi; op_params = [ { it = TVar "a"; _ }; _ ]; _ } ];
      } ->
      ()
  | _ -> Alcotest.fail "effect parameters or operation signature lowered incorrectly");
  let phantom = only_decl (lower "multi effect Choice a where { choose : () -> Bool }\n") in
  (match phantom.Kernel.it with
  | Kernel.DefEffect { evars = [ "a" ]; ops = [ { op_mode = Multi; op_params = []; _ } ]; _ } -> ()
  | _ -> Alcotest.fail "phantom effect parameter was not preserved");
  let once = only_decl (lower "once effect Gate where { enter : () -> () }\n") in
  (match once.Kernel.it with
  | Kernel.DefEffect { ops = [ { op_name = "enter"; op_mode = Once; _ } ]; _ } -> ()
  | _ -> Alcotest.fail "effect-level once shorthand did not lower");
  let mixed =
    only_decl
      (lower "effect Control where {\n  once stop : () -> ()\n  multi branch : () -> ()\n}\n")
  in
  (match mixed.Kernel.it with
  | Kernel.DefEffect
      {
        ops =
          [ { op_name = "stop"; op_mode = Once; _ }; { op_name = "branch"; op_mode = Multi; _ } ];
        _;
      } ->
      ()
  | _ -> Alcotest.fail "mixed per-operation modes did not lower");
  has_code "E1220" "multi effect Choice where\n  choose : () -> Bool\n";
  List.iter (has_code "E1236")
    [
      "effect Missing where { op : () -> () }\n";
      "effect Mixed where { once first : () -> (); second : () -> () }\n";
      "once effect Duplicate where { once op : () -> () }\n";
      "once effect Conflict where { multi op : () -> () }\n";
      "effect Repeated where { once once op : () -> () }\n";
      "once multi effect PrefixConflict where { op : () -> () }\n";
    ];
  let diagnostic_source =
    "effect Missing where { op : () -> () }\n\
     effect Mixed where {\n\
    \  once first : () -> ()\n\
    \  second : () -> ()\n\
     }\n\
     once effect Duplicate where { once op : () -> () }\n\
     once effect Conflict where { multi op : () -> () }\n\
     effect Repeated where { once once op : () -> () }\n\
     once multi effect PrefixConflict where { op : () -> () }\n"
  in
  let rendered =
    Surface_parse.recover_string ~file:"bad-modes.jac" diagnostic_source |> fun recovered ->
    List.map Diag.to_string recovered.Surface_ast.diagnostics
  in
  Alcotest.(check (list string))
    "mode diagnostics and spans"
    [
      e1236 "bad-modes.jac:1:24-26"
        "surface effect operation `op` requires an explicit `once` or `multi` mode; during \
         migration, choose `once` unless its handler deliberately searches, captures, or reuses \
         continuations";
      e1236 "bad-modes.jac:4:3-9"
        "surface effect operation `second` requires an explicit `once` or `multi` mode; during \
         migration, choose `once` unless its handler deliberately searches, captures, or reuses \
         continuations";
      e1236 "bad-modes.jac:6:31-35"
        "`once` is already supplied by the effect-level shorthand; remove the operation-level mode";
      e1236 "bad-modes.jac:7:30-35"
        "operation mode `multi` conflicts with the effect-level `once` shorthand";
      e1236 "bad-modes.jac:8:30-34" "operation mode `once` is duplicated";
      e1236 "bad-modes.jac:9:6-11" "effect-level mode `multi` conflicts with `once`";
    ]
    rendered;
  let format source =
    let recovered = Surface_parse.recover_string ~file:"format-modes.jac" source in
    match Surface_print.print_recovered recovered with
    | Ok text -> text
    | Error diagnostics -> fail_diags "format modes" diagnostics
  in
  let uniform = format "effect Uniform where { once first : () -> (); once second : () -> () }\n" in
  Alcotest.(check string)
    "uniform per-operation syntax canonicalizes to shorthand"
    "once effect Uniform where {\n  first : () -> ()\n  second : () -> ()\n}\n" uniform;
  Alcotest.(check string) "uniform formatter idempotence" uniform (format uniform);
  let mixed_source =
    "effect Mixed where {\n  once stop : () -> ()\n  multi branch : () -> ()\n}\n"
  in
  let mixed = format mixed_source in
  Alcotest.(check string) "mixed canonical syntax" mixed_source mixed;
  Alcotest.(check string) "mixed formatter idempotence" mixed (format mixed)

let test_ordered_bare_expressions () =
  match lower "first = 1\n10\nsecond = 2\n20\n" with
  | [
   Kernel.Decl { it = DefTerm [ { bname = "first"; _ } ]; _ };
   Kernel.Expr { it = Lit (LInt 10); _ };
   Kernel.Decl { it = DefTerm [ { bname = "second"; _ } ]; _ };
   Kernel.Expr { it = Lit (LInt 20); _ };
  ] ->
      ()
  | _ -> Alcotest.fail "bare expressions did not remain ordered run boundaries"

let test_declaration_recovery () =
  let legacy_cases =
    [
      "type Bad = | Some(a)\nlater = 1\n";
      "once effect Bad where {\n  op : () -> T\nlater = 1\n";
      "once effect Bad where {\n  broken = 0\n}\nlater = 1\n";
    ]
  in
  List.iter
    (fun source ->
      let recovered = Surface_parse.recover_string ~file:"recover-decls.jac" source in
      Alcotest.(check bool) "recovery reports damage" true (recovered.diagnostics <> []);
      match List.rev recovered.items with
      | { Surface_ast.it = Definition { name = "later"; _ }; _ } :: _ -> ()
      | _ -> Alcotest.failf "declaration recovery lost the later definition:\n%s" source)
    legacy_cases;
  let exact_cases =
    [
      ( "type without constructor",
        "type Bad = |\nlater = 1\n",
        `Type,
        [ e1225 "recover-decls.jac:2:1-6" "a type declaration requires a constructor after `|`" ] );
      ( "effect without operation or close",
        "once effect Bad where {\nlater = 1\n",
        `Effect,
        [ e1221 "recover-decls.jac:2:1-6" "expected `}` before the next top-level item" ] );
      ( "field without type or close",
        "type Bad = | MkBad(field:\nlater = 1\n",
        `Type,
        [
          e1225 "recover-decls.jac:2:1-6"
            "expected a field type in constructor `MkBad` before the next top-level item";
        ] );
      ( "parsed field type without close",
        "type Bad = | MkBad(field: (List T)\nlater = 1\n",
        `Type,
        [
          e1225 "recover-decls.jac:2:1-6"
            "expected `)` to close constructor `MkBad` before the next top-level item";
        ] );
    ]
  in
  List.iter
    (fun (label, source, first_kind, expected_diagnostics) ->
      let recovered = Surface_parse.recover_string ~file:"recover-decls.jac" source in
      Alcotest.(check (list string))
        (label ^ " ordered diagnostics") expected_diagnostics
        (List.map Diag.to_string recovered.diagnostics);
      match (first_kind, recovered.items) with
      | `Type, [ { it = TypeDecl _; _ }; { it = Definition { name = "later"; _ }; _ } ] -> ()
      | `Effect, [ { it = EffectDecl _; _ }; { it = Definition { name = "later"; _ }; _ } ] -> ()
      | _ -> Alcotest.failf "%s did not retain the declaration and later definition" label)
    exact_cases

let source_slice source meta =
  match Meta.span meta with
  | None -> Alcotest.fail "expected source metadata to carry a span"
  | Some span ->
      String.sub source span.Span.start_pos.offset (span.end_pos.offset - span.start_pos.offset)

let test_spans () =
  let source = "id : (a) ->{} a\n\n-- doc\nid(x) = x\n" in
  let declaration = only_decl (lower source) in
  (match declaration.Kernel.it with
  | Kernel.DefTerm [ binding ] ->
      Alcotest.(check string)
        "merged binding span" "id : (a) ->{} a\n\n-- doc\nid(x) = x"
        (source_slice source binding.Kernel.bmeta);
      Alcotest.(check string)
        "merged declaration span" "id : (a) ->{} a\n\n-- doc\nid(x) = x"
        (source_slice source declaration.meta)
  | _ -> Alcotest.fail "span fixture was not one term declaration");
  let type_source = "type Fleet = | MkFleet(inv: SvcMood, SvcMood)\n" in
  let type_decl = declared_type (lower type_source) in
  (match type_decl.Kernel.it with
  | Kernel.DefType { cons = [ { fields = [ labeled; positional ]; _ } ]; _ } ->
      Alcotest.(check string)
        "labeled field span" "inv: SvcMood"
        (source_slice type_source labeled.Kernel.fmeta);
      Alcotest.(check string)
        "positional field span" "SvcMood"
        (source_slice type_source positional.Kernel.fmeta)
  | _ -> Alcotest.fail "field span fixture had the wrong shape");
  let effect_source = "multi effect Choice a where {\n  choose : () -> Bool\n}\n" in
  let effect_decl = only_decl (lower effect_source) in
  match effect_decl.Kernel.it with
  | Kernel.DefEffect { ops = [ operation ]; _ } ->
      Alcotest.(check string)
        "operation span" "choose : () -> Bool"
        (source_slice effect_source operation.Kernel.smeta)
  | _ -> Alcotest.fail "operation span fixture had the wrong shape"

let test_surface_bootstrap_equivalence () =
  let bool_hash = Hash.of_string "surface-bool" in
  let mood_hash = Hash.of_string "surface-mood" in
  let names =
    Resolve.of_alist
      [
        ("bool", { Resolve.hash = bool_hash; kind = Resolve.KType });
        ("svc-mood", { Resolve.hash = mood_hash; kind = Resolve.KType });
      ]
  in
  check_equivalent "value definition" "answer = 42\n" "(defterm ((binding answer () (lit 42))))";
  check_equivalent "annotated equation" "id : (a) ->{} a\nid(x) = x\n"
    "(defterm ((binding id ((tarrow ((tvar a)) (row) (tvar a))) (lam ((pvar x)) (var x)))))";
  check_equivalent "positional type" "type Option a = | None | Some a\n"
    "(deftype option ((tvar a)) (con none) (con some (field (tvar a))))";
  check_equivalent ~names "labeled type" "type Fleet = | MkFleet(inv: SvcMood, SvcMood)\n"
    "(deftype fleet () (con mk-fleet (field inv (tref svc-mood)) (field (tref svc-mood))))";
  check_equivalent ~names "phantom effect" "multi effect Choice a where { choose : () -> Bool }\n"
    "(defeffect choice ((tvar a)) (op choose () (tref bool)))";
  check_equivalent "once operation" "once effect Gate where { enter : () -> () }\n"
    "(defeffect gate () (op enter once () (ttuple)))";
  check_equivalent "bare expression" "42\n" "(lit 42)"

let test_bootstrap_reader_unchanged () =
  let source = "(defterm ((binding id () (lam ((pvar x)) (var x)))))" in
  match Reader.parse_one ~file:"unchanged.jqd" source with
  | Ok form -> (
      match Kernel.of_form form with
      | Ok (Kernel.Decl { Kernel.it = Kernel.DefTerm [ _ ]; _ }) -> ()
      | _ -> Alcotest.fail "bootstrap declaration validation changed")
  | Error diagnostics -> fail_diags "bootstrap reader regression" diagnostics

(* --- SX.27: D36 generated accessors and declaration-time label validation --- *)

let accessor_names tops =
  List.filter_map
    (function
      | Kernel.Decl { Kernel.it = Kernel.DefTerm [ binding ]; _ } as top
        when is_generated_accessor top ->
          Some binding.Kernel.bname
      | _ -> None)
    tops

(* Resolve and install tops in order in a fresh store, returning each top's canonical hash. *)
let installed_hashes tops =
  let root = Filename.temp_dir "jacquard-accessor-" ".store" in
  match Store.open_store root with
  | Error diagnostics -> fail_diags "open store" diagnostics
  | Ok store ->
      List.map
        (fun top ->
          let resolved = resolve (Store.names_view store) top in
          (match resolved with
          | Kernel.Decl declaration -> (
              match Store.put_decl store declaration with
              | Ok _ -> ()
              | Error diagnostics -> fail_diags "install" diagnostics)
          | Kernel.Expr _ -> ());
          (resolved, hash resolved))
        tops

let test_generated_accessors_match_kernel_twins () =
  let surface = lower "type Pair a b = | Pair(left: a, right: b)\n" in
  Alcotest.(check (list string))
    "one accessor per label" [ "pair.left"; "pair.right" ] (accessor_names surface);
  let twin =
    bootstrap
      "(deftype pair ((tvar a) (tvar b)) (con pair (field left (tvar a)) (field right (tvar b))))\n\
       (defterm ((binding pair.left () (lam ((pvar value)) (match (var value) (clause (pcon pair \
       (pvar field) (pwild)) (var field)))))))\n\
       (defterm ((binding pair.right () (lam ((pvar value)) (match (var value) (clause (pcon pair \
       (pwild) (pvar field)) (var field)))))))\n"
  in
  List.iter2
    (fun (actual, actual_hash) (expected, expected_hash) ->
      Alcotest.(check bool)
        "resolved accessor AST" true
        (Form.equal_ignoring_meta (Kernel.to_form expected) (Kernel.to_form actual));
      Alcotest.(check string)
        "canonical identity" (Hash.to_hex expected_hash) (Hash.to_hex actual_hash))
    (installed_hashes surface) (installed_hashes twin);
  (* every constructor gets a clause, so the accessor is total over a sum type *)
  let shapes = lower "type Shape = | Circle(id: Int, radius: Int) | Square(side: Int, id: Int)\n" in
  Alcotest.(check (list string))
    "only uniformly carried labels" [ "shape.id" ] (accessor_names shapes);
  match List.rev shapes with
  | Kernel.Decl { Kernel.it = Kernel.DefTerm [ { value; _ } ]; _ } :: _ -> (
      match value.Kernel.it with
      | Kernel.Lam (_, { Kernel.it = Kernel.Match (_, [ circle; square ]); _ }) -> (
          match (circle.Kernel.cpat.it, square.Kernel.cpat.it) with
          | ( Kernel.PCon
                (_, [ { Kernel.it = Kernel.PVar "field"; _ }; { Kernel.it = Kernel.PWild; _ } ]),
              Kernel.PCon
                (_, [ { Kernel.it = Kernel.PWild; _ }; { Kernel.it = Kernel.PVar "field"; _ } ]) )
            ->
              ()
          | _ -> Alcotest.fail "accessor clauses select the wrong positions")
      | _ -> Alcotest.fail "accessor is not a one-parameter match")
  | _ -> Alcotest.fail "the accessor does not follow its type"

let test_ineligible_labels_generate_nothing () =
  List.iter
    (fun (label, source) -> Alcotest.(check (list string)) label [] (accessor_names (lower source)))
    [
      ("positional fields", "type Pair a b = | Pair a b\n");
      ("label on some constructors", "type Reply = | Accepted(value: Int) | Refused(reason: Text)\n");
      ("label missing from one constructor", "type Tagged = | Tag(id: Int) | Untagged\n");
      (* an escaped type name ending in `?` has no dotted namespace for an accessor *)
      ("type name without a namespace", "type `type:ok?` = | Mk(x: Int)\n");
    ];
  (* generated accessors never reach the surface printer's output *)
  match lower "type Pair = | Pair(left: Int, right: Int)\n" with
  | _ :: accessor :: _ -> (
      match Surface_print.print_top accessor with
      | Ok printed -> Alcotest.(check string) "accessor prints nothing" "" printed
      | Error diagnostics -> fail_diags "print accessor" diagnostics)
  | _ -> Alcotest.fail "no accessor was generated"

let expect_lowering_error label ~code ~span source =
  match Surface_lower.lower_tops (parse source) with
  | Ok _ -> Alcotest.failf "%s: lowering accepted the declaration" label
  | Error [ diagnostic ] ->
      Alcotest.(check string) (label ^ " code") code (Diag.code_or_uncoded diagnostic);
      let rendered =
        match Diag.span diagnostic with
        | Some span ->
            String.sub source span.Span.start_pos.offset
              (span.end_pos.offset - span.start_pos.offset)
        | None -> "<no span>"
      in
      Alcotest.(check string) (label ^ " span") span rendered
  | Error diagnostics -> fail_diags (label ^ ": expected one diagnostic") diagnostics

let test_label_validation () =
  expect_lowering_error "duplicate label" ~code:"E1239" ~span:"left: Text"
    "type Pair = | Pair(left: Int, left: Text)\n";
  expect_lowering_error "inconsistent label type" ~code:"E1240" ~span:"id: Text"
    "type Key = | Numbered(id: Int) | Named(id: Text)\n";
  expect_lowering_error "collision with an explicit term" ~code:"E1241" ~span:"left: Int"
    "pair.left(p) = 0\ntype Pair = | Pair(left: Int, right: Int)\n";
  expect_lowering_error "collision with a later explicit term" ~code:"E1241" ~span:"right: Int"
    "type Pair = | Pair(left: Int, right: Int)\npair.right(p) = 0\n";
  expect_lowering_error "collision with a raw bootstrap term" ~code:"E1241" ~span:"left: Int"
    "type Pair = | Pair(left: Int)\n\
     jqd { (defterm ((binding pair.left () (lam ((pvar p)) (lit 0))))) }\n";
  (* types are compared before resolution only where resolution cannot make them equal *)
  List.iter
    (fun (label, source) ->
      Alcotest.(check (list string)) label [ "same.f" ] (accessor_names (lower source)))
    [
      ( "effect rows compare as sets",
        "type Same = | A(f: (Int) ->{Console, Abort} Int) | B(f: (Int) ->{Abort, Console} Int)\n" );
      ( "hash references are left to the checker",
        "type Same = | A(f: Int) | B(f: \
         #907085f5670ab5835e5356feb10ae729496e3816b863ddbb21cfe289e7d34f0d:type)\n" );
    ];
  (* a same-typed label on some constructors only is valid and has no accessor *)
  Alcotest.(check (list string))
    "consistent partial label" []
    (accessor_names (lower "type Key = | Numbered(id: Int, n: Int) | Other(id: Int) | Blank\n"))

let suite =
  [
    Alcotest.test_case "generated accessors match kernel twins" `Quick
      test_generated_accessors_match_kernel_twins;
    Alcotest.test_case "ineligible labels generate no accessor" `Quick
      test_ineligible_labels_generate_nothing;
    Alcotest.test_case "declaration-time label validation" `Quick test_label_validation;
    Alcotest.test_case "definition forms" `Quick test_definition_forms;
    Alcotest.test_case "signature adjacency" `Quick test_signature_adjacency;
    Alcotest.test_case "SCC grouping and resolution" `Quick test_scc_grouping_and_resolution;
    Alcotest.test_case "SCC binders and quotes" `Quick test_scc_binders_and_quotes;
    Alcotest.test_case "duplicate definition names" `Quick test_duplicate_definition_names;
    Alcotest.test_case "type declarations" `Quick test_type_declarations;
    Alcotest.test_case "effect declarations" `Quick test_effect_declarations;
    Alcotest.test_case "ordered bare expressions" `Quick test_ordered_bare_expressions;
    Alcotest.test_case "declaration recovery" `Quick test_declaration_recovery;
    Alcotest.test_case "spans" `Quick test_spans;
    Alcotest.test_case "surface/bootstrap equivalence" `Quick test_surface_bootstrap_equivalence;
    Alcotest.test_case "bootstrap reader unchanged" `Quick test_bootstrap_reader_unchanged;
  ]
