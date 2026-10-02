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

let test_mixed_payloads () =
  (* each instance's operations must agree with its own payload *)
  rejects "a Text into the Int store" Instances
    (Scoped ("count", Int 0, Scoped ("log", Text "", Put (Var "count", Text "x"))));
  rejects "an Int into the Text store" Instances
    (Scoped ("count", Int 0, Scoped ("log", Text "", Put (Var "log", Int 1))));
  rejects "adding the Text store's value" Instances
    (Scoped ("count", Int 0, Scoped ("log", Text "", Add (Get (Var "log"), Int 1))))

let test_spawned_work () =
  (* async.spawn's child runs under the scheduler, outside the instance's handler *)
  let spawn_over_instance = Scoped ("c", Int 0, Detach (Put (Var "c", Int 1))) in
  rejects "spawned work may not perform a scoped instance" Instances spawn_over_instance;
  (* the model's Mono mode also refuses it; shipped TS.0 instead charges ambient effects of
     spawned work to the caller under SC.4, a divergence recorded in the design's limits *)
  rejects "nor under the model's mono rule" Mono spawn_over_instance;
  (match run By_instance spawn_over_instance with
  | Stuck _ -> ()
  | _ -> Alcotest.fail "the detached put should reach a stale capability");
  accepts "capability-free spawned work" Instances (Scoped ("c", Int 0, Detach Unit));
  (* a value read in scope may be handed to spawned work: only the capability may not *)
  accepts "a value, not a capability" Instances
    (Scoped ("c", Int 7, Let ("v", Get (Var "c"), Detach (Let ("_", Add (Var "v", Int 1), Unit)))))

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
                TArr (TUnit, [ Label "c" ], TUnit),
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
                Lam ("f", TArr (TUnit, [ Label "b" ], TUnit), App (Var "f", Unit)),
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

let subterms = function
  | Int _ | Bool _ | Unit | Text _ | Var _ | Flip -> []
  | Lam (_, _, e)
  | Get e
  | Amb e
  | Emit e
  | Collect e
  | Detach e
  | ThrowScoped (_, e)
  | EmitScoped (_, e)
  | Fst e
  | Snd e ->
      [ e ]
  | App (a, b)
  | Let (_, a, b)
  | Add (a, b)
  | Put (a, b)
  | Scoped (_, a, b)
  | Head (a, b)
  | ThrowAt (a, b, _)
  | EmitAt (a, b) ->
      [ a; b ]
  | If (a, b, c) | MatchResult (a, _, b, _, c) -> [ a; b; c ]

let rec size e = 1 + List.fold_left (fun n e -> n + size e) 0 (subterms e)
let rec exists p e = p e || List.exists (exists p) (subterms e)

(* feature counts over a program: nested scopes, a scope under amb, closures over capabilities *)
let is_scope = function Scoped _ | ThrowScoped _ | EmitScoped _ -> true | _ -> false

let rec count_scopes e =
  (if is_scope e then 1 else 0) + List.fold_left (fun n e -> n + count_scopes e) 0 (subterms e)

let scope_under_amb = exists (function Amb e -> count_scopes e > 0 | _ -> false)

let contains_operation =
  exists (function Get _ | Put _ | ThrowAt _ | EmitAt _ -> true | _ -> false)

let closure_over_capability =
  exists (function Lam (_, _, body) -> contains_operation body | _ -> false)

let contains_collect = exists (function Collect _ -> true | _ -> false)
let contains_throw_scope = exists (function ThrowScoped _ -> true | _ -> false)
let contains_emit_scope = exists (function EmitScoped _ -> true | _ -> false)

let test_instances_sound () =
  let programs = generated () in
  let typed_programs = List.filter (fun e -> typed Instances e <> None) programs in
  let count predicate = List.length (List.filter predicate typed_programs) in
  let nested = count (fun e -> count_scopes e >= 2)
  and under_amb = count scope_under_amb
  and closures = count closure_over_capability
  and collects = count contains_collect
  and throws = count contains_throw_scope
  and emits = count contains_emit_scope in
  Printf.printf
    "well-typed features: nested scopes %d, scope under amb %d, closure over a capability %d, \
     collect %d, throw scope %d, emit scope %d\n"
    nested under_amb closures collects throws emits;
  List.iter
    (fun (label, n) -> Alcotest.(check bool) (Printf.sprintf "%s %d" label n) true (n >= 200))
    [
      ("nested scopes", nested);
      ("scope under amb", under_amb);
      ("closures over capabilities", closures);
      ("collects", collects);
      ("throw scopes", throws);
      ("emit scopes", emits);
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

(* The escape check does real work: run the programs it rejects anyway (a permissive checker),
   and count those that then reach a stale capability. *)
(* An effect that leaves the scope may not carry the capability either: emitting it to an outer
   collector hands it out after its handler has gone. *)
let emitted_escape =
  Scoped ("outer", Int 7, Get (Head (Collect (Scoped ("c", Int 0, Emit (Var "c"))), Var "outer")))

let test_escape_through_effect () =
  rejects "instances reject a capability in an outward effect payload" Instances emitted_escape;
  (match run By_instance emitted_escape with
  | Stuck message when String.ends_with ~suffix:"stale capability" message -> ()
  | _ -> Alcotest.fail "the emitted capability should be stale when used");
  (* an effect whose payload does not mention the instance still leaves the scope *)
  let fine = Collect (Scoped ("c", Int 0, Emit (Get (Var "c")))) in
  accepts "a payload read from the capability may leave" Instances fine;
  match value By_instance fine with
  | VList [ VInt 0 ] -> ()
  | _ -> Alcotest.fail "collected the read value"

(* Mono payloads are structural: two different function payloads never share a row entry, and a
   row entry cannot be forged from a string. (A string encoding let this program type-check and
   then read a Bool-taking function as an Int-taking one.) *)
let test_mono_payloads_are_structural () =
  let ascribe t e = App (Lam ("v", t, Var "v"), e) in
  let a = TArr (TBool, [ Carrying (mono_state, TUnit) ], TInt) in
  let b = TArr (TInt, [], TInt) in
  let c = TArr (TBool, [], TInt) in
  let p = TArr (TUnit, [ Carrying (mono_state, c) ], TInt) in
  let q = TArr (TUnit, [ Carrying (mono_state, a); Carrying (mono_state, b) ], TInt) in
  let program =
    Let
      ( "b",
        Scoped ("b", Lam ("n", TInt, Var "n"), Var "b"),
        Let
          ( "p",
            Scoped ("p", ascribe p (Lam ("_", TUnit, Int 0)), Var "p"),
            Let
              ( "f",
                Scoped ("q", ascribe q (Lam ("_", TUnit, App (Get (Var "b"), Int 0))), Get (Var "p")),
                Scoped
                  ( "c",
                    ascribe c (Lam ("flag", TBool, If (Var "flag", Int 1, Int 2))),
                    App (Var "f", Unit) ) ) ) )
  in
  rejects "mono rejects the confused payloads" Mono program;
  rejects "a forged row label is not a payload" Mono
    (Lam ("f", TArr (TUnit, [ Label "state:Unit" ], TUnit), Unit))

let test_escape_check_is_load_bearing () =
  let stale =
    List.filter
      (fun e ->
        match check Instances e with
        | Ok _ -> false
        | Error message -> (
            (String.starts_with ~prefix:"instance escapes" message
            || String.starts_with ~prefix:"detached work" message)
            &&
            match run By_instance e with
            | Stuck message -> String.ends_with ~suffix:"stale capability" message
            | _ -> false))
      (generated ())
  in
  Printf.printf "escape-rejected programs that reach a stale capability when run: %d\n"
    (List.length stale);
  Alcotest.(check bool)
    (Printf.sprintf "%d stale" (List.length stale))
    true
    (List.length stale >= 100);
  let through_effect =
    List.filter
      (fun e ->
        match check Instances e with
        | Error message -> String.starts_with ~prefix:"instance escapes through the effect" message
        | Ok _ -> false)
      (generated ())
  in
  Printf.printf "rejected for an escape through an outward effect: %d\n"
    (List.length through_effect);
  Alcotest.(check bool)
    (Printf.sprintf "%d effect escapes" (List.length through_effect))
    true
    (List.length through_effect >= 100)

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

(* --- slice 2b: Throw and Emit instances (§11 A3) --- *)

let stuck_with suffix label = function
  | Stuck message when String.ends_with ~suffix message -> ()
  | Stuck message -> Alcotest.failf "%s: stuck with %s" label message
  | Value _ -> Alcotest.failf "%s: ran to a value" label
  | Out_of_fuel -> Alcotest.failf "%s: out of fuel" label

let check_type label expected e =
  match check Instances e with
  | Ok t -> Alcotest.(check string) label (show_ty expected) (show_ty t)
  | Error message -> Alcotest.failf "%s: rejected: %s" label message

let refused prefix label e =
  match check Instances e with
  | Error message when String.starts_with ~prefix message -> ()
  | Error message -> Alcotest.failf "%s: refused for another reason: %s" label message
  | Ok t -> Alcotest.failf "%s: accepted at %s" label (show_ty t)

(* an outer Throw scope (Text) holding an inner one (Int); the program throws on the outer one
   from inside the inner, whose handler would add to an Int error *)
let two_throws =
  ThrowScoped
    ( "o",
      MatchResult
        ( ThrowScoped
            ( "i",
              If (Bool false, ThrowAt (Var "i", Int 5, TInt), ThrowAt (Var "o", Text "outer", TInt))
            ),
          "v",
          Var "v",
          "n",
          Add (Var "n", Int 1) ) )

let test_two_throw_scopes () =
  check_type "a Result over the outer error type" (TResult (TText, TInt)) two_throws;
  rejects "mono: one throw payload per region" Mono two_throws;
  (match value By_instance two_throws with
  | VErr (VText "outer") -> ()
  | _ -> Alcotest.fail "the outer throw passes the inner scope to its own");
  (* the pinned example: an outer Throw holds an inner Throw and a State scope; the throw on the
     outer scope skips the marker put and the inner scope's return *)
  let pinned =
    ThrowScoped
      ( "o",
        MatchResult
          ( ThrowScoped
              ( "i",
                Scoped
                  ( "s",
                    Int 0,
                    Let
                      ( "_",
                        ThrowAt (Var "o", Text "outer", TUnit),
                        Let
                          ( "_",
                            Put (Var "s", Int 99),
                            If (Bool false, ThrowAt (Var "i", Int 1, TInt), Get (Var "s")) ) ) ) ),
            "v",
            Var "v",
            "n",
            Var "n" ) )
  in
  check_type "pinned: Result Text Int" (TResult (TText, TInt)) pinned;
  (match value By_instance pinned with
  | VErr (VText "outer") -> ()
  | _ -> Alcotest.fail "exactly err(outer)");
  (* the answer type is fresh at every use within one scope *)
  let per_use =
    ThrowScoped
      ("t", If (ThrowAt (Var "t", Int 1, TBool), Add (ThrowAt (Var "t", Int 2, TInt), Int 1), Int 0))
  in
  check_type "per-use answer types" (TResult (TInt, TInt)) per_use;
  match value By_instance per_use with
  | VErr (VInt 1) -> ()
  | _ -> Alcotest.fail "the first throw wins"

let test_nested_emit_order () =
  let program =
    EmitScoped
      ( "a",
        Let
          ( "_",
            EmitAt (Var "a", Int 1),
            Let
              ( "r",
                EmitScoped
                  ( "b",
                    Let
                      ( "_",
                        EmitAt (Var "a", Int 2),
                        Let
                          ("_", EmitAt (Var "b", Text "x"), Let ("_", EmitAt (Var "a", Int 3), Unit))
                      ) ),
                Let ("_", EmitAt (Var "a", Int 4), Var "r") ) ) )
  in
  let expected = TPair (TPair (TUnit, TList TText), TList TInt) in
  check_type "nested pairs" expected program;
  (match value By_instance program with
  | VPair (VPair (VUnit, VList [ VText "x" ]), VList [ VInt 1; VInt 2; VInt 3; VInt 4 ]) -> ()
  | _ -> Alcotest.fail "each scope records its own emits in order, forwarded through the inner");
  (* nearest dispatch records the outer emits in the inner scope: an ill-typed answer *)
  match run Nearest program with
  | Value v -> Alcotest.(check bool) "nearest: wrong type" false (value_has_type v expected)
  | _ -> Alcotest.fail "nearest dispatch still runs to a value"

let test_throw_inside_state () =
  let program =
    Scoped
      ( "s",
        Int 0,
        Let
          ( "_",
            Put (Var "s", Int 1),
            Let
              ( "r",
                ThrowScoped
                  ("t", Let ("_", Put (Var "s", Int 2), ThrowAt (Var "t", Text "stop", TUnit))),
                MatchResult (Var "r", "u", Int 0, "e", Get (Var "s")) ) ) )
  in
  accepts "state around a throw scope" Instances program;
  Alcotest.(check int) "the throw keeps the store's last write" 2 (int_value By_instance program)

let test_state_inside_emit () =
  let program =
    EmitScoped
      ( "e",
        Scoped
          ( "s",
            Int 5,
            Let
              ( "_",
                EmitAt (Var "e", Get (Var "s")),
                Let
                  ( "_",
                    Put (Var "s", Add (Get (Var "s"), Int 1)),
                    Let ("_", EmitAt (Var "e", Get (Var "s")), Get (Var "s")) ) ) ) )
  in
  check_type "an emit scope over a state" (TPair (TInt, TList TInt)) program;
  match value By_instance program with
  | VPair (VInt 6, VList [ VInt 5; VInt 6 ]) -> ()
  | _ -> Alcotest.fail "the emitted reads, then the final read"

let test_throw_nearest_counterexample () =
  accepts "instances accept two throw scopes" Instances two_throws;
  (* the same well-typed program under nearest dispatch hands the outer Text error to the inner
     scope, whose handler adds to it *)
  stuck_with "add of a non-Int" "nearest dispatch confuses the throw scopes"
    (run Nearest two_throws)

let test_throw_emit_payload_escape () =
  (* throw.scoped(fn c -> c), then the returned capability is used under an outer scope *)
  let returned =
    ThrowScoped
      ( "outer",
        Let
          ( "r",
            ThrowScoped ("c", Var "c"),
            MatchResult (Var "r", "k", ThrowAt (Var "k", Int 1, TInt), "e", Int 0) ) )
  in
  refused "instance escapes through the result" "returning the throw capability" returned;
  stuck_with "throw on a stale capability" "the returned capability" (run By_instance returned);
  (* a throw carrying a nested State scope's capability *)
  let carried =
    Let
      ( "r",
        ThrowScoped ("t", Scoped ("d", Int 0, ThrowAt (Var "t", Var "d", TUnit))),
        MatchResult (Var "r", "u", Int 0, "k", Get (Var "k")) )
  in
  refused "instance escapes through the environment" "throwing another scope's capability" carried;
  stuck_with "get on a stale capability" "the thrown capability" (run By_instance carried);
  (* the same two escapes for Emit *)
  let emit_returned =
    EmitScoped ("outer", Let ("p", EmitScoped ("e", Var "e"), EmitAt (Fst (Var "p"), Int 1)))
  in
  refused "instance escapes through the result" "returning the emit capability" emit_returned;
  stuck_with "emit on a stale capability" "the returned emit capability"
    (run By_instance emit_returned);
  refused "instance escapes through the environment" "emitting another scope's capability"
    (EmitScoped ("e", Scoped ("d", Int 0, EmitAt (Var "e", Var "d"))));
  (* a value read from another scope may be thrown or emitted *)
  accepts "a read value, not a capability" Instances
    (ThrowScoped ("t", Scoped ("d", Int 3, ThrowAt (Var "t", Get (Var "d"), TUnit))))

let suite =
  [
    Alcotest.test_case "two stores of different payload types" `Quick test_two_stores;
    Alcotest.test_case "same-typed instances: mono is type-safe but instance-blind" `Quick
      test_same_type_instances;
    Alcotest.test_case "each instance keeps its own payload" `Quick test_mixed_payloads;
    Alcotest.test_case "spawned work may not perform a scoped instance" `Quick test_spawned_work;
    Alcotest.test_case "capabilities do not escape their scope" `Quick test_escape;
    Alcotest.test_case "capabilities do not escape through outward effects" `Quick
      test_escape_through_effect;
    Alcotest.test_case "mono payloads are structural" `Quick test_mono_payloads_are_structural;
    Alcotest.test_case "higher-order transport keeps the instance" `Quick test_higher_order;
    Alcotest.test_case "multi-shot resumptions copy or share state by scope" `Quick test_multi_shot;
    Alcotest.test_case "instance typing with instance dispatch is sound (generated)" `Quick
      test_instances_sound;
    Alcotest.test_case "TS.0 mono typing with nearest dispatch is sound (generated)" `Quick
      test_mono_sound;
    Alcotest.test_case "rejected escapes would reach stale capabilities (generated)" `Quick
      test_escape_check_is_load_bearing;
    Alcotest.test_case "instance typing requires instance dispatch (generated)" `Quick
      test_instance_typing_needs_instance_dispatch;
    Alcotest.test_case "two throw scopes of different error types" `Quick test_two_throw_scopes;
    Alcotest.test_case "nested emit scopes keep chronological order" `Quick test_nested_emit_order;
    Alcotest.test_case "a throw inside state keeps the store" `Quick test_throw_inside_state;
    Alcotest.test_case "state inside emit" `Quick test_state_inside_emit;
    Alcotest.test_case "nearest dispatch confuses throw scopes of different error types" `Quick
      test_throw_nearest_counterexample;
    Alcotest.test_case "throw and emit payloads do not escape their scope" `Quick
      test_throw_emit_payload_escape;
  ]
