open Jacquard

(* PF.2 phase 1: arrow tiers, resume disciplines, and the store's tier sidecar.
   The discipline classifier is deliberately conservative; the state.run case below
   pins the known false-negative (state-passing style reads as multi-shot). *)

let parse_expr src =
  match Reader.parse_one ~file:"t.jqd" src with
  | Error ds -> Alcotest.failf "parse: %s" (String.concat "; " (List.map Diag.to_string ds))
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> Alcotest.failf "validate: %s" (String.concat "; " (List.map Diag.to_string ds))
      | Ok e -> e)

let disc = Alcotest.testable (Fmt.of_to_string Tier.discipline_to_string) ( = )
let tier = Alcotest.testable (Fmt.of_to_string Tier.to_string) ( = )
let classify src = Tier.discipline ~resume:"k" (parse_expr src)

let test_classify_ty () =
  let h = Hash.of_string "eff" in
  let int_ty = Types.TCon (Hash.of_string "int", []) in
  Alcotest.check tier "non-arrow is data" Tier.Data (Tier.classify_ty int_ty);
  Alcotest.check tier "closed empty row is pure" Tier.Pure
    (Tier.classify_ty (Types.TArrow ([ int_ty ], Types.empty_row, int_ty)));
  Alcotest.check tier "open empty row is row-poly" Tier.RowPoly
    (Tier.classify_ty
       (Types.TArrow ([ int_ty ], { Types.effects = []; tail = Types.new_rvar 1 }, int_ty)));
  Alcotest.check tier "closed effects"
    (Tier.Effectful { effects = [ h ]; opened = false })
    (Tier.classify_ty (Types.TArrow ([ int_ty ], Types.closed_row [ h ], int_ty)));
  Alcotest.check tier "open effects"
    (Tier.Effectful { effects = [ h ]; opened = true })
    (Tier.classify_ty (Types.TArrow ([ int_ty ], Types.open_row 1 [ h ], int_ty)))

let test_render_roundtrip () =
  let h1 = Hash.of_string "a" and h2 = Hash.of_string "b" in
  List.iter
    (fun t ->
      Alcotest.check (Alcotest.option tier) (Tier.to_string t) (Some t)
        (Tier.of_string (Tier.to_string t)))
    [
      Tier.Data;
      Tier.Pure;
      Tier.RowPoly;
      Tier.Effectful { effects = [ h1 ]; opened = false };
      Tier.Effectful { effects = [ h1; h2 ]; opened = true };
    ];
  Alcotest.check (Alcotest.option tier) "garbage is None" None (Tier.of_string "granite")

let test_disciplines () =
  Alcotest.check disc "no resume aborts" Tier.Aborting (classify "(lit 7)");
  Alcotest.check disc "single tail resume" Tier.TailResumptive (classify "(app (var k) (lit 0))");
  Alcotest.check disc "resume under let is off tail" Tier.OneShot
    (classify "(let nonrec (pvar r) (app (var k) (lit 1)) (var r))");
  Alcotest.check disc "two resumes clone" Tier.MultiShot
    (classify "(tuple (app (var k) (lit 1)) (app (var k) (lit 2)))");
  Alcotest.check disc "resume as a value escapes" Tier.MultiShot (classify "(var k)");
  Alcotest.check disc "state-passing style escapes under the lam" Tier.MultiShot
    (classify "(lam ((pvar s)) (app (app (var k) (var s)) (var s)))");
  Alcotest.check disc "abort on one arm is not tail-resumptive" Tier.OneShot
    (classify
       "(match (var c) (clause (pcon true) (app (var k) (lit 1))) (clause (pcon false) (lit 0)))");
  Alcotest.check disc "every arm tail-resumes" Tier.TailResumptive
    (classify
       "(match (var c) (clause (pcon true) (app (var k) (lit 1))) (clause (pcon false) (app (var \
        k) (lit 2))))");
  Alcotest.check disc "shadowed k does not count" Tier.Aborting
    (classify "(app (lam ((pvar k)) (app (var k) (lit 1))) (lam ((pvar x)) (var x)))")

(* --- sidecar persistence --- *)

let fresh_root =
  let n = ref 0 in
  fun () ->
    incr n;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-tier-test-%d-%d" (Unix.getpid ()) !n)

let open_ok root =
  match Store.open_store root with
  | Ok t -> t
  | Error ds ->
      Alcotest.failf "open_store failed: %s" (String.concat "; " (List.map Diag.to_string ds))

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let test_sidecar_roundtrip () =
  let root = fresh_root () in
  let store = open_ok root in
  let hs =
    let src = "(defterm ((binding f () (lam ((pvar x)) (var x)))))" in
    match Reader.parse_one ~file:"t.jqd" src with
    | Error _ -> Alcotest.fail "parse"
    | Ok f -> (
        match Kernel.decl_of_form f with
        | Error _ -> Alcotest.fail "validate"
        | Ok d -> (
            match Resolve.resolve_decl (Store.names_view store) d with
            | Error _ -> Alcotest.fail "resolve"
            | Ok d -> (
                match Store.put_decl store d with Error _ -> Alcotest.fail "put" | Ok hs -> hs)))
  in
  let member = List.assoc "f" hs.Canon.named in
  let object_bytes = read_file (Store.object_path store hs.Canon.decl_hash) in
  Alcotest.check (Alcotest.option tier) "unstamped is None" None (Store.tier store member);
  let t = Tier.Effectful { effects = [ Hash.of_string "eff" ]; opened = true } in
  Store.stamp_tier store member t;
  Alcotest.check (Alcotest.option tier) "stamp reads back" (Some t) (Store.tier store member);
  Store.stamp_tier store member Tier.Pure;
  Alcotest.check (Alcotest.option tier) "last writer wins" (Some Tier.Pure)
    (Store.tier store member);
  Alcotest.check Alcotest.string "the object file is untouched (metadata law)" object_bytes
    (read_file (Store.object_path store hs.Canon.decl_hash));
  (* the sidecar survives a reopen, and the reopened index ignores .tier files *)
  let store2 = open_ok root in
  Alcotest.check (Alcotest.option tier) "sidecar survives reopen" (Some Tier.Pure)
    (Store.tier store2 member);
  Alcotest.(check bool)
    "reopened store still resolves f" true
    (Option.is_some (Store.lookup_name store2 "f"))

let suite =
  [
    Alcotest.test_case "arrow rows classify by shape" `Quick test_classify_ty;
    Alcotest.test_case "tier rendering round-trips" `Quick test_render_roundtrip;
    Alcotest.test_case "resume disciplines" `Quick test_disciplines;
    Alcotest.test_case "tier sidecar round-trips through the store" `Quick test_sidecar_roundtrip;
  ]
