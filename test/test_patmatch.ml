open Jacquard

(* W2.3: match_pat over every pattern form, match and no-match (table-driven), plus one
   deep nesting test. Patterns are built directly as resolved kernel ASTs. *)

let node it = { Kernel.it; meta = Meta.empty }
let pwild = node Kernel.PWild
let pvar x = node (Kernel.PVar x)
let plit l = node (Kernel.PLit l)
let pcon h ps = node (Kernel.PCon (Kernel.Hashed h, ps))
let ptuple ps = node (Kernel.PTuple ps)
let pas x p = node (Kernel.PAs (x, p))
let matches v p = match Eval.match_pat v p Value.Env.empty with Some _ -> true | None -> false

let binding_of v p x =
  match Eval.match_pat v p Value.Env.empty with
  | Some env -> Option.map (fun cell -> !cell) (Value.Env.find_opt x env)
  | None -> None

let test_table () =
  let h = Eval_support.make () in
  let tc = h.Eval_support.true_con and fc = h.Eval_support.false_con in
  let sc = h.Eval_support.some_con in
  let vtrue = Value.VCon { con = tc; name = "true"; args = [] } in
  let vfalse = Value.VCon { con = fc; name = "false"; args = [] } in
  let vsome v = Value.VCon { con = sc; name = "some"; args = [ v ] } in
  let cases =
    [
      (* name, value, pattern, expected *)
      ("pwild/int", Value.VInt 1, pwild, true);
      ("pwild/con", vtrue, pwild, true);
      ("pvar/any", Value.VText "s", pvar "x", true);
      ("plit int yes", Value.VInt 3, plit (Kernel.LInt 3), true);
      ("plit int no", Value.VInt 4, plit (Kernel.LInt 3), false);
      ("plit int vs text", Value.VText "3", plit (Kernel.LInt 3), false);
      ("plit real yes", Value.VReal 2.5, plit (Kernel.LReal 2.5), true);
      ("plit real nan", Value.VReal nan, plit (Kernel.LReal nan), true);
      ("plit real negzero", Value.VReal (-0.0), plit (Kernel.LReal 0.0), true);
      ("plit text yes", Value.VText "a", plit (Kernel.LText "a"), true);
      ("plit text no", Value.VText "b", plit (Kernel.LText "a"), false);
      ("pcon nullary yes", vtrue, pcon tc [], true);
      ("pcon nullary wrong con", vfalse, pcon tc [], false);
      ("pcon wrong value", Value.VInt 0, pcon tc [], false);
      ("pcon arg yes", vsome (Value.VInt 1), pcon sc [ plit (Kernel.LInt 1) ], true);
      ("pcon arg no", vsome (Value.VInt 2), pcon sc [ plit (Kernel.LInt 1) ], false);
      ("pcon arity mismatch", vsome (Value.VInt 1), pcon sc [], false);
      ( "ptuple yes",
        Value.VTuple [ Value.VInt 1; Value.VInt 2 ],
        ptuple [ pvar "a"; pvar "b" ],
        true );
      ("ptuple len", Value.VTuple [ Value.VInt 1 ], ptuple [ pvar "a"; pvar "b" ], false);
      ("ptuple not tuple", Value.VInt 1, ptuple [ pvar "a" ], false);
      ("pas yes", Value.VInt 7, pas "whole" (plit (Kernel.LInt 7)), true);
      ("pas inner no", Value.VInt 8, pas "whole" (plit (Kernel.LInt 7)), false);
    ]
  in
  List.iter (fun (name, v, p, expected) -> Alcotest.(check bool) name expected (matches v p)) cases

let test_bindings () =
  let v = Value.VTuple [ Value.VInt 1; Value.VInt 2 ] in
  Alcotest.(check (option string))
    "pvar binds" (Some "(1, 2)")
    (Option.map Value.show (binding_of v (pvar "x") "x"));
  Alcotest.(check (option string))
    "pas binds whole" (Some "(1, 2)")
    (Option.map Value.show (binding_of v (pas "w" (ptuple [ pvar "a"; pvar "b" ])) "w"));
  Alcotest.(check (option string))
    "tuple component" (Some "2")
    (Option.map Value.show (binding_of v (ptuple [ pvar "a"; pvar "b" ]) "b"))

(* nested PAs inside PCon inside PTuple binds all names (plan's deep test) *)
let test_deep_nesting () =
  let h = Eval_support.make () in
  let sc = h.Eval_support.some_con in
  let v =
    Value.VTuple
      [
        Value.VCon
          { con = sc; name = "some"; args = [ Value.VTuple [ Value.VInt 1; Value.VInt 2 ] ] };
        Value.VInt 9;
      ]
  in
  let p =
    ptuple
      [ pcon sc [ pas "inner" (ptuple [ pvar "x"; pvar "y" ]) ]; pas "nine" (plit (Kernel.LInt 9)) ]
  in
  match Eval.match_pat v p Value.Env.empty with
  | None -> Alcotest.fail "deep pattern should match"
  | Some env ->
      let get x = Value.show !(Value.Env.find x env) in
      Alcotest.(check string) "x" "1" (get "x");
      Alcotest.(check string) "y" "2" (get "y");
      Alcotest.(check string) "inner" "(1, 2)" (get "inner");
      Alcotest.(check string) "nine" "9" (get "nine")

(* the same semantics drive full match expressions in the machine *)
let test_match_expression_end_to_end () =
  let h = Eval_support.make () in
  Alcotest.(check string)
    "first matching clause wins" "\"one\""
    (Value.show
       (Eval_support.eval_ok h
          "(match (app (var some) (lit 1)) (clause (pcon some (plit 0)) (lit \"zero\")) (clause \
           (pcon some (pvar n)) (lit \"one\")) (clause (pcon none) (lit \"none\")))"));
  Alcotest.(check string)
    "as-pattern in clause" "(1, 2)"
    (Value.show
       (Eval_support.eval_ok h
          "(match (tuple (lit 1) (lit 2)) (clause (pas whole (ptuple (pvar a) (pwild))) (var \
           whole)))"))

let suite =
  [
    Alcotest.test_case "pattern form table" `Quick test_table;
    Alcotest.test_case "bindings" `Quick test_bindings;
    Alcotest.test_case "deep nesting binds all names" `Quick test_deep_nesting;
    Alcotest.test_case "match expression end to end" `Quick test_match_expression_end_to_end;
  ]
