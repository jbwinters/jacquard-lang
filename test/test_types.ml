open Jacquard
open Jacquard.Types

(* W3.1: the unifier, with the row cases the plan names, plus the qcheck symmetry
   property. Effect labels here are arbitrary distinct hashes. *)

let ha = Hash.of_string "effect-a"
let hb = Hash.of_string "effect-b"
let hc = Hash.of_string "effect-c"
let t_int = TCon (Hash.of_string "ty-int", [])
let t_text = TCon (Hash.of_string "ty-text", [])
let unifies f = match f () with () -> true | exception Unify_error _ -> false

let source_contains source needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) source 0);
    true
  with Not_found -> false

let check_frozen_spawn_shape_guard () =
  let source = Corpus_support.read_file "../src/check.ml" in
  Alcotest.(check bool)
    "frozen spawn shape disagreement is an E0805 diagnostic" true
    (source_contains source
       "frozen async.spawn identity resolved to an invalid converted parameter shape");
  Alcotest.(check bool)
    "frozen spawn shape disagreement never asserts" false
    (source_contains source "assert false (* the identity guard proved the exact frozen shape *)")

let test_type_cases () =
  let cases =
    [
      ("int ~ int", (fun () -> unify t_int t_int), true);
      ("int ~ text", (fun () -> unify t_int t_text), false);
      ("var ~ int", (fun () -> unify (new_tvar 0) t_int), true);
      ( "var binds and sticks",
        (fun () ->
          let v = new_tvar 0 in
          unify v t_int;
          unify v t_int),
        true );
      ( "var binds and conflicts",
        (fun () ->
          let v = new_tvar 0 in
          unify v t_int;
          unify v t_text),
        false );
      ( "occurs check",
        (fun () ->
          let v = new_tvar 0 in
          unify v (TArrow ([ v ], empty_row, t_int))),
        false );
      ( "arrow arity",
        (fun () ->
          unify (TArrow ([ t_int ], empty_row, t_int)) (TArrow ([ t_int; t_int ], empty_row, t_int))),
        false );
      ("tuple lengths", (fun () -> unify (TTuple [ t_int ]) (TTuple [ t_int; t_int ])), false);
      ( "con args unify",
        (fun () ->
          let v = new_tvar 0 in
          unify (TCon (ha, [ v ])) (TCon (ha, [ t_int ]));
          unify v t_int),
        true );
      ("con head mismatch", (fun () -> unify (TCon (ha, [])) (TCon (hb, []))), false);
      ( "skolem reflexive",
        (fun () ->
          let s = TSkolem (fresh_id (), "a") in
          unify s s),
        true );
      ( "skolems distinct",
        (fun () -> unify (TSkolem (fresh_id (), "a")) (TSkolem (fresh_id (), "b"))),
        false );
      ("skolem vs concrete", (fun () -> unify (TSkolem (fresh_id (), "a")) t_int), false);
      ("var ~ skolem ok", (fun () -> unify (new_tvar 0) (TSkolem (fresh_id (), "a"))), true);
      ( "Resume unifies with the same Resume shape",
        (fun () ->
          unify
            (TResume (t_int, closed_row [ ha ], t_text))
            (TResume (t_int, closed_row [ ha ], t_text))),
        true );
      ( "Resume crosses a unary local-helper boundary",
        (fun () ->
          unify
            (TResume (t_int, closed_row [ ha ], t_text))
            (TArrow ([ t_int ], closed_row [ ha ], t_text))),
        true );
      ( "Resume does not cross a multi-argument function boundary",
        (fun () ->
          unify
            (TResume (t_int, closed_row [ ha ], t_text))
            (TArrow ([ t_int; t_int ], closed_row [ ha ], t_text))),
        false );
    ]
  in
  List.iter (fun (name, f, expected) -> Alcotest.(check bool) name expected (unifies f)) cases;
  check_frozen_spawn_shape_guard ()

let arrow_with_row row = TArrow ([ t_int ], row, t_int)

let test_row_cases () =
  let cases =
    [
      ( "closed ~ closed equal",
        (fun () -> unify_rows (closed_row [ ha; hb ]) (closed_row [ hb; ha ])),
        true );
      ( "closed ~ closed differ",
        (fun () -> unify_rows (closed_row [ ha ]) (closed_row [ ha; hb ])),
        false );
      ( "open absorbs closed remainder",
        (fun () -> unify_rows (open_row 0 [ ha ]) (closed_row [ ha; hb ])),
        true );
      ( "closed cannot absorb",
        (fun () -> unify_rows (closed_row [ ha ]) (open_row 0 [ ha; hb ])),
        false );
      ( "open ~ open fresh tail",
        (fun () ->
          let ra = open_row 0 [ ha ] and rb = open_row 0 [ hb ] in
          unify_rows ra rb;
          (* both sides now include both labels *)
          let ra = repr_row ra and rb = repr_row rb in
          if not (List.exists (Hash.equal hb) ra.effects && List.exists (Hash.equal ha) rb.effects)
          then raise (Unify_error "labels did not propagate")),
        true );
      ( "same tail same sets",
        (fun () ->
          let tail = new_rvar 0 in
          unify_rows { effects = [ ha ]; tail } { effects = [ ha ]; tail }),
        true );
      ( "same tail different sets occurs",
        (fun () ->
          let tail = new_rvar 0 in
          unify_rows { effects = [ ha ]; tail } { effects = [ hb ]; tail }),
        false );
      ( "spawn-dependent child/caller row cannot hide an extra effect",
        (fun () ->
          let shared = open_row 0 [ ha ] in
          let spawn = TArrow ([ TArrow ([], shared, t_text) ], shared, t_int) in
          let misleading =
            TArrow ([ TArrow ([], shared, t_text) ], { shared with effects = [ ha; hb ] }, t_int)
          in
          unify spawn misleading),
        false );
      ( "row via arrows",
        (fun () -> unify (arrow_with_row (open_row 0 [])) (arrow_with_row (closed_row [ hc ]))),
        true );
      ( "row skolem reflexive",
        (fun () ->
          let sk = RSkolem (fresh_id (), "e") in
          unify_rows { effects = [ ha ]; tail = sk } { effects = [ ha ]; tail = sk }),
        true );
      ( "row skolem vs closed",
        (fun () -> unify_rows { effects = []; tail = RSkolem (fresh_id (), "e") } (closed_row [])),
        false );
      ( "open var absorbs skolem side",
        (fun () ->
          let sk = RSkolem (fresh_id (), "e") in
          unify_rows { effects = [ ha ]; tail = sk } { effects = []; tail = new_rvar 0 }),
        true );
    ]
  in
  List.iter (fun (name, f, expected) -> Alcotest.(check bool) name expected (unifies f)) cases

(* transitivity through variables: a ~ b, b ~ int, then a is int *)
let test_chains () =
  let a = new_tvar 0 and b = new_tvar 0 in
  unify a b;
  unify b t_int;
  Alcotest.(check bool) "chained" true (unifies (fun () -> unify a t_int));
  Alcotest.(check bool) "chained conflict" false (unifies (fun () -> unify a t_text))

let test_row_inclusion_does_not_pollute_callee () =
  let callee = open_row 1 [] in
  let ambient = open_row 1 [ ha ] in
  let ambient = include_rows ~sub:callee ~into:ambient in
  let ambient = include_rows ~sub:(closed_row [ hb ]) ~into:ambient in
  let callee = repr_row callee and ambient = repr_row ambient in
  Alcotest.(check bool) "ambient fixed effects do not leak backward" true (callee.effects = []);
  Alcotest.(check bool)
    "ambient accumulates effects before and after higher-order call" true
    (List.for_all (fun eff -> List.exists (Hash.equal eff) ambient.effects) [ ha; hb ])

let arrow_row = function
  | TArrow (_, row, _) -> row
  | ty -> Alcotest.failf "expected arrow, got %s" (show ty)

let assert_constructive_join label wrap unwrap =
  List.iter
    (fun reverse ->
      let tail = new_rvar 1 in
      let callback_row = { effects = []; tail } and effectful_row = { effects = [ hb ]; tail } in
      let callback = TArrow ([], callback_row, t_int)
      and effectful = TArrow ([], effectful_row, t_int) in
      let left, right = if reverse then (effectful, callback) else (callback, effectful) in
      let joined = join ~level:1 (wrap left) (wrap right) |> unwrap |> arrow_row in
      Alcotest.(check bool)
        (label ^ " source callback stays clean")
        true
        ((repr_row callback_row).effects = []);
      Alcotest.(check bool)
        (label ^ " result owns an independent row")
        true
        (joined != callback_row && joined != effectful_row);
      Alcotest.(check bool)
        (label ^ " result contains branch effects")
        true
        (List.exists (Hash.equal hb) (repr_row joined).effects);
      unify_rows callback_row (closed_row []);
      Alcotest.(check bool)
        (label ^ " callback can still close pure")
        true
        ((repr_row callback_row).effects = [] && (repr_row joined).effects = [ hb ]))
    [ false; true ]

let test_join_constructs_non_aliasing_results () =
  assert_constructive_join "direct" (fun ty -> ty) (fun ty -> ty);
  assert_constructive_join "tuple"
    (fun ty -> TTuple [ ty ])
    (function
      | TTuple [ ty ] -> ty | ty -> Alcotest.failf "expected singleton tuple, got %s" (show ty));
  assert_constructive_join "constructor"
    (fun ty -> TCon (hc, [ ty ]))
    (function
      | TCon (head, [ ty ]) when Hash.equal head hc -> ty
      | ty -> Alcotest.failf "expected constructor wrapper, got %s" (show ty));
  let rigid = RSkolem (fresh_id (), "e") in
  let rigid_left = { effects = [ ha ]; tail = rigid }
  and rigid_right = { effects = [ hb ]; tail = rigid } in
  Alcotest.(check bool)
    "rigid annotation rows remain exact" false
    (unifies (fun () ->
         ignore
           (join ~level:1
              (TArrow ([ t_int ], rigid_left, t_int))
              (TArrow ([ t_int ], rigid_right, t_int)))));
  Alcotest.(check bool)
    "failed rigid join leaves sources unchanged" true
    (rigid_left.effects = [ ha ] && rigid_right.effects = [ hb ]);
  let recursive = new_tvar 1 in
  Alcotest.(check bool)
    "join accumulator preserves the occurs check" false
    (unifies (fun () -> join_into ~level:1 recursive (TCon (hc, [ recursive ]))))

let test_mono_scheme_does_not_implicitly_generalize_rows () =
  let row = open_row 1 [] in
  let scheme = mono (TArrow ([ t_int ], row, t_int)) in
  let first = instantiate ~level:2 scheme and second = instantiate ~level:2 scheme in
  unify first (TArrow ([ t_int ], closed_row [ ha ], t_int));
  Alcotest.(check bool)
    "the second use shares the monomorphic row constraint" false
    (unifies (fun () -> unify second (TArrow ([ t_int ], closed_row [ hb ], t_int))))

(* --- qcheck: unify(a,b) succeeds iff unify(b,a) does, with agreeing solutions --- *)

(* A pure structure with shared variable slots; materialized fresh per direction. *)
type tpl =
  | PInt
  | PText
  | PVar of int
  | PTuple of tpl list
  | PArrow of tpl list * int option * bool * tpl (* row var slot, has-label-a?, result *)

let gen_tpl : tpl QCheck.Gen.t =
  let open QCheck.Gen in
  sized
  @@ fix (fun self n ->
      let base = oneof [ return PInt; return PText; map (fun i -> PVar (i mod 3)) nat_small ] in
      if n = 0 then base
      else
        oneof
          [
            base;
            map (fun ts -> PTuple ts) (list_size (int_range 0 2) (self (n / 3)));
            map2
              (fun (t1, rv) t2 ->
                PArrow ([ t1 ], (if rv mod 3 = 0 then None else Some (rv mod 2)), rv mod 2 = 0, t2))
              (pair (self (n / 3)) nat_small)
              (self (n / 3));
          ])

let materialize (t : tpl) =
  let tvars = Hashtbl.create 4 and rvars = Hashtbl.create 4 in
  let tv i =
    match Hashtbl.find_opt tvars i with
    | Some v -> v
    | None ->
        let v = new_tvar 1 in
        Hashtbl.add tvars i v;
        v
  in
  let rv i =
    match Hashtbl.find_opt rvars i with
    | Some v -> v
    | None ->
        let v = new_rvar 1 in
        Hashtbl.add rvars i v;
        v
  in
  let rec go = function
    | PInt -> t_int
    | PText -> t_text
    | PVar i -> tv i
    | PTuple ts -> TTuple (List.map go ts)
    | PArrow (ps, rvi, la, r) ->
        let tail = match rvi with None -> RClosed | Some i -> rv i in
        TArrow (List.map go ps, { effects = (if la then [ ha ] else []); tail }, go r)
  in
  go t

let prop_unify_symmetric =
  QCheck.Test.make ~count:500 ~name:"unify symmetry: unify(a,b) iff unify(b,a), same solution"
    QCheck.(make Gen.(pair gen_tpl gen_tpl))
    (fun (ta, tb) ->
      let run flip =
        let a = materialize ta and b = materialize tb in
        match if flip then unify b a else unify a b with
        | () -> Some (Types.show (TTuple [ a; b ]))
        | exception Unify_error _ -> None
      in
      match (run false, run true) with
      | None, None -> true
      | Some s1, Some s2 -> s1 = s2 (* zonked rendering agrees up to var naming *)
      | _ -> false)

let prop_spawn_dependent_row_charges_child_effects =
  QCheck.Test.make ~count:200 ~name:"spawn-dependent row retains every generated child effect"
    QCheck.(make Gen.(pair bool bool))
    (fun (uses_b, uses_c) ->
      let shared = open_row 0 [ ha ] in
      let spawn = TArrow ([ TArrow ([], shared, t_text) ], shared, t_int) in
      let child_effects = ha :: ((if uses_b then [ hb ] else []) @ if uses_c then [ hc ] else []) in
      let child = TArrow ([], closed_row child_effects, t_text) in
      match unify spawn (TArrow ([ child ], open_row 0 [], t_int)) with
      | () ->
          let charged =
            match repr spawn with TArrow (_, row, _) -> (repr_row row).effects | _ -> assert false
          in
          List.for_all
            (fun child_effect -> List.exists (Hash.equal child_effect) charged)
            child_effects
      | exception Unify_error _ -> false)

let prop_row_inclusion_keeps_fixed_effects_directional =
  QCheck.Test.make ~count:300 ~name:"row inclusion never copies ambient fixed effects into callee"
    QCheck.(make Gen.(pair bool bool))
    (fun (ambient_has_a, later_has_b) ->
      let callee = open_row 1 [] in
      let ambient = open_row 1 (if ambient_has_a then [ ha ] else []) in
      let ambient = include_rows ~sub:callee ~into:ambient in
      let ambient =
        include_rows ~sub:(closed_row (if later_has_b then [ hb ] else [])) ~into:ambient
      in
      let callee = repr_row callee and ambient = repr_row ambient in
      callee.effects = []
      && List.exists (Hash.equal ha) ambient.effects = ambient_has_a
      && List.exists (Hash.equal hb) ambient.effects = later_has_b)

let suite =
  [
    Alcotest.test_case "type unification cases" `Quick test_type_cases;
    Alcotest.test_case "row unification cases" `Quick test_row_cases;
    Alcotest.test_case "chained unification" `Quick test_chains;
    Alcotest.test_case "row inclusion is directional" `Quick
      test_row_inclusion_does_not_pollute_callee;
    Alcotest.test_case "join constructs non-aliasing results" `Quick
      test_join_constructs_non_aliasing_results;
    Alcotest.test_case "mono schemes do not generalize rows" `Quick
      test_mono_scheme_does_not_implicitly_generalize_rows;
    QCheck_alcotest.to_alcotest prop_unify_symmetric;
    QCheck_alcotest.to_alcotest prop_spawn_dependent_row_charges_child_effects;
    QCheck_alcotest.to_alcotest prop_row_inclusion_keeps_fixed_effects_directional;
  ]
