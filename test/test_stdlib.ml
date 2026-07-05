open Jacquard

(* SL.2–SL.4: ring 0 dictionaries, the vocabulary grid, and ring 1 handlers,
   tested behaviorally against OCaml reference implementations via qcheck.
   One prelude context is shared: everything under test is pure. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)

(* Jacquard source builders *)
let wlist xs =
  List.fold_right (fun x acc -> Printf.sprintf "(app (var cons) %s %s)" x acc) xs "(var nil)"

let wint n = Printf.sprintf "(lit %d)" n
let wints ns = wlist (List.map wint ns)
let wbool b = if b then "(var true)" else "(var false)"
let vbool b = if b then "true" else "false"

(* the Value.show rendering of an int list / option / etc., built from OCaml values *)
let rec vlist = function [] -> "nil" | x :: r -> Printf.sprintf "cons(%d, %s)" x (vlist r)
let voption = function None -> "none" | Some n -> Printf.sprintf "some(%d)" n
let ints_gen = QCheck.Gen.(list_size (int_bound 12) (int_range (-50) 50))
let ints_arb = QCheck.make ~print:QCheck.Print.(list int) ints_gen

let qtest ?(count = 60) name gen f =
  QCheck_alcotest.to_alcotest (QCheck.Test.make ~count ~name gen f)

(* --- SL.2: dictionaries --- *)

let test_instances () =
  Alcotest.(check string)
    "int.eq true" "true"
    (show "(app (app (var eq.fn) (var int.eq)) (lit 4) (lit 4))");
  Alcotest.(check string)
    "int.eq false" "false"
    (show "(app (app (var eq.fn) (var int.eq)) (lit 4) (lit 5))");
  Alcotest.(check string)
    "int.ord less" "less"
    (show "(app (app (var ord.fn) (var int.ord)) (lit 1) (lit 2))");
  Alcotest.(check string)
    "int.ord greater" "greater"
    (show "(app (app (var ord.fn) (var int.ord)) (lit 2) (lit 1))");
  Alcotest.(check string)
    "int.ord equal" "equal"
    (show "(app (app (var ord.fn) (var int.ord)) (lit 2) (lit 2))");
  Alcotest.(check string)
    "bool.eq" "true"
    (show "(app (app (var eq.fn) (var bool.eq)) (var false) (var false))")

let prop_ord_to_eq_consistent =
  QCheck.Test.make ~count:80 ~name:"ord.to-eq agrees with int.eq"
    QCheck.(pair (int_range (-30) 30) (int_range (-30) 30))
    (fun (a, b) ->
      show
        (Printf.sprintf "(app (app (var eq.fn) (app (var ord.to-eq) (var int.ord))) %s %s)" (wint a)
           (wint b))
      = vbool (a = b))

let prop_ord_reverse =
  QCheck.Test.make ~count:80 ~name:"ord.reverse flips compare"
    QCheck.(pair (int_range (-30) 30) (int_range (-30) 30))
    (fun (a, b) ->
      let flip = function "less" -> "greater" | "greater" -> "less" | o -> o in
      show
        (Printf.sprintf "(app (app (var ord.fn) (app (var ord.reverse) (var int.ord))) %s %s)"
           (wint a) (wint b))
      = flip
          (show (Printf.sprintf "(app (app (var ord.fn) (var int.ord)) %s %s)" (wint a) (wint b))))

let prop_eq_for_list =
  QCheck.Test.make ~count:60 ~name:"eq.for-list is structural equality"
    QCheck.(pair ints_arb ints_arb)
    (fun (xs, ys) ->
      show
        (Printf.sprintf "(app (app (var eq.fn) (app (var eq.for-list) (var int.eq))) %s %s)"
           (wints xs) (wints ys))
      = vbool (xs = ys))

let test_eq_for_pair () =
  Alcotest.(check string)
    "pair eq" "true"
    (show
       "(app (app (var eq.fn) (app (var eq.for-pair) (var int.eq) (var bool.eq))) (tuple (lit 1) \
        (var true)) (tuple (lit 1) (var true)))");
  Alcotest.(check string)
    "pair neq second" "false"
    (show
       "(app (app (var eq.fn) (app (var eq.for-pair) (var int.eq) (var bool.eq))) (tuple (lit 1) \
        (var true)) (tuple (lit 1) (var false)))")

(* --- SL.3: the grid vs OCaml references --- *)

let prop_map =
  qtest "list.map = List.map" ints_arb (fun xs ->
      show
        (Printf.sprintf "(app (var list.map) %s (lam ((pvar n)) (app (var mul) (var n) (lit 3))))"
           (wints xs))
      = vlist (List.map (fun n -> n * 3) xs))

let prop_filter =
  qtest "list.filter = List.filter" ints_arb (fun xs ->
      show
        (Printf.sprintf "(app (var list.filter) %s (lam ((pvar n)) (app (var lt) (lit 0) (var n))))"
           (wints xs))
      = vlist (List.filter (fun n -> n > 0) xs))

let prop_fold =
  qtest "list.fold is a left fold" ints_arb (fun xs ->
      (* subtraction is not commutative, so this pins the fold direction too *)
      show (Printf.sprintf "(app (var list.fold) %s (lit 0) (var sub))" (wints xs))
      = string_of_int (List.fold_left ( - ) 0 xs))

let prop_reverse_append =
  qtest "reverse and append"
    QCheck.(pair ints_arb ints_arb)
    (fun (xs, ys) ->
      show (Printf.sprintf "(app (var list.reverse) %s)" (wints xs)) = vlist (List.rev xs)
      && show (Printf.sprintf "(app (var list.append) %s %s)" (wints xs) (wints ys))
         = vlist (xs @ ys))

let prop_length_nth_last =
  qtest "length, nth, last" ints_arb (fun xs ->
      let n = List.length xs in
      show (Printf.sprintf "(app (var list.length) %s)" (wints xs)) = string_of_int n
      && show (Printf.sprintf "(app (var list.last) %s)" (wints xs))
         = voption (if n = 0 then None else Some (List.nth xs (n - 1)))
      && show (Printf.sprintf "(app (var list.nth) %s (lit %d))" (wints xs) (n / 2))
         = voption (List.nth_opt xs (n / 2)))

let prop_take_drop =
  qtest "take/drop partition"
    QCheck.(pair ints_arb (int_range (-2) 15))
    (fun (xs, n) ->
      let rec take k = function x :: r when k > 0 -> x :: take (k - 1) r | _ -> [] in
      let rec drop k = function _ :: r when k > 0 -> drop (k - 1) r | l -> l in
      show (Printf.sprintf "(app (var list.take) %s %s)" (wints xs) (wint n)) = vlist (take n xs)
      && show (Printf.sprintf "(app (var list.drop) %s %s)" (wints xs) (wint n)) = vlist (drop n xs))

let prop_concat_range =
  qtest "concat and range"
    QCheck.(make ~print:Print.(list (list int)) Gen.(list_size (int_bound 4) ints_gen))
    (fun xss ->
      show (Printf.sprintf "(app (var list.concat) %s)" (wlist (List.map wints xss)))
      = vlist (List.concat xss)
      && show "(app (var list.range) (lit 2) (lit 6))" = vlist [ 2; 3; 4; 5 ]
      && show "(app (var list.range) (lit 3) (lit 3))" = "nil")

let test_zip () =
  Alcotest.(check string)
    "zip uneven" "cons((1, 9), cons((2, 8), nil))"
    (show (Printf.sprintf "(app (var list.zip) %s %s)" (wints [ 1; 2; 3 ]) (wints [ 9; 8 ])))

let prop_sort =
  qtest "list.sort = List.sort" ints_arb (fun xs ->
      show (Printf.sprintf "(app (var list.sort) %s (var int.ord))" (wints xs))
      = vlist (List.sort compare xs))

let test_sort_stability () =
  (* pairs sorted by second component keep first-component order among ties *)
  let pairs = [ (1, 5); (2, 3); (3, 5); (4, 3); (5, 5) ] in
  let wpairs =
    wlist (List.map (fun (a, b) -> Printf.sprintf "(tuple %s %s)" (wint a) (wint b)) pairs)
  in
  let expected =
    List.stable_sort (fun (_, b1) (_, b2) -> compare b1 b2) pairs
    |> List.map (fun (a, b) -> Printf.sprintf "(%d, %d)" a b)
    |> fun l -> List.fold_right (fun x acc -> Printf.sprintf "cons(%s, %s)" x acc) l "nil"
  in
  Alcotest.(check string)
    "stable by second" expected
    (show
       (Printf.sprintf "(app (var list.sort) %s (app (var ord.on-second) (var int.ord)))" wpairs))

let prop_find_contains =
  qtest "find and contains?"
    QCheck.(pair ints_arb (int_range (-50) 50))
    (fun (xs, x) ->
      show (Printf.sprintf "(app (var list.contains?) %s %s (var int.eq))" (wints xs) (wint x))
      = vbool (List.mem x xs)
      && show
           (Printf.sprintf "(app (var list.find) %s (lam ((pvar y)) (app (var lt) %s (var y))))"
              (wints xs) (wint x))
         = voption (List.find_opt (fun y -> y > x) xs))

let prop_head_empty =
  qtest "head and empty?" ints_arb (fun xs ->
      show (Printf.sprintf "(app (var list.head) %s)" (wints xs))
      = voption (match xs with [] -> None | x :: _ -> Some x)
      && show (Printf.sprintf "(app (var list.empty?) %s)" (wints xs)) = vbool (xs = []))

let test_option_grid () =
  let checks =
    [
      ( "(app (var option.map) (app (var some) (lit 3)) (lam ((pvar n)) (app (var add) (var n) \
         (lit 1))))",
        "some(4)" );
      ("(app (var option.map) (var none) (lam ((pvar n)) (app (var add) (var n) (lit 1))))", "none");
      ("(app (var option.then) (app (var some) (lit 3)) (lam ((pvar n)) (var none)))", "none");
      ("(app (var option.with-default) (var none) (lit 9))", "9");
      ("(app (var option.with-default) (app (var some) (lit 2)) (lit 9))", "2");
      ("(app (var option.none?) (var none))", "true");
      ("(app (var option.some?) (var none))", "false");
      ( "(app (var option.filter) (app (var some) (lit 4)) (lam ((pvar n)) (app (var lt) (var n) \
         (lit 3))))",
        "none" );
      ( "(app (var option.filter) (app (var some) (lit 2)) (lam ((pvar n)) (app (var lt) (var n) \
         (lit 3))))",
        "some(2)" );
      ("(app (var option.fold) (app (var some) (lit 4)) (lit 10) (var add))", "14");
      ("(app (var option.fold) (var none) (lit 10) (var add))", "10");
    ]
  in
  List.iter (fun (src, want) -> Alcotest.(check string) src want (show src)) checks

let test_result_grid () =
  let checks =
    [
      ( "(app (var result.map) (app (var ok) (lit 3)) (lam ((pvar n)) (app (var add) (var n) (lit \
         1))))",
        "ok(4)" );
      ( "(app (var result.map) (app (var err) (lit 7)) (lam ((pvar n)) (app (var add) (var n) (lit \
         1))))",
        "err(7)" );
      ( "(app (var result.map-error) (app (var err) (lit 7)) (lam ((pvar e)) (app (var mul) (var \
         e) (lit 2))))",
        "err(14)" );
      ( "(app (var result.then) (app (var ok) (lit 3)) (lam ((pvar n)) (app (var err) (var n))))",
        "err(3)" );
      ( "(app (var result.then) (app (var err) (lit 7)) (lam ((pvar n)) (app (var ok) (var n))))",
        "err(7)" );
      ( "(app (var result.map-error) (app (var ok) (lit 3)) (lam ((pvar e)) (app (var mul) (var e) \
         (lit 2))))",
        "ok(3)" );
      ("(app (var result.with-default) (app (var err) (lit 7)) (lit 0))", "0");
      ("(app (var result.with-default) (app (var ok) (lit 5)) (lit 0))", "5");
      ("(app (var result.of-option) (app (var some) (lit 1)) (lit 99))", "ok(1)");
      ("(app (var result.of-option) (var none) (lit 99))", "err(99)");
      ("(app (var option.of-result) (app (var ok) (lit 1)))", "some(1)");
      ("(app (var option.of-result) (app (var err) (lit 5)))", "none");
    ]
  in
  List.iter (fun (src, want) -> Alcotest.(check string) src want (show src)) checks

let test_bool_grid () =
  let checks =
    [
      ("(app (var bool.not) (var true))", "false");
      ("(app (var bool.not) (var false))", "true");
      ("(app (var bool.and) (var true) (var false))", "false");
      ("(app (var bool.and) (var true) (var true))", "true");
      ("(app (var bool.or) (var false) (var false))", "false");
      ("(app (var bool.or) (var false) (var true))", "true");
      ("(app (var result.fold) (app (var ok) (lit 4)) (lit 10) (var add))", "14");
      ("(app (var result.fold) (app (var err) (lit 4)) (lit 10) (var add))", "10");
    ]
  in
  List.iter (fun (src, want) -> Alcotest.(check string) src want (show src)) checks

(* the thunked forms short-circuit: the unreached side's effect never happens *)
let test_bool_short_circuit () =
  let go src = show src in
  Alcotest.(check string)
    "and-then skips thunk on false" "(false, nil)"
    (go
       "(app (var emit.collect) (lam () (app (var bool.and-then) (var false) (lam () (let nonrec \
        (pwild) (app (var emit) (lit 1)) (var true))))))");
  Alcotest.(check string)
    "and-then runs thunk on true" "(true, cons(1, nil))"
    (go
       "(app (var emit.collect) (lam () (app (var bool.and-then) (var true) (lam () (let nonrec \
        (pwild) (app (var emit) (lit 1)) (var true))))))");
  Alcotest.(check string)
    "or-else skips thunk on true" "(true, nil)"
    (go
       "(app (var emit.collect) (lam () (app (var bool.or-else) (var true) (lam () (let nonrec \
        (pwild) (app (var emit) (lit 1)) (var false))))))");
  Alcotest.(check string)
    "or-else runs thunk on false" "(false, cons(1, nil))"
    (go
       "(app (var emit.collect) (lam () (app (var bool.or-else) (var false) (lam () (let nonrec \
        (pwild) (app (var emit) (lit 1)) (var false))))))")

(* option.each / result.each run the action exactly on the payload-bearing side *)
let test_each_side_effects () =
  Alcotest.(check string)
    "option.each some" "((), cons(7, nil))"
    (show
       "(app (var emit.collect) (lam () (app (var option.each) (app (var some) (lit 7)) (var \
        emit))))");
  Alcotest.(check string)
    "option.each none" "((), nil)"
    (show "(app (var emit.collect) (lam () (app (var option.each) (var none) (var emit))))");
  Alcotest.(check string)
    "result.each ok" "((), cons(3, nil))"
    (show
       "(app (var emit.collect) (lam () (app (var result.each) (app (var ok) (lit 3)) (var emit))))");
  Alcotest.(check string)
    "result.each err" "((), nil)"
    (show
       "(app (var emit.collect) (lam () (app (var result.each) (app (var err) (lit 3)) (var \
        emit))))")

(* list.each runs the action once per element, in order (observed via emit) *)
let test_each_order () =
  Alcotest.(check string)
    "each emits in order" "((), cons(1, cons(2, cons(3, nil))))"
    (show
       (Printf.sprintf
          "(app (var emit.collect) (lam () (app (var list.each) %s (lam ((pvar n)) (app (var emit) \
           (var n))))))"
          (wints [ 1; 2; 3 ])))

(* --- SL.4: ring 1 seam laws --- *)

let prop_getter_seam_laws =
  qtest ~count:200 "abort.to-option (get! o) = o; head!/head agree" ints_arb (fun xs ->
      let o =
        match xs with [] -> "(var none)" | x :: _ -> Printf.sprintf "(app (var some) %s)" (wint x)
      in
      show (Printf.sprintf "(app (var abort.to-option) (lam () (app (var option.get!) %s)))" o)
      = voption (match xs with [] -> None | x :: _ -> Some x)
      && show
           (Printf.sprintf "(app (var abort.to-option) (lam () (app (var list.head!) %s)))"
              (wints xs))
         = show (Printf.sprintf "(app (var list.head) %s)" (wints xs)))

let prop_throw_seam_law =
  qtest ~count:200 "throw.to-result (result.get! r) = r"
    QCheck.(pair bool int)
    (fun (is_ok, n) ->
      let r = Printf.sprintf "(app (var %s) %s)" (if is_ok then "ok" else "err") (wint n) in
      show (Printf.sprintf "(app (var throw.to-result) (lam () (app (var result.get!) %s)))" r)
      = Printf.sprintf "%s(%d)" (if is_ok then "ok" else "err") n)

let test_abort_or () =
  Alcotest.(check string)
    "aborted" "42"
    (show "(app (var abort.or) (lam () (app (var list.head!) (var nil))) (lit 42))");
  Alcotest.(check string)
    "not aborted" "7"
    (show
       (Printf.sprintf "(app (var abort.or) (lam () (app (var list.head!) %s)) (lit 42))"
          (wints [ 7 ])))

let test_throw_catch () =
  Alcotest.(check string)
    "caught" "21"
    (show
       "(app (var throw.catch) (lam () (app (var throw) (lit 7))) (lam ((pvar e)) (app (var mul) \
        (var e) (lit 3))))");
  Alcotest.(check string)
    "no throw" "5"
    (show "(app (var throw.catch) (lam () (lit 5)) (lam ((pvar e)) (lit 0)))")

let prop_state_laws =
  qtest ~count:200 "state.run threads puts; eval drops final state"
    QCheck.(pair (int_range 0 50) (int_range 0 50))
    (fun (init, delta) ->
      (* put (get + delta); get *)
      let body =
        Printf.sprintf
          "(lam () (let nonrec (pwild) (app (var put) (app (var add) (app (var get)) %s)) (app \
           (var get))))"
          (wint delta)
      in
      show (Printf.sprintf "(app (var state.run) %s %s)" body (wint init))
      = Printf.sprintf "(%d, %d)" (init + delta) (init + delta)
      && show (Printf.sprintf "(app (var state.eval) %s %s)" body (wint init))
         = string_of_int (init + delta))

let test_state_pure_body () =
  Alcotest.(check string)
    "pure body leaves state alone" "(3, 17)"
    (show "(app (var state.run) (lam () (lit 3)) (lit 17))")

let prop_emit_collect_order =
  qtest ~count:200 "emit.collect is chronological" ints_arb (fun xs ->
      show
        (Printf.sprintf
           "(app (var emit.collect) (lam () (let nonrec (pwild) (app (var list.each) %s (var \
            emit)) (lit 0))))"
           (wints xs))
      = Printf.sprintf "(0, %s)" (vlist xs))

let test_emit_pipe () =
  (* pipe forwards each emit to f; here f re-emits doubled into an outer collect *)
  Alcotest.(check string)
    "pipe transforms the stream" "(9, cons(2, cons(4, nil)))"
    (show
       "(app (var emit.collect) (lam () (app (var emit.pipe) (lam () (let nonrec (pwild) (app (var \
        emit) (lit 1)) (let nonrec (pwild) (app (var emit) (lit 2)) (lit 9)))) (lam ((pvar w)) \
        (app (var emit) (app (var mul) (var w) (lit 2)))))))")

(* signatures: the ! getters name their effects; handlers discharge them *)
let check_ctx =
  let c =
    match Check.make_ctx store with Ok c -> c | Error ds -> Eval_support.fail_diags "ctx" ds
  in
  (match Prelude.builtin_signatures store with
  | Ok sigs -> List.iter (fun (h, s) -> Hashtbl.replace c.Check.builtin_sigs h s) sigs
  | Error ds -> Eval_support.fail_diags "builtin sigs" ds);
  c

let sig_of src =
  match Reader.parse_one ~file:"sig.wft" src with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> Eval_support.fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr (Store.names_view store) e with
          | Error ds -> Eval_support.fail_diags "resolve" ds
          | Ok e -> (
              match Check.check_top check_ctx (Kernel.Expr e) with
              | Ok { Check.names = [ (_, s) ]; _ } -> Check.show_scheme check_ctx s
              | Ok _ -> Alcotest.fail "expected one signature"
              | Error ds -> Eval_support.fail_diags "check" ds)))

let test_ring1_rows () =
  let has needle s =
    let nl = String.length needle and hl = String.length s in
    let rec go i = i + nl <= hl && (String.sub s i nl = needle || go (i + 1)) in
    go 0
  in
  let g = sig_of "(var option.get!)" in
  Alcotest.(check bool) ("option.get! row names abort: " ^ g) true (has "{abort" g);
  let r = sig_of "(var result.get!)" in
  Alcotest.(check bool) ("result.get! row names throw: " ^ r) true (has "{throw" r);
  (* the handler removes it: to-option over a get! thunk is effect-free *)
  let h =
    sig_of "(lam ((pvar o)) (app (var abort.to-option) (lam () (app (var option.get!) (var o)))))"
  in
  Alcotest.(check bool) ("handled row is clean: " ^ h) false (has "abort" h)

let suite =
  [
    Alcotest.test_case "dictionary instances" `Quick test_instances;
    prop_ord_to_eq_consistent |> QCheck_alcotest.to_alcotest;
    prop_ord_reverse |> QCheck_alcotest.to_alcotest;
    prop_eq_for_list |> QCheck_alcotest.to_alcotest;
    Alcotest.test_case "eq.for-pair" `Quick test_eq_for_pair;
    prop_map;
    prop_filter;
    prop_fold;
    prop_reverse_append;
    prop_length_nth_last;
    prop_take_drop;
    prop_concat_range;
    Alcotest.test_case "zip uneven lengths" `Quick test_zip;
    prop_sort;
    Alcotest.test_case "sort is stable (ord.on-second)" `Quick test_sort_stability;
    prop_find_contains;
    prop_head_empty;
    Alcotest.test_case "option grid" `Quick test_option_grid;
    Alcotest.test_case "result grid" `Quick test_result_grid;
    Alcotest.test_case "bool grid" `Quick test_bool_grid;
    Alcotest.test_case "bool short-circuit" `Quick test_bool_short_circuit;
    Alcotest.test_case "option/result each side effects" `Quick test_each_side_effects;
    Alcotest.test_case "list.each order" `Quick test_each_order;
    prop_getter_seam_laws;
    prop_throw_seam_law;
    Alcotest.test_case "abort.or" `Quick test_abort_or;
    Alcotest.test_case "throw.catch" `Quick test_throw_catch;
    prop_state_laws;
    Alcotest.test_case "state: pure body" `Quick test_state_pure_body;
    prop_emit_collect_order;
    Alcotest.test_case "emit.pipe" `Quick test_emit_pipe;
    Alcotest.test_case "ring 1 rows name and discharge effects" `Quick test_ring1_rows;
  ]
