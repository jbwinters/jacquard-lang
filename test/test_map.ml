open Weft

(* SL.6: Map/Set — the largest pure-Weft program, tested against an association-list
   model, plus AVL balance and CPS stack-safety pins. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed: %s" (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)

(* build a Weft map expression from a list of operations *)
type op = Set of int * int | Delete of int

let map_expr ops =
  List.fold_left
    (fun m -> function
      | Set (k, v) -> Printf.sprintf "(app (var map.set) %s (lit %d) (lit %d))" m k v
      | Delete k ->
          Printf.sprintf "(app (var map.update) %s (lit %d) (lam ((pwild)) (var none)))" m k)
    "(app (var map.empty) (var int.ord))" ops

(* the model: assoc list, last write wins *)
let model ops =
  List.fold_left
    (fun m -> function
      | Set (k, v) -> (k, v) :: List.remove_assoc k m | Delete k -> List.remove_assoc k m)
    [] ops

(* in-order fold accumulating with cons yields DESCENDING key order *)
let render_model m =
  List.sort (fun (a, _) (b, _) -> compare b a) m
  |> List.map (fun (k, v) -> Printf.sprintf "(%d, %d)" k v)
  |> fun l -> List.fold_right (fun x acc -> Printf.sprintf "cons(%s, %s)" x acc) l "nil"

let ops_gen =
  QCheck.Gen.(
    list_size (int_bound 30)
      (bind (int_range 0 3) (fun tag ->
           if tag = 0 then map (fun k -> Delete (k mod 15)) (int_bound 14)
           else map2 (fun k v -> Set (k mod 15, v)) (int_bound 14) (int_range (-99) 99))))

let ops_print ops =
  String.concat ";"
    (List.map
       (function
         | Set (k, v) -> Printf.sprintf "set %d=%d" k v | Delete k -> Printf.sprintf "del %d" k)
       ops)

let prop_model_agreement =
  QCheck.Test.make ~count:500 ~name:"random op sequences agree with the assoc model"
    (QCheck.make ops_gen ~print:ops_print) (fun ops ->
      let m = map_expr ops and mdl = model ops in
      let folded =
        show
          (Printf.sprintf
             "(app (var map.fold) %s (var nil) (lam ((pvar acc) (pvar k) (pvar v)) (app (var cons) \
              (tuple (var k) (var v)) (var acc))))"
             m)
      in
      let size = show (Printf.sprintf "(app (var map.size) %s)" m) in
      (* probe get on every key the sequence touched, hit or miss *)
      let keys =
        List.sort_uniq compare (List.map (function Set (k, _) -> k | Delete k -> k) ops)
      in
      folded = render_model mdl
      && size = string_of_int (List.length mdl)
      && List.for_all
           (fun k ->
             show (Printf.sprintf "(app (var map.get) %s (lit %d))" m k)
             =
             match List.assoc_opt k mdl with
             | Some v -> Printf.sprintf "some(%d)" v
             | None -> "none")
           keys)

let test_update_read_modify () =
  (* update sees the current binding: increment-or-init *)
  let bump m k =
    Printf.sprintf
      "(app (var map.update) %s (lit %d) (lam ((pvar cur)) (app (var some) (app (var add) (lit 1) \
       (app (var option.with-default) (var cur) (lit 0))))))"
      m k
  in
  let m = bump (bump (bump "(app (var map.empty) (var int.ord))" 5) 5) 7 in
  Alcotest.(check string)
    "counts" "cons((7, 1), cons((5, 2), nil))"
    (show
       (Printf.sprintf
          "(app (var map.fold) %s (var nil) (lam ((pvar acc) (pvar k) (pvar v)) (app (var cons) \
           (tuple (var k) (var v)) (var acc))))"
          m))

let height_of m =
  show
    (Printf.sprintf
       "(match %s (clause (pcon mk-map (pwild) (pvar root)) (app (var mnode.height) (var root))))" m)

let insert_range order =
  Printf.sprintf
    "(app (var list.fold) %s (app (var map.empty) (var int.ord)) (lam ((pvar m) (pvar i)) (app \
     (var map.set) (var m) (var i) (var i))))"
    order

(* AVL bound: height <= 1.4405 log2(n+2); for n=1000 that is < 15. Sequential inserts are
   the classic worst case for an unbalanced tree (height would be 1000). *)
let test_balance () =
  List.iter
    (fun (name, order) ->
      let h = int_of_string (height_of (insert_range order)) in
      Alcotest.(check bool) (name ^ Printf.sprintf ": height %d <= 15" h) true (h <= 15))
    [
      ("ascending", "(app (var list.range) (lit 0) (lit 1000))");
      ("descending", "(app (var list.reverse) (app (var list.range) (lit 0) (lit 1000)))");
    ]

let test_inorder_fold () =
  Alcotest.(check string)
    "keys ascend" "cons(9, cons(5, cons(1, nil)))"
    (show
       (Printf.sprintf
          "(app (var map.fold) %s (var nil) (lam ((pvar acc) (pvar k) (pwild)) (app (var cons) \
           (var k) (var acc))))"
          (map_expr [ Set (5, 0); Set (1, 0); Set (9, 0) ])))

(* 10k inserts: the CPS machine keeps frames on the heap, so deep recursion is safe *)
let test_10k_stack_safety () =
  Alcotest.(check string)
    "10000 distinct members" "(10000, true, false)"
    (show
       "(let nonrec (pvar s) (app (var list.fold) (app (var list.range) (lit 0) (lit 10000)) (app \
        (var set.empty) (var int.ord)) (lam ((pvar acc) (pvar i)) (app (var set.insert) (var acc) \
        (app (var mul) (var i) (lit 2))))) (tuple (app (var set.size) (var s)) (app (var \
        set.member?) (var s) (lit 40)) (app (var set.member?) (var s) (lit 41))))")

let test_set_fold_and_captive_ord () =
  Alcotest.(check string)
    "set.fold in key order" "cons(3, cons(2, cons(1, nil)))"
    (show
       "(app (var set.fold) (app (var set.insert) (app (var set.insert) (app (var set.insert) (app \
        (var set.empty) (var int.ord)) (lit 2)) (lit 3)) (lit 1)) (var nil) (lam ((pvar acc) (pvar \
        k)) (app (var cons) (var k) (var acc))))");
  (* captive dictionary: a reversed-ord map keeps ITS ordering; no API takes a second ord *)
  Alcotest.(check string)
    "captive reversed ord" "cons(1, cons(2, cons(3, nil)))"
    (show
       "(app (var map.fold) (app (var list.fold) (app (var list.range) (lit 1) (lit 4)) (app (var \
        map.empty) (app (var ord.reverse) (var int.ord))) (lam ((pvar m) (pvar i)) (app (var \
        map.set) (var m) (var i) (var i)))) (var nil) (lam ((pvar acc) (pvar k) (pwild)) (app (var \
        cons) (var k) (var acc))))")

let suite =
  [
    QCheck_alcotest.to_alcotest prop_model_agreement;
    Alcotest.test_case "update is read-modify-write" `Quick test_update_read_modify;
    Alcotest.test_case "AVL balance under adversarial inserts" `Quick test_balance;
    Alcotest.test_case "fold is in-order" `Quick test_inorder_fold;
    Alcotest.test_case "10k inserts are stack-safe" `Quick test_10k_stack_safety;
    Alcotest.test_case "set.fold and captive ord" `Quick test_set_fold_and_captive_ord;
  ]
