open Jacquard

(* Exercise the ordinary parse/lower/check path, including stored declarations and aliases. *)
let check source =
  let source =
    Test_surface_types.lower source
    |> List.map (fun top -> Printer.print (Kernel.to_form top))
    |> String.concat "\n"
  in
  Test_check.check_src (Test_check.make_cctx ()) source

let rejects source () =
  match check source with
  | Ok _ -> Alcotest.fail "a mismatched effect payload passed static checking"
  | Error [ diagnostic ] ->
      Alcotest.(check bool)
        "static type refusal" true
        (List.mem (Diag.code_or_uncoded diagnostic) [ "E0801"; "E0804" ])
  | Error diagnostics -> Eval_support.fail_diags "expected one type refusal" diagnostics

let accepts source () =
  match check source with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "well-typed effect payload" diagnostics

let negative =
  [
    ( "State: reproduced annotated mismatch",
      {|bad : () ->{} (Text, Int)
bad() = state.run(fn () -> { put("hi"); get() }, 0)
bad()
|} );
    ("State: get result is tied to initial state", {|(state.run(fn () -> get(), 0) : (Text, Int))|});
    ( "State: operation aliases retain payload constraints",
      {|{ let write = put
let read = get
state.run(fn () -> { write("hi"); read() }, 0) }|} );
    ( "State: handler alias retains payload constraints",
      {|{ let run-state = state.run
run-state(fn () -> { put("hi"); get() }, 0) }|} );
    ( "State: higher-order transport retains payload constraints",
      {|apply(f, x) = f(x)
write(s) = apply(put, s)
state.run(fn () -> { write("hi"); get() }, 0)|}
    );
    ( "State: annotations cannot erase payload constraints",
      {|write : (Text) ->{State} ()
write(s) = put(s)
state.run(fn () -> { write("hi"); get() }, 0)|}
    );
    ( "State: nested handlers check their own payload",
      {|state.run(fn () -> state.run(fn () -> { put("hi"); get() }, 0), "outer")|} );
    ( "Throw: result error matches thrown payload",
      {|(throw.to-result(fn () -> throw("hi")) : Result Int Int)|} );
    ( "Throw: catch callback matches thrown payload",
      {|throw.catch(fn () -> throw("hi"), fn (n) -> add(n, 1))|} );
    ( "Throw: higher-order and aliases retain payload constraints",
      {|apply(f, x) = f(x)
{ let raise-error = throw
throw.catch(fn () -> apply(raise-error, "hi"), fn (n) -> add(n, 1)) }|}
    );
    ( "Emit: collection matches emitted element",
      {|(emit.collect(fn () -> emit("hi")) : ((), List Int))|} );
    ( "Emit: one handled region cannot mix element types",
      {|emit.collect(fn () -> { emit(1); emit("hi") })|} );
    ( "Emit: pipe callback matches emitted element",
      {|emit.pipe(fn () -> emit("hi"), fn (n) -> { add(n, 1); () })|} );
    ( "Emit: higher-order transport retains payload constraints",
      {|apply(f, x) = f(x)
(emit.collect(fn () -> apply(emit, "hi")) : ((), List Int))|} );
    ( "State: nominal callback field cannot erase payload constraints",
      {|type Writer = Writer(write: (Text) ->{State} ())
{ let writer = Writer(put)
state.run(fn () -> { match writer { | Writer(write) -> write("hi") }; get() }, 0) }|}
    );
    ( "State: nominal open-row callback cannot erase payload constraints",
      {|type Writer = Writer(write: (Text) ->{| e} ())
{ let writer = Writer(put)
state.run(fn () -> { match writer { | Writer(write) -> write("hi") }; get() }, 0) }|}
    );
    ( "State: callbacks nested inside nominal containers cannot erase payloads",
      {|type Writer = Writer(writes: List ((Text) ->{State} ()))
{ let writer = Writer([put])
state.run(fn () -> { match writer { | Writer(writes) -> list.each(writes, fn (write) -> write("hi")) }; get() }, 0) }|}
    );
    ( "State: nested open callback rows cannot erase payloads",
      {|type Writer = Writer(writes: List ((Text) ->{| e} ()))|} );
    ( "State: resume must agree with the handled get type",
      {|handle { (get() : Int) } {
| return value -> value
| get() resume k -> k("hi")
| put(value) resume k -> k(())
}|}
    );
    ( "Polymorphic operations: a handler cannot invent a result type",
      {|once effect Poly a where { poly : () -> a }
handle { (poly() : Text) } {
| return value -> value
| poly() resume k -> k(1)
}|}
    );
    ( "Polymorphic operations: an input type cannot escape its clause",
      {|multi effect Poly where { poly : (List a) -> () }
handle { poly(["hi"]) } {
| return value -> [1]
| poly(value) resume unused -> value
}|}
    );
  ]

let positive =
  [
    ("State: same payload type", {|(state.run(fn () -> { put(42); get() }, 0) : (Int, Int))|});
    ( "State: independent instantiations",
      {|(state.run(fn () -> get(), 0), state.run(fn () -> get(), "hi"))|} );
    ( "State: aliases and higher-order transport",
      {|apply(f, x) = f(x)
{ let run-state = state.run
run-state(fn () -> { apply(put, "hi"); get() }, "initial") }|}
    );
    ( "State: a generic callback field retains its complete type",
      {|type Writer f = Writer f
{ let writer = Writer(put)
state.run(fn () -> { match writer { | Writer(write) -> write("hi") }; get() }, "initial") }|}
    );
    ( "State: nested independent payload types",
      {|state.run(fn () -> { state.run(fn () -> { put(42); get() }, 0); get() }, "outer")|} );
    ( "Throw: matching callback",
      {|throw.catch(fn () -> throw("hi"), fn (message) -> text.length(message))|} );
    ( "Throw: independent error types",
      {|(throw.to-result(fn () -> throw(1)), throw.to-result(fn () -> throw("hi")))|} );
    ( "Throw: different abortive result types in one region",
      {|throw.to-result(fn () -> { (throw("first") : Int); (throw("second") : Text) })|} );
    ( "Emit: same-type collection",
      {|(emit.collect(fn () -> { emit(1); emit(2) }) : ((), List Int))|} );
    ( "Emit: independent instantiations",
      {|(emit.collect(fn () -> emit(1)), emit.collect(fn () -> emit("hi")))|} );
    ( "Emit: nested independent element types",
      {|emit.collect(fn () -> { emit.collect(fn () -> emit(1)); emit("hi") })|} );
    ( "Dist: a polymorphic recursive helper remains usable by enumeration",
      {|dist.enumerate(fn () -> {
let n = sample(UniformInt(1, 2))
if sample(Bernoulli(0.5)) then add(n, 1) else n
})|}
    );
  ]

let rejects_kernel expected source () =
  match Test_check.check_src (Test_check.make_cctx ()) source with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "static refusal" expected (Diag.code_or_uncoded diagnostic)
  | Error diagnostics -> Eval_support.fail_diags "expected one type refusal" diagnostics
  | Ok _ -> Alcotest.fail "an erased nominal field or polymorphic recursion was accepted"

let quantified_field =
  {|(deftype payload-box () (con payload-box (field value (tforall ((tvar a)) () (tvar a)))))
(let nonrec (pvar boxed) (app (var payload-box) (var put))
  (app (var state.run)
    (lam ()
      (let nonrec (pwild)
        (match (var boxed) (clause (pcon payload-box (pvar write)) (app (var write) (lit "hi"))))
        (app (var get))))
    (lit 0)))|}

let recursive_components () =
  let source =
    {|(defterm
      ((binding consume () (lam () (tuple (app (var identity) (lit 1)) (app (var identity) (lit "hi")))))
       (binding identity () (lam ((pvar x)) (var x)))))
      (app (var consume))|}
  in
  match Test_check.check_src (Test_check.make_cctx ()) source with
  | Ok _ -> ()
  | Error diagnostics ->
      Eval_support.fail_diags "completed component generalizes before use" diagnostics

let suite =
  List.map (fun (name, source) -> Alcotest.test_case name `Quick (rejects source)) negative
  @ List.map (fun (name, source) -> Alcotest.test_case name `Quick (accepts source)) positive
  @ [
      Alcotest.test_case "State: quantified nominal fields cannot erase callback types" `Quick
        (rejects_kernel "E0801" quantified_field);
      Alcotest.test_case "Nominal fields must bind nested variables in the header" `Quick
        (rejects_kernel "E0811"
           "(deftype hidden () (con hidden (field callbacks (tapp (tref list) (tvar a)))))");
      Alcotest.test_case "Independent stored components generalize before callers" `Quick
        recursive_components;
      Alcotest.test_case "A true recursive component remains monomorphic" `Quick
        (rejects_kernel "E0801"
           {|(defterm
          ((binding f () (lam ((pvar x)) (app (var g) (var x))))
           (binding g () (lam ((pvar y))
             (let nonrec (pwild) (app (var f) (lit 1))
               (let nonrec (pwild) (app (var f) (lit "hi")) (var y)))))))|});
    ]
