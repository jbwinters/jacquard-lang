open Jacquard

let valid_dir = "../corpus/valid"
let golden_file = "../corpus/golden/hashes.golden"

let pipeline_ok ~what src =
  match Corpus_support.pipeline ~file:what src with
  | Ok hs -> hs
  | Error ds ->
      Alcotest.failf "%s: pipeline failed: %s" what
        (String.concat "; " (List.map Diag.to_string ds))

let resolved_tops ~what src =
  match Reader.parse_string ~file:what src with
  | Error _ -> Alcotest.failf "%s: parse failed" what
  | Ok forms ->
      List.map
        (fun f ->
          match Kernel.of_form f with
          | Error _ -> Alcotest.failf "%s: validation failed" what
          | Ok top -> (
              match Resolve.resolve Corpus_support.stub_names top with
              | Error ds ->
                  Alcotest.failf "%s: resolution failed: %s" what
                    (String.concat "; " (List.map Diag.to_string ds))
              | Ok t -> t))
        forms

let hash_of_top ~what t =
  match Canon.hash_top t with
  | Ok h -> h
  | Error ds ->
      Alcotest.failf "%s: hashing failed: %s" what (String.concat "; " (List.map Diag.to_string ds))

(* --- golden hashes for the whole corpus; CI fails on drift --- *)

let test_golden_corpus_hashes () =
  let expected =
    Corpus_support.read_file golden_file
    |> String.split_on_char '\n'
    |> List.filter (fun l -> l <> "")
  in
  let actual = Corpus_support.corpus_golden_lines ~valid_dir in
  Alcotest.(check (list string))
    "corpus hashes match corpus/golden/hashes.golden (regenerate with `dune exec \
     test/gen_goldens.exe` and review the diff)"
    expected actual

(* --- alpha-renaming locals never changes a hash --- *)

(* After resolution every remaining Var is local, so an injective rename of all binder names
   and Var occurrences preserves binding structure. Quote payloads are data and must NOT be
   renamed, except inside unquote splices (which are expressions). *)
let rec rename_pat f (p : Kernel.pat) =
  let it =
    match p.Kernel.it with
    | (Kernel.PWild | Kernel.PLit _) as it -> it
    | Kernel.PVar x -> Kernel.PVar (f x)
    | Kernel.PCon (c, ps) -> Kernel.PCon (c, List.map (rename_pat f) ps)
    | Kernel.PTuple ps -> Kernel.PTuple (List.map (rename_pat f) ps)
    | Kernel.PAs (x, inner) -> Kernel.PAs (f x, rename_pat f inner)
  in
  { p with Kernel.it }

let rec rename_expr f (e : Kernel.expr) =
  let it =
    match e.Kernel.it with
    | (Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _) as it -> it
    | Kernel.Var x -> Kernel.Var (f x)
    | Kernel.Lam (ps, body) -> Kernel.Lam (List.map (rename_pat f) ps, rename_expr f body)
    | Kernel.App (fn, args) -> Kernel.App (rename_expr f fn, List.map (rename_expr f) args)
    | Kernel.Let { isrec; binder; value; body } ->
        Kernel.Let
          {
            isrec;
            binder = rename_pat f binder;
            value = rename_expr f value;
            body = rename_expr f body;
          }
    | Kernel.Match (s, cs) ->
        Kernel.Match
          ( rename_expr f s,
            List.map
              (fun c ->
                {
                  c with
                  Kernel.cpat = rename_pat f c.Kernel.cpat;
                  cbody = rename_expr f c.Kernel.cbody;
                })
              cs )
    | Kernel.Tuple items -> Kernel.Tuple (List.map (rename_expr f) items)
    | Kernel.Handle { body; ret; ops } ->
        Kernel.Handle
          {
            body = rename_expr f body;
            ret =
              {
                ret with
                Kernel.rbinder = rename_pat f ret.Kernel.rbinder;
                rbody = rename_expr f ret.Kernel.rbody;
              };
            ops =
              List.map
                (fun o ->
                  {
                    o with
                    Kernel.params = List.map (rename_pat f) o.Kernel.params;
                    resume = f o.Kernel.resume;
                    obody = rename_expr f o.Kernel.obody;
                  })
                ops;
          }
    | Kernel.Quote payload -> Kernel.Quote (rename_quoted f payload)
    | Kernel.Unquote s -> Kernel.Unquote (rename_expr f s)
    | Kernel.Ann (s, t) -> Kernel.Ann (rename_expr f s, t)
  in
  { e with Kernel.it }

and rename_quoted ?(level = 0) f (form : Form.t) =
  (* mirror canon's quasiquote levels: only live splices are expressions to rename *)
  if form.Form.head = "unquote" && level = 0 then
    match form.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok e -> { form with Form.args = [ Form.F (Kernel.expr_to_form (rename_expr f e)) ] }
        | Error _ -> form)
    | _ -> form
  else
    let level =
      match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    {
      form with
      Form.args =
        List.map (function Form.F g -> Form.F (rename_quoted ~level f g) | a -> a) form.Form.args;
    }

let rename_top f = function
  | Kernel.Expr e -> Kernel.Expr (rename_expr f e)
  | Kernel.Decl d ->
      Kernel.Decl
        (match d.Kernel.it with
        | Kernel.DefTerm bs ->
            {
              d with
              Kernel.it =
                Kernel.DefTerm
                  (List.map (fun b -> { b with Kernel.value = rename_expr f b.Kernel.value }) bs);
            }
        | _ -> d)

let corpus_tops () =
  List.concat_map
    (fun file ->
      resolved_tops ~what:file (Corpus_support.read_file (Filename.concat valid_dir file)))
    (Corpus_support.jqd_files valid_dir)

let prop_alpha_renaming =
  QCheck.Test.make ~count:50 ~name:"alpha-renaming locals never changes a hash"
    QCheck.(make Gen.(oneof_list [ "-r"; "z"; "-x9"; "q-q"; "renamed" ]))
    (fun suffix ->
      let f x = x ^ suffix in
      List.for_all
        (fun top ->
          Hash.equal (hash_of_top ~what:"orig" top).Canon.decl_hash
            (hash_of_top ~what:"renamed" (rename_top f top)).Canon.decl_hash)
        (corpus_tops ()))

(* --- meta mutation never changes a hash --- *)

let test_meta_mutation_never_changes_hash () =
  List.iter
    (fun file ->
      let src = Corpus_support.read_file (Filename.concat valid_dir file) in
      match Reader.parse_string ~file src with
      | Error _ -> Alcotest.failf "%s: parse failed" file
      | Ok forms ->
          let rand = Random.State.make [| 7; Hashtbl.hash file |] in
          let hash_forms fs =
            List.map
              (fun f ->
                match Kernel.of_form f with
                | Error _ -> Alcotest.failf "%s: validation failed" file
                | Ok top -> (
                    match Resolve.resolve Corpus_support.stub_names top with
                    | Error _ -> Alcotest.failf "%s: resolution failed" file
                    | Ok t -> (hash_of_top ~what:file t).Canon.decl_hash))
              fs
          in
          let original = hash_forms forms in
          let perturbed = hash_forms (List.map (Test_form.perturb_meta rand) forms) in
          List.iter2
            (fun a b ->
              Alcotest.(check bool)
                (Printf.sprintf "%s: meta perturbation preserved hash" file)
                true (Hash.equal a b))
            original perturbed)
    (Corpus_support.jqd_files valid_dir)

(* --- group order: permuting members never changes the group hash --- *)

let cycle_members =
  [
    ("a", "(binding a () (lam ((pvar n)) (app (var b) (var n))))");
    ("b", "(binding b () (lam ((pvar n)) (app (var c) (lit 1))))");
    ("c", "(binding c () (lam ((pvar n)) (app (var a) (var n) (lit 2))))");
  ]

let rec permutations = function
  | [] -> [ [] ]
  | l ->
      List.concat_map
        (fun x -> List.map (fun p -> x :: p) (permutations (List.filter (( <> ) x) l)))
        l

let test_group_permutation_invariance () =
  let hash_of_order order =
    let src = "(defterm (" ^ String.concat " " (List.map (fun (_, b) -> b) order) ^ "))" in
    match resolved_tops ~what:"cycle" src with
    | [ top ] ->
        let { Canon.decl_hash; named } = hash_of_top ~what:"cycle" top in
        (decl_hash, List.sort compare (List.map (fun (n, h) -> (n, Hash.to_hex h)) named))
    | _ -> Alcotest.fail "expected one decl"
  in
  let reference = hash_of_order cycle_members in
  List.iteri
    (fun i order ->
      let this = hash_of_order order in
      Alcotest.(check bool)
        (Printf.sprintf "permutation %d: group hash invariant" i)
        true
        (Hash.equal (fst reference) (fst this));
      Alcotest.(check (list (pair string string)))
        (Printf.sprintf "permutation %d: member hashes invariant" i)
        (snd reference) (snd this))
    (permutations cycle_members)

(* Identical-body twins referenced asymmetrically: rank refinement cannot separate u and v
   (identical bodies, out-references only), so ordering must fall back to the byte-least
   candidate. This was the review counterexample for the source-order leak. *)
let twin_members =
  [
    ("u", "(binding u () (lit 0))");
    ("v", "(binding v () (lit 0))");
    ("w1", "(binding w1 () (app (var u) (lit 1)))");
    ("w2", "(binding w2 () (app (var v) (lit 2)))");
  ]

let hash_group_of_order order =
  let src = "(defterm (" ^ String.concat " " (List.map snd order) ^ "))" in
  match resolved_tops ~what:"group" src with
  | [ top ] ->
      let { Canon.decl_hash; named } = hash_of_top ~what:"group" top in
      (decl_hash, List.sort compare (List.map (fun (n, h) -> (n, Hash.to_hex h)) named))
  | _ -> Alcotest.fail "expected one decl"

let test_asymmetric_twin_permutation_invariance () =
  let reference = hash_group_of_order twin_members in
  List.iteri
    (fun i order ->
      let this = hash_group_of_order order in
      Alcotest.(check bool)
        (Printf.sprintf "twin permutation %d: group hash invariant" i)
        true
        (Hash.equal (fst reference) (fst this));
      Alcotest.(check (list (pair string string)))
        (Printf.sprintf "twin permutation %d: member hashes invariant" i)
        (snd reference) (snd this))
    (permutations twin_members)

let take n l = List.filteri (fun i _ -> i < n) l

(* Random small groups: hashing must be invariant under a random source permutation. *)
let gen_group : (string * string) list QCheck.Gen.t =
  let open QCheck.Gen in
  let member_names = [ "m0"; "m1"; "m2"; "m3" ] in
  int_range 2 4 >>= fun n ->
  let names = take n member_names in
  let body =
    oneof
      [
        return "(lit 0)";
        return "(lit 1)";
        ( oneof_list names >>= fun t1 ->
          oneof_list names >|= fun t2 ->
          Printf.sprintf "(tuple (app (var %s)) (app (var %s)))" t1 t2 );
        (oneof_list names >|= fun t -> Printf.sprintf "(app (var %s) (lit 2))" t);
      ]
  in
  flatten_list
    (List.map
       (fun name -> body >|= fun b -> (name, Printf.sprintf "(binding %s () %s)" name b))
       names)

let prop_random_group_permutation_invariant =
  QCheck.Test.make ~count:150 ~name:"random group hashing is source-order-invariant"
    (QCheck.make
       QCheck.Gen.(
         gen_group >>= fun members ->
         shuffle_list members >|= fun shuffled -> (members, shuffled))
       ~print:(fun (a, _) -> String.concat " " (List.map snd a)))
    (fun (members, shuffled) ->
      let a = hash_group_of_order members and b = hash_group_of_order shuffled in
      Hash.equal (fst a) (fst b) && snd a = snd b)

(* --- alpha-equivalent factorials hash equal (explicit test) --- *)

let fact_a =
  "(defterm ((binding fact ()\n\
  \  (lam ((pvar n))\n\
  \    (match (var n)\n\
  \      (clause (plit 0) (lit 1))\n\
  \      (clause (pvar m)\n\
  \        (app (var mul) (var m)\n\
  \          (app (var fact) (app (var sub) (var m) (lit 1))))))))))"

(* different binding name, different locals, different formatting; same term *)
let fact_b =
  "(defterm ((binding factorial () (lam ((pvar num)) (match (var num) (clause (plit 0) (lit 1)) \
   (clause (pvar k) (app (var mul) (var k) (app (var factorial) (app (var sub) (var k) (lit \
   1))))))))))"

let test_alpha_equivalent_factorials () =
  let hash src =
    match resolved_tops ~what:"fact" src with
    | [ top ] -> hash_of_top ~what:"fact" top
    | _ -> Alcotest.fail "expected one decl"
  in
  let a = hash fact_a and b = hash fact_b in
  Alcotest.(check bool) "group hashes equal" true (Hash.equal a.Canon.decl_hash b.Canon.decl_hash);
  let member (h : Canon.decl_hashes) = snd (List.hd h.Canon.named) in
  Alcotest.(check bool) "member hashes equal" true (Hash.equal (member a) (member b));
  (* negative control: a one-literal edit changes the hash *)
  let c =
    hash
      "(defterm ((binding fact () (lam ((pvar n)) (match (var n) (clause (plit 0) (lit 2)) (clause \
       (pvar m) (app (var mul) (var m) (app (var fact) (app (var sub) (var m) (lit 1))))))))))"
  in
  Alcotest.(check bool)
    "literal edit changes hash" false
    (Hash.equal a.Canon.decl_hash c.Canon.decl_hash)

(* --- assorted invariants --- *)

let test_row_order_insensitive () =
  let hash src =
    match resolved_tops ~what:"row" src with
    | [ top ] -> (hash_of_top ~what:"row" top).Canon.decl_hash
    | _ -> Alcotest.fail "expected one expr"
  in
  Alcotest.(check bool)
    "row effect order ignored" true
    (Hash.equal
       (hash "(ann (var add) (tarrow ((tref int)) (row (eref console) (eref net)) (tref int)))")
       (hash "(ann (var add) (tarrow ((tref int)) (row (eref net) (eref console)) (tref int)))"))

let test_derived_hashes_distinct () =
  let d = Hash.of_string "some-decl" in
  Alcotest.(check bool)
    "con ordinals differ" false
    (Hash.equal (Canon.con_hash d 0) (Canon.con_hash d 1));
  Alcotest.(check bool)
    "con and op domains differ" false
    (Hash.equal (Canon.con_hash d 0) (Canon.op_hash d 0))

(* the internal groupref marker only hashes inside a defterm group, in range *)
let test_groupref_gated () =
  let top s =
    match Kernel.of_form (Result.get_ok (Reader.parse_one ~file:"g.jqd" s)) with
    | Ok t -> t
    | Error _ -> Alcotest.fail "validation failed"
  in
  (match Canon.hash_top (top "(groupref 0)") with
  | Error [ d ] -> Alcotest.(check string) "outside group" "E0503" d.Diag.code
  | _ -> Alcotest.fail "bare groupref must not hash");
  (match Canon.hash_top (top "(app (groupref 7) (lit 1))") with
  | Error [ d ] -> Alcotest.(check string) "nested outside group" "E0503" d.Diag.code
  | _ -> Alcotest.fail "nested bare groupref must not hash");
  match Canon.hash_top (top "(defterm ((binding f () (groupref 5))))") with
  | Error [ d ] -> Alcotest.(check string) "out of range" "E0503" d.Diag.code
  | _ -> Alcotest.fail "out-of-range groupref must not hash"

let test_unresolved_rejected () =
  let top s =
    match Kernel.of_form (Result.get_ok (Reader.parse_one ~file:"u.jqd" s)) with
    | Ok t -> t
    | Error _ -> Alcotest.fail "validation failed"
  in
  (match Canon.hash_top (top "(app (var free-name) (lit 1))") with
  | Error [ d ] -> Alcotest.(check string) "free var" "E0502" d.Diag.code
  | _ -> Alcotest.fail "unresolved var must be rejected");
  match Canon.hash_top (top "(match (lit 1) (clause (pcon true) (lit 0)))") with
  | Error [ d ] -> Alcotest.(check string) "named con" "E0501" d.Diag.code
  | _ -> Alcotest.fail "unresolved constructor must be rejected"

let suite =
  [
    Alcotest.test_case "golden corpus hashes" `Quick test_golden_corpus_hashes;
    QCheck_alcotest.to_alcotest prop_alpha_renaming;
    Alcotest.test_case "meta mutation never changes hash" `Quick
      test_meta_mutation_never_changes_hash;
    Alcotest.test_case "group permutation invariance (3-cycle)" `Quick
      test_group_permutation_invariance;
    Alcotest.test_case "asymmetric twin permutation invariance" `Quick
      test_asymmetric_twin_permutation_invariance;
    QCheck_alcotest.to_alcotest prop_random_group_permutation_invariant;
    Alcotest.test_case "alpha-equivalent factorials" `Quick test_alpha_equivalent_factorials;
    Alcotest.test_case "row order insensitive" `Quick test_row_order_insensitive;
    Alcotest.test_case "derived hashes distinct" `Quick test_derived_hashes_distinct;
    Alcotest.test_case "groupref gated at hashing" `Quick test_groupref_gated;
    Alcotest.test_case "unresolved trees rejected" `Quick test_unresolved_rejected;
  ]
