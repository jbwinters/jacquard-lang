open Jacquard

(* Hand-built in-memory store stub (the W1.4 seam); the real store lands in W1.6. *)
let h name = Hash.of_string ("stub:" ^ name)

let stub =
  Resolve.of_alist
    (List.map
       (fun (n, k) -> (n, { Resolve.hash = h n; kind = k }))
       [
         ("add", Resolve.KTerm);
         ("sub", Resolve.KTerm);
         ("mul", Resolve.KTerm);
         ("div", Resolve.KTerm);
         ("eq", Resolve.KTerm);
         ("true", Resolve.KCon);
         ("false", Resolve.KCon);
         ("some", Resolve.KCon);
         ("none", Resolve.KCon);
         ("abort", Resolve.KOp);
         ("print", Resolve.KOp);
         ("int", Resolve.KType);
         ("text", Resolve.KType);
         ("option", Resolve.KType);
         ("console", Resolve.KEffect);
       ])

let parse_top s =
  match Reader.parse_one ~file:"r.wft" s with
  | Error ds -> Alcotest.failf "parse failed: %s" (String.concat "; " (List.map Diag.to_string ds))
  | Ok f -> (
      match Kernel.of_form f with
      | Error ds ->
          Alcotest.failf "validation failed: %s" (String.concat "; " (List.map Diag.to_string ds))
      | Ok t -> t)

let resolve_ok s =
  match Resolve.resolve stub (parse_top s) with
  | Ok t -> t
  | Error ds ->
      Alcotest.failf "expected %S to resolve: %s" s
        (String.concat "; " (List.map Diag.to_string ds))

let resolve_err s =
  match Resolve.resolve stub (parse_top s) with
  | Ok _ -> Alcotest.failf "expected %S to fail resolution" s
  | Error ds -> ds

let expr_of_top = function
  | Kernel.Expr e -> e
  | Kernel.Decl _ -> Alcotest.fail "expected an expression"

(* --- resolution of free names --- *)

let test_free_name_becomes_ref () =
  let e = expr_of_top (resolve_ok "(app (var add) (lit 1) (lit 2))") in
  match e.Kernel.it with
  | Kernel.App ({ Kernel.it = Kernel.Ref (hash, Kernel.Term); meta }, _) ->
      Alcotest.(check bool) "hash is add's" true (Hash.equal hash (h "add"));
      Alcotest.(check (option string))
        "original name retained in meta" (Some "add") (Meta.name meta)
  | _ -> Alcotest.fail "free `add` should resolve to a term ref"

let test_con_and_op_refs () =
  let e = expr_of_top (resolve_ok "(app (var some) (var abort))") in
  match e.Kernel.it with
  | Kernel.App
      ( { Kernel.it = Kernel.Ref (_, Kernel.Con); _ },
        [ { Kernel.it = Kernel.Ref (_, Kernel.Op); _ } ] ) ->
      ()
  | _ -> Alcotest.fail "constructor and op names should resolve with their kinds"

(* --- shadowing --- *)

let test_inner_let_shadows_outer () =
  (* both x's are local; the inner body's (var x) must stay a Var, not resolve
     to any global, and the structure keeps both binders *)
  let e =
    expr_of_top
      (resolve_ok "(let nonrec (pvar add) (lit 1) (let nonrec (pvar add) (lit 2) (var add)))")
  in
  match e.Kernel.it with
  | Kernel.Let { body = { Kernel.it = Kernel.Let { body; _ }; _ }; _ } -> (
      match body.Kernel.it with
      | Kernel.Var "add" -> ()
      | _ -> Alcotest.fail "local `add` must shadow the global term and stay a Var")
  | _ -> Alcotest.fail "unexpected shape"

let test_lam_param_shadows_global () =
  let e = expr_of_top (resolve_ok "(lam ((pvar add)) (app (var add) (lit 1)))") in
  match e.Kernel.it with
  | Kernel.Lam (_, { Kernel.it = Kernel.App ({ Kernel.it = Kernel.Var "add"; _ }, _); _ }) -> ()
  | _ -> Alcotest.fail "lam param must shadow global"

let test_pattern_binds_in_clause_body_only () =
  (* `m` is bound in the second clause's body; using it in a sibling clause fails *)
  let _ = resolve_ok "(match (lit 1) (clause (pvar m) (var m)) (clause (pwild) (lit 0)))" in
  let ds = resolve_err "(match (lit 1) (clause (pvar m) (lit 0)) (clause (pwild) (var m)))" in
  match ds with
  | [ d ] -> Alcotest.(check string) "unknown m" "E0301" d.Diag.code
  | _ -> Alcotest.fail "expected one diagnostic"

let test_let_nonrec_value_no_self () =
  let ds = resolve_err "(let nonrec (pvar x) (var x) (lit 1))" in
  match ds with
  | [ d ] -> Alcotest.(check string) "nonrec value can't see binder" "E0301" d.Diag.code
  | _ -> Alcotest.fail "expected one diagnostic"

let test_resume_bound_in_opclause () =
  let e =
    expr_of_top
      (resolve_ok
         "(handle (app (var div) (lit 1) (lit 0)) (ret (pvar x) (var x)) (opclause abort () k (app \
          (var k) (lit 0))))")
  in
  match e.Kernel.it with
  | Kernel.Handle { ops = [ { Kernel.obody; op = Kernel.Hashed _; _ } ]; _ } -> (
      match obody.Kernel.it with
      | Kernel.App ({ Kernel.it = Kernel.Var "k"; _ }, _) -> ()
      | _ -> Alcotest.fail "resume name must stay a local Var in the op clause body")
  | _ -> Alcotest.fail "unexpected shape"

(* --- defterm groups --- *)

let test_group_self_reference () =
  let d =
    match resolve_ok "(defterm ((binding fact () (lam ((pvar n)) (app (var fact) (var n))))))" with
    | Kernel.Decl d -> d
    | _ -> Alcotest.fail "expected a decl"
  in
  match d.Kernel.it with
  | Kernel.DefTerm [ { Kernel.value = { Kernel.it = Kernel.Lam (_, body); _ }; _ } ] -> (
      match body.Kernel.it with
      | Kernel.App ({ Kernel.it = Kernel.GroupRef 0; meta }, _) ->
          Alcotest.(check (option string)) "name retained" (Some "fact") (Meta.name meta)
      | _ -> Alcotest.fail "self-reference must resolve to GroupRef 0, not a hash")
  | _ -> Alcotest.fail "unexpected shape"

let test_group_mutual_references () =
  let d =
    match
      resolve_ok
        "(defterm ((binding even () (lam ((pvar n)) (app (var odd) (var n)))) (binding odd () (lam \
         ((pvar n)) (app (var even) (var n))))))"
    with
    | Kernel.Decl d -> d
    | _ -> Alcotest.fail "expected a decl"
  in
  match d.Kernel.it with
  | Kernel.DefTerm [ { Kernel.value = v_even; _ }; { Kernel.value = v_odd; _ } ] ->
      let target v =
        match v.Kernel.it with
        | Kernel.Lam (_, { Kernel.it = Kernel.App ({ Kernel.it = Kernel.GroupRef i; _ }, _); _ }) ->
            i
        | _ -> Alcotest.fail "expected (lam _ (app (groupref i) _))"
      in
      Alcotest.(check int) "even calls odd (index 1)" 1 (target v_even);
      Alcotest.(check int) "odd calls even (index 0)" 0 (target v_odd)
  | _ -> Alcotest.fail "unexpected shape"

let test_duplicate_group_binding () =
  let ds = resolve_err "(defterm ((binding f () (lit 1)) (binding f () (lit 2))))" in
  Alcotest.(check bool) "E0303 reported" true (List.exists (fun d -> d.Diag.code = "E0303") ds)

(* --- unknown names and suggestions --- *)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  go 0

let test_unknown_with_suggestion () =
  let ds = resolve_err "(app (var ad) (lit 1))" in
  match ds with
  | [ d ] ->
      Alcotest.(check string) "code" "E0301" d.Diag.code;
      let hint = Option.value ~default:"" d.Diag.hint in
      Alcotest.(check bool)
        (Printf.sprintf "hint %S mentions add" hint)
        true (contains ~needle:"add" hint)
  | _ -> Alcotest.fail "expected one diagnostic"

let test_unknown_no_near_miss () =
  let ds = resolve_err "(app (var zzzzzzz) (lit 1))" in
  match ds with
  | [ d ] -> Alcotest.(check (option string)) "no hint" None d.Diag.hint
  | _ -> Alcotest.fail "expected one diagnostic"

let test_multiple_unknowns_all_reported () =
  let ds = resolve_err "(app (var nope1) (var nope2))" in
  Alcotest.(check int) "two diagnostics" 2 (List.length ds)

(* --- kinds --- *)

let test_kind_mismatch () =
  let ds = resolve_err "(app (var int) (lit 1))" in
  (match ds with
  | [ d ] -> Alcotest.(check string) "type used as value" "E0302" d.Diag.code
  | _ -> Alcotest.fail "expected one diagnostic");
  let ds = resolve_err "(match (lit 1) (clause (pcon add) (lit 0)))" in
  (match ds with
  | [ d ] -> Alcotest.(check string) "term used as constructor" "E0302" d.Diag.code
  | _ -> Alcotest.fail "expected one diagnostic");
  let ds = resolve_err "(ann (lit 1) (tref add))" in
  match ds with
  | [ d ] -> Alcotest.(check string) "term used as type" "E0302" d.Diag.code
  | _ -> Alcotest.fail "expected one diagnostic"

let test_types_and_rows_resolve () =
  let e =
    expr_of_top (resolve_ok "(ann (var add) (tarrow ((tref int)) (row (eref console)) (tref int)))")
  in
  match e.Kernel.it with
  | Kernel.Ann
      ( _,
        {
          Kernel.it =
            Kernel.TArrow
              ( [ { Kernel.it = Kernel.TRef (Kernel.Hashed _); _ } ],
                { Kernel.effects = [ Kernel.Hashed _ ]; _ },
                _ );
          _;
        } ) ->
      ()
  | _ -> Alcotest.fail "tref/eref names should resolve to hashes"

(* --- quote --- *)

let test_quote_payload_untouched_but_splices_resolve () =
  let e = expr_of_top (resolve_ok "(quote (app (var add) (unquote (app (var add) (lit 1)))))") in
  match e.Kernel.it with
  | Kernel.Quote payload -> (
      (* the (var add) inside the quote stays a var form... *)
      match payload.Form.args with
      | [ Form.F { Form.head = "var"; args = [ Form.Sym "add" ]; _ }; Form.F unq ] -> (
          (* ...but the unquote splice resolved to a ref form *)
          match unq.Form.args with
          | [ Form.F { Form.head = "app"; args = Form.F { Form.head = "ref"; _ } :: _; _ } ] -> ()
          | _ -> Alcotest.fail "unquote splice should resolve")
      | _ -> Alcotest.fail "quoted data outside unquote must stay unresolved")
  | _ -> Alcotest.fail "expected a quote"

let test_duplicate_pattern_var () =
  let ds = resolve_err "(match (lit 1) (clause (ptuple (pvar x) (pvar x)) (var x)))" in
  Alcotest.(check bool) "E0304 reported" true (List.exists (fun d -> d.Diag.code = "E0304") ds);
  (* duplicates across sibling binders of one construct are rejected too *)
  let ds = resolve_err "(lam ((pvar x) (pvar x)) (var x))" in
  Alcotest.(check bool)
    "duplicate lam params" true
    (List.exists (fun d -> d.Diag.code = "E0304") ds);
  let ds =
    resolve_err
      "(handle (lit 1) (ret (pvar x) (var x)) (opclause abort ((pvar k)) k (app (var k))))"
  in
  Alcotest.(check bool)
    "resume duplicating a param" true
    (List.exists (fun d -> d.Diag.code = "E0304") ds)

let test_group_member_shadows_global () =
  (* `add` is a stub global term; a group member of the same name wins *)
  let d =
    match resolve_ok "(defterm ((binding add () (lam ((pvar n)) (app (var add) (var n))))))" with
    | Kernel.Decl d -> d
    | _ -> Alcotest.fail "expected a decl"
  in
  match d.Kernel.it with
  | Kernel.DefTerm [ { Kernel.value = { Kernel.it = Kernel.Lam (_, body); _ }; _ } ] -> (
      match body.Kernel.it with
      | Kernel.App ({ Kernel.it = Kernel.GroupRef 0; _ }, _) -> ()
      | _ -> Alcotest.fail "group member must shadow the global of the same name")
  | _ -> Alcotest.fail "unexpected shape"

let test_local_shadows_group_member () =
  let d =
    match resolve_ok "(defterm ((binding f () (lam ((pvar f)) (app (var f) (lit 1))))))" with
    | Kernel.Decl d -> d
    | _ -> Alcotest.fail "expected a decl"
  in
  match d.Kernel.it with
  | Kernel.DefTerm [ { Kernel.value = { Kernel.it = Kernel.Lam (_, body); _ }; _ } ] -> (
      match body.Kernel.it with
      | Kernel.App ({ Kernel.it = Kernel.Var "f"; _ }, _) -> ()
      | _ -> Alcotest.fail "local must shadow the group member of the same name")
  | _ -> Alcotest.fail "unexpected shape"

let test_nested_quote_splices_stay_data () =
  let e = expr_of_top (resolve_ok "(quote (quote (unquote (var add))))") in
  match e.Kernel.it with
  | Kernel.Quote payload -> (
      (* the inner quote's unquote belongs to the inner quote: (var add) stays a name *)
      match payload.Form.args with
      | [ Form.F { Form.head = "unquote"; args = [ Form.F { Form.head = "var"; _ } ]; _ } ] -> ()
      | _ -> Alcotest.fail "splice under a nested quote must stay unresolved data")
  | _ -> Alcotest.fail "expected a quote"

let suite =
  [
    Alcotest.test_case "free name becomes term ref with name meta" `Quick test_free_name_becomes_ref;
    Alcotest.test_case "constructor and op kinds" `Quick test_con_and_op_refs;
    Alcotest.test_case "inner let shadows outer" `Quick test_inner_let_shadows_outer;
    Alcotest.test_case "lam param shadows global" `Quick test_lam_param_shadows_global;
    Alcotest.test_case "pattern binds in clause body only" `Quick
      test_pattern_binds_in_clause_body_only;
    Alcotest.test_case "nonrec value cannot see binder" `Quick test_let_nonrec_value_no_self;
    Alcotest.test_case "resume bound in op clause" `Quick test_resume_bound_in_opclause;
    Alcotest.test_case "group self-reference is GroupRef" `Quick test_group_self_reference;
    Alcotest.test_case "group mutual references" `Quick test_group_mutual_references;
    Alcotest.test_case "duplicate group binding" `Quick test_duplicate_group_binding;
    Alcotest.test_case "unknown name suggests near miss" `Quick test_unknown_with_suggestion;
    Alcotest.test_case "unknown name without near miss" `Quick test_unknown_no_near_miss;
    Alcotest.test_case "multiple unknowns all reported" `Quick test_multiple_unknowns_all_reported;
    Alcotest.test_case "kind mismatches" `Quick test_kind_mismatch;
    Alcotest.test_case "types and rows resolve" `Quick test_types_and_rows_resolve;
    Alcotest.test_case "quote data untouched, splices resolve" `Quick
      test_quote_payload_untouched_but_splices_resolve;
    Alcotest.test_case "duplicate pattern variable" `Quick test_duplicate_pattern_var;
    Alcotest.test_case "group member shadows global" `Quick test_group_member_shadows_global;
    Alcotest.test_case "local shadows group member" `Quick test_local_shadows_group_member;
    Alcotest.test_case "nested quote splices stay data" `Quick test_nested_quote_splices_stay_data;
  ]
