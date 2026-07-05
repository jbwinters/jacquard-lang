open Jacquard

let span1 =
  Span.make ~file:"t.wft"
    ~start_pos:{ Span.line = 1; col = 1; offset = 0 }
    ~end_pos:{ Span.line = 1; col = 8; offset = 7 }

(* (app (var add) (lit 1) (lit 2)) with meta only on some nodes *)
let sample =
  Form.form ~meta:(Meta.with_span span1 Meta.empty) "app"
    [
      Form.F (Form.form "var" [ Form.Sym "add" ]);
      Form.F (Form.form "lit" [ Form.Int 1 ]);
      Form.F (Form.form "lit" [ Form.Int 2 ]);
    ]

let test_construct_and_inspect () =
  Alcotest.(check string) "head" "app" sample.Form.head;
  Alcotest.(check int) "arity" 3 (List.length sample.Form.args);
  (match sample.Form.args with
  | Form.F { Form.head = "var"; args = [ Form.Sym "add" ]; _ } :: _ -> ()
  | _ -> Alcotest.fail "first arg should be (var add)");
  Alcotest.(check bool) "span read back" true (Form.span sample = Some span1)

let test_meta_accessors () =
  let m = Meta.empty |> Meta.with_span span1 |> Meta.with_name "add" in
  Alcotest.(check (option string)) "name" (Some "add") (Meta.name m);
  Alcotest.(check bool) "span" true (Meta.span m = Some span1);
  Alcotest.(check bool) "empty has no span" true (Meta.span Meta.empty = None);
  let m' = Meta.remove "span" m in
  Alcotest.(check bool) "removed span" true (Meta.span m' = None)

let test_equal_ignoring_meta_basic () =
  let bare = Form.form "app" sample.Form.args in
  Alcotest.(check bool) "meta ignored at root" true (Form.equal_ignoring_meta sample bare);
  let different = Form.form "app" [ Form.F (Form.form "lit" [ Form.Int 1 ]) ] in
  Alcotest.(check bool) "different args differ" false (Form.equal_ignoring_meta sample different);
  let renamed = Form.form "lam" sample.Form.args in
  Alcotest.(check bool) "different head differs" false (Form.equal_ignoring_meta sample renamed)

let test_scalar_leaves_compared () =
  let f x = Form.form "lit" [ Form.Real x ] in
  Alcotest.(check bool) "nan = nan" true (Form.equal_ignoring_meta (f nan) (f nan));
  Alcotest.(check bool) "1.0 <> 2.0" false (Form.equal_ignoring_meta (f 1.0) (f 2.0));
  let h1 = Hash.of_string "a" and h2 = Hash.of_string "b" in
  let g h = Form.form "ref" [ Form.Hash h; Form.Sym "term" ] in
  Alcotest.(check bool) "same hash" true (Form.equal_ignoring_meta (g h1) (g h1));
  Alcotest.(check bool) "different hash" false (Form.equal_ignoring_meta (g h1) (g h2));
  Alcotest.(check bool)
    "text vs sym differ" false
    (Form.equal_ignoring_meta
       (Form.form "lit" [ Form.Text "x" ])
       (Form.form "lit" [ Form.Sym "x" ]))

(* --- QCheck: random meta perturbation never affects equal_ignoring_meta --- *)

let gen_ident = QCheck.Gen.(oneof_list [ "x"; "y"; "add"; "fact"; "m"; "n" ])
let gen_head = QCheck.Gen.(oneof_list [ "app"; "lam"; "lit"; "var"; "tuple"; "match" ])

let gen_form : Form.t QCheck.Gen.t =
  let open QCheck.Gen in
  sized
  @@ fix (fun self n ->
      let scalar =
        oneof
          [
            map (fun i -> Form.Int i) int_small;
            map (fun r -> Form.Real r) float;
            map (fun s -> Form.Text s) string_small;
            map (fun s -> Form.Sym s) gen_ident;
            map (fun s -> Form.Hash (Hash.of_string s)) string_small;
          ]
      in
      let arg =
        if n = 0 then scalar else oneof [ scalar; map (fun f -> Form.F f) (self (n / 4)) ]
      in
      map2 (fun head args -> Form.form head args) gen_head (list_size (int_bound 4) arg))

let gen_meta_value : Meta.value QCheck.Gen.t =
  let open QCheck.Gen in
  sized
  @@ fix (fun self n ->
      let leaf =
        oneof
          [
            map (fun s -> Meta.Sym s) gen_ident;
            map (fun s -> Meta.Text s) string_small;
            return (Meta.Span span1);
          ]
      in
      if n = 0 then leaf
      else
        oneof
          [
            leaf;
            map (fun vs -> Meta.List vs) (list_size (int_bound 3) (self (n / 4)));
            map (fun kvs -> Meta.Map kvs) (list_size (int_bound 3) (pair gen_ident (self (n / 4))));
          ])

(* Rewrite every node's meta with random noise: add reserved and unreserved
   keys, sometimes drop everything that was there. *)
let rec perturb_meta rand (f : Form.t) : Form.t =
  let noise_key =
    QCheck.Gen.(generate1 ~rand (oneof_list [ "span"; "name"; "doc"; "origin"; "x-custom" ]))
  in
  let v = QCheck.Gen.generate1 ~rand gen_meta_value in
  let base = if QCheck.Gen.(generate1 ~rand bool) then Meta.empty else f.Form.meta in
  let meta = Meta.add noise_key v base in
  {
    f with
    Form.meta;
    args = List.map (function Form.F g -> Form.F (perturb_meta rand g) | a -> a) f.Form.args;
  }

let prop_meta_never_affects_equality =
  QCheck.Test.make ~count:500 ~name:"meta perturbation never affects equal_ignoring_meta"
    (QCheck.make gen_form ~print:Form.to_string) (fun f ->
      let rand = Random.State.make [| 42; Hashtbl.hash (Form.to_string f) |] in
      Form.equal_ignoring_meta f (perturb_meta rand f))

let prop_equal_reflexive =
  QCheck.Test.make ~count:200 ~name:"equal_ignoring_meta reflexive"
    (QCheck.make gen_form ~print:Form.to_string) (fun f -> Form.equal_ignoring_meta f f)

let suite =
  [
    Alcotest.test_case "construct and inspect nested forms" `Quick test_construct_and_inspect;
    Alcotest.test_case "meta accessors" `Quick test_meta_accessors;
    Alcotest.test_case "equal_ignoring_meta basics" `Quick test_equal_ignoring_meta_basic;
    Alcotest.test_case "scalar leaf comparison" `Quick test_scalar_leaves_compared;
    QCheck_alcotest.to_alcotest prop_meta_never_affects_equality;
    QCheck_alcotest.to_alcotest prop_equal_reflexive;
  ]
