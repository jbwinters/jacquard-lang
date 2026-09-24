(* TS.1: the scoped-instance model's examples and its generated soundness checks. *)

open Scoped_instances_model

let typed mode e = match check mode e with Ok t -> Some t | Error _ -> None
let accepts label mode e = Alcotest.(check bool) label true (typed mode e <> None)
let rejects label mode e = Alcotest.(check bool) label true (typed mode e = None)

let value dispatch e =
  match run dispatch e with
  | Value v -> v
  | Stuck message -> Alcotest.failf "stuck: %s" message
  | Out_of_fuel -> Alcotest.fail "out of fuel"

let int_value dispatch e =
  match value dispatch e with VInt n -> n | _ -> Alcotest.fail "not an Int"

(* two stores of different payload types, used in one scope *)
let two_stores =
  Scoped
    ( "count",
      Int 0,
      Scoped
        ( "log",
          Text "start",
          Let
            ( "_",
              Put (Var "count", Add (Get (Var "count"), Int 1)),
              Let ("_", Put (Var "log", Text "done"), Get (Var "count")) ) ) )

let test_two_stores () =
  accepts "instances accept two stores" Instances two_stores;
  rejects "mono rejects two stores (one payload per region)" Mono two_stores;
  Alcotest.(check int) "instance dispatch keeps them apart" 1 (int_value By_instance two_stores);
  (* the same well-typed program under operation-identity dispatch reads the Text store as Int *)
  match run Nearest two_stores with
  | Stuck _ -> ()
  | Value v ->
      Alcotest.failf "nearest dispatch should confuse the stores, got %s"
        (match v with VInt n -> string_of_int n | _ -> "?")
  | Out_of_fuel -> Alcotest.fail "out of fuel"

let test_same_type_instances () =
  (* same payload type: mono accepts, and nearest dispatch silently serves the wrong instance *)
  let program =
    Scoped
      ( "outer",
        Int 10,
        Scoped ("inner", Int 20, Let ("_", Put (Var "outer", Int 11), Get (Var "outer"))) )
  in
  accepts "instances accept" Instances program;
  accepts "mono accepts" Mono program;
  Alcotest.(check int) "by instance: the outer store" 11 (int_value By_instance program);
  Alcotest.(check int) "nearest: the inner store answers for outer" 11 (int_value Nearest program);
  let observe_inner =
    Scoped
      ( "outer",
        Int 10,
        Scoped ("inner", Int 20, Let ("_", Put (Var "outer", Int 11), Get (Var "inner"))) )
  in
  Alcotest.(check int) "by instance: inner untouched" 20 (int_value By_instance observe_inner);
  Alcotest.(check int)
    "nearest: the put to outer landed on inner" 11 (int_value Nearest observe_inner)

let test_escape () =
  rejects "returning the capability" Instances (Scoped ("c", Int 0, Var "c"));
  rejects "returning a closure over it" Instances
    (Scoped ("c", Int 0, Lam ("_", TUnit, Get (Var "c"))));
  rejects "a list holding it" Instances (Scoped ("c", Int 0, Amb (Var "c")));
  (* the same escapes are type-correct under mono and get stuck at run time *)
  let leaked =
    Let ("k", Scoped ("c", Int 0, Lam ("_", TUnit, Get (Var "c"))), App (Var "k", Unit))
  in
  rejects "instances reject the leaked thunk" Instances leaked;
  (match run By_instance leaked with
  | Stuck _ -> ()
  | _ -> Alcotest.fail "a leaked capability must be stale at run time");
  (* a capability used strictly inside its scope, through a closure, is fine *)
  let inside =
    Scoped ("c", Int 5, Let ("k", Lam ("_", TUnit, Get (Var "c")), App (Var "k", Unit)))
  in
  accepts "closure used inside the scope" Instances inside;
  Alcotest.(check int) "and it reads the store" 5 (int_value By_instance inside)

let test_higher_order () =
  (* a function whose latent row names the instance, passed and applied in scope *)
  let program =
    Scoped
      ( "c",
        Int 1,
        Let
          ( "twice",
            Lam
              ( "f",
                TArr (TUnit, [ "c" ], TUnit),
                Let ("_", App (Var "f", Unit), App (Var "f", Unit)) ),
            Let
              ( "_",
                App (Var "twice", Lam ("_", TUnit, Put (Var "c", Add (Get (Var "c"), Int 1)))),
                Get (Var "c") ) ) )
  in
  accepts "higher-order transport" Instances program;
  Alcotest.(check int) "applied twice" 3 (int_value By_instance program);
  (* passing a thunk over one instance where another is expected is rejected *)
  let crossed =
    Scoped
      ( "a",
        Int 0,
        Scoped
          ( "b",
            Int 0,
            Let
              ( "run-b",
                Lam ("f", TArr (TUnit, [ "b" ], TUnit), App (Var "f", Unit)),
                App (Var "run-b", Lam ("_", TUnit, Put (Var "a", Int 1))) ) ) )
  in
  rejects "a thunk over a is not a thunk over b" Instances crossed

let test_multi_shot () =
  (* state inside the multi-shot region: each branch owns a copy *)
  let local =
    Amb
      (Scoped
         ( "c",
           Int 0,
           Let ("_", If (Flip, Put (Var "c", Int 1), Put (Var "c", Int 2)), Get (Var "c")) ))
  in
  accepts "instance inside amb" Instances local;
  (match value By_instance local with
  | VList [ VInt 1; VInt 2 ] -> ()
  | _ -> Alcotest.fail "each branch should see its own store");
  (* state outside: branches run in order and share the store *)
  let shared =
    Scoped
      ( "c",
        Int 0,
        Let
          ( "r",
            Amb
              (If
                 ( Flip,
                   Put (Var "c", Add (Get (Var "c"), Int 1)),
                   Put (Var "c", Add (Get (Var "c"), Int 1)) )),
            Get (Var "c") ) )
  in
  accepts "amb inside an instance" Instances shared;
  Alcotest.(check int) "both branches updated the shared store" 2 (int_value By_instance shared);
  (* a capability cannot leave its scope through a resumption's result *)
  rejects "no escape through amb results" Instances
    (Scoped ("c", Int 0, Amb (If (Flip, Var "c", Var "c"))))

(* --- generated soundness --- *)

let samples = 20_000

let generated () =
  QCheck.Gen.generate ~rand:(Random.State.make [| 210 |]) ~n:samples Scoped_instances_model.gen_expr

type tally = { mutable typed : int; mutable rejected : int; mutable ran : int; mutable fuel : int }

let soundness mode dispatch programs =
  let tally = { typed = 0; rejected = 0; ran = 0; fuel = 0 } in
  List.iter
    (fun e ->
      match check mode e with
      | Error _ -> tally.rejected <- tally.rejected + 1
      | Ok t -> (
          tally.typed <- tally.typed + 1;
          match run dispatch e with
          | Value v ->
              tally.ran <- tally.ran + 1;
              if not (value_has_type v t) then Alcotest.fail "a result has the wrong type"
          | Out_of_fuel -> tally.fuel <- tally.fuel + 1
          | Stuck message -> Alcotest.failf "a well-typed program got stuck: %s" message))
    programs;
  tally

let rec size = function
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> 1
  | Lam (_, _, e) | Get e | Amb e -> 1 + size e
  | App (a, b) | Let (_, a, b) | Add (a, b) | Put (a, b) | Scoped (_, a, b) -> 1 + size a + size b
  | If (a, b, c) -> 1 + size a + size b + size c

(* feature counts over a program: nested scopes, a scope under amb, closures over capabilities *)
let rec count_scopes = function
  | Scoped (_, a, b) -> 1 + count_scopes a + count_scopes b
  | Lam (_, _, e) | Get e | Amb e -> count_scopes e
  | App (a, b) | Let (_, a, b) | Add (a, b) | Put (a, b) -> count_scopes a + count_scopes b
  | If (a, b, c) -> count_scopes a + count_scopes b + count_scopes c
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> 0

let rec scope_under_amb = function
  | Amb e -> count_scopes e > 0 || scope_under_amb e
  | Scoped (_, a, b) | App (a, b) | Let (_, a, b) | Add (a, b) | Put (a, b) ->
      scope_under_amb a || scope_under_amb b
  | Lam (_, _, e) | Get e -> scope_under_amb e
  | If (a, b, c) -> scope_under_amb a || scope_under_amb b || scope_under_amb c
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> false

let rec contains_operation = function
  | Get _ | Put _ -> true
  | Lam (_, _, e) | Amb e -> contains_operation e
  | Scoped (_, a, b) | App (a, b) | Let (_, a, b) | Add (a, b) ->
      contains_operation a || contains_operation b
  | If (a, b, c) -> contains_operation a || contains_operation b || contains_operation c
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> false

let rec closure_over_capability = function
  | Lam (_, _, body) -> contains_operation body || closure_over_capability body
  | Scoped (_, a, b) | App (a, b) | Let (_, a, b) | Add (a, b) | Put (a, b) ->
      closure_over_capability a || closure_over_capability b
  | Get e | Amb e -> closure_over_capability e
  | If (a, b, c) ->
      closure_over_capability a || closure_over_capability b || closure_over_capability c
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> false

let test_instances_sound () =
  let programs = generated () in
  let typed_programs = List.filter (fun e -> typed Instances e <> None) programs in
  let count predicate = List.length (List.filter predicate typed_programs) in
  let nested = count (fun e -> count_scopes e >= 2)
  and under_amb = count scope_under_amb
  and closures = count closure_over_capability in
  Printf.printf
    "well-typed features: nested scopes %d, scope under amb %d, closure over a capability %d\n"
    nested under_amb closures;
  List.iter
    (fun (label, n) -> Alcotest.(check bool) (Printf.sprintf "%s %d" label n) true (n >= 200))
    [
      ("nested scopes", nested);
      ("scope under amb", under_amb);
      ("closures over capabilities", closures);
    ];
  let sizes = List.map size programs in
  Printf.printf "generated %d programs, mean size %.1f, max %d\n" samples
    (float (List.fold_left ( + ) 0 sizes) /. float samples)
    (List.fold_left max 0 sizes);
  let tally = soundness Instances By_instance programs in
  Printf.printf "instances: typed %d, rejected %d, ran %d, out of fuel %d\n" tally.typed
    tally.rejected tally.ran tally.fuel;
  (* coverage floors: the generator must exercise both acceptance and rejection *)
  Alcotest.(check bool) (Printf.sprintf "typed %d" tally.typed) true (tally.typed > samples / 4);
  Alcotest.(check bool)
    (Printf.sprintf "rejected %d" tally.rejected)
    true
    (tally.rejected > samples / 20);
  Alcotest.(check bool) (Printf.sprintf "ran %d" tally.ran) true (tally.ran > tally.typed / 2)

let test_mono_sound () =
  let tally = soundness Mono Nearest (generated ()) in
  Printf.printf "mono: typed %d, rejected %d, ran %d\n" tally.typed tally.rejected tally.ran;
  Alcotest.(check bool) (Printf.sprintf "typed %d" tally.typed) true (tally.typed > samples / 10)

let test_instance_typing_needs_instance_dispatch () =
  (* instance typing over operation-identity dispatch is unsound: the generator finds cases *)
  let unsound =
    List.filter
      (fun e ->
        typed Instances e <> None && match run Nearest e with Stuck _ -> true | _ -> false)
      (generated ())
  in
  Alcotest.(check bool)
    (Printf.sprintf "%d counterexamples" (List.length unsound))
    true (unsound <> [])

let suite =
  [
    Alcotest.test_case "two stores of different payload types" `Quick test_two_stores;
    Alcotest.test_case "same-typed instances: mono is type-safe but instance-blind" `Quick
      test_same_type_instances;
    Alcotest.test_case "capabilities do not escape their scope" `Quick test_escape;
    Alcotest.test_case "higher-order transport keeps the instance" `Quick test_higher_order;
    Alcotest.test_case "multi-shot resumptions copy or share state by scope" `Quick test_multi_shot;
    Alcotest.test_case "instance typing with instance dispatch is sound (generated)" `Quick
      test_instances_sound;
    Alcotest.test_case "TS.0 mono typing with nearest dispatch is sound (generated)" `Quick
      test_mono_sound;
    Alcotest.test_case "instance typing requires instance dispatch (generated)" `Quick
      test_instance_typing_needs_instance_dispatch;
  ]
