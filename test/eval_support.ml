(** Shared harness for interpreter tests (W2.x): a fresh store seeded with a miniature prelude —
    Bool/Option types, native arithmetic registered under real store hashes via quote-marker
    declarations — plus parse/resolve/eval helpers. W2.6 turns this pattern into the real prelude.
*)

open Jacquard

type harness = {
  store : Store.t;
  ctx : Eval.ctx;
  names : Resolve.names;
  true_con : Hash.t;
  false_con : Hash.t;
  some_con : Hash.t;
  none_con : Hash.t;
  trace : Value.t list ref;  (** values recorded by the [note]/[pick] builtins, in order *)
  bumps : int ref;  (** how many times the [bump] builtin ran *)
}

let fresh_dir =
  let n = ref 0 in
  fun () ->
    incr n;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-eval-test-%d-%d" (Unix.getpid ()) !n)

let fail_diags what ds =
  Alcotest.failf "%s: %s" what (String.concat "; " (List.map Diag.to_string ds))

let put_src store names src =
  match Reader.parse_one ~file:"h.jqd" src with
  | Error ds -> fail_diags "parse" ds
  | Ok f -> (
      match Kernel.decl_of_form f with
      | Error ds -> fail_diags "validate" ds
      | Ok d -> (
          match Resolve.resolve_decl names d with
          | Error ds -> fail_diags "resolve" ds
          | Ok d -> (
              match Store.put_decl store d with Error ds -> fail_diags "put" ds | Ok hs -> hs)))

(* A builtin is declared as a real defterm whose body is a distinctive quoted marker; the
   native implementation is registered under the resulting member hash and wins over the
   store body at evaluation time. *)
let declare_builtin store ctx name native =
  let hs =
    put_src store (Store.names_view store)
      (Printf.sprintf "(defterm ((binding %s () (quote (builtin-marker %s)))))" name name)
  in
  let h = List.assoc name hs.Canon.named in
  Eval.register_builtin ctx h (Value.VBuiltin (name, native));
  h

let int2 name f =
  ( name,
    fun (args : Value.t list) ->
      match args with
      | [ Value.VInt a; Value.VInt b ] -> f a b
      | _ ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "%s expects two ints, got %s" name
                  (String.concat ", " (List.map Value.show args)))) )

let make () : harness =
  let store =
    match Store.open_store (fresh_dir ()) with Ok s -> s | Error ds -> fail_diags "open_store" ds
  in
  let ctx = Eval.make_ctx store in
  let bool_hs = put_src store Resolve.empty_names "(deftype bool () (con false) (con true))" in
  let option_hs =
    put_src store (Store.names_view store)
      "(deftype option ((tvar a)) (con none) (con some (field (tvar a))))"
  in
  let false_con = List.assoc "false" bool_hs.Canon.named in
  let true_con = List.assoc "true" bool_hs.Canon.named in
  let none_con = List.assoc "none" option_hs.Canon.named in
  let some_con = List.assoc "some" option_hs.Canon.named in
  let vbool b =
    if b then Value.VCon { con = true_con; name = "true"; args = [] }
    else Value.VCon { con = false_con; name = "false"; args = [] }
  in
  let trace = ref [] in
  let bumps = ref 0 in
  let arith (name, f) = ignore (declare_builtin store ctx name f) in
  arith (int2 "add" (fun a b -> Ok (Value.VInt (a + b))));
  arith (int2 "sub" (fun a b -> Ok (Value.VInt (a - b))));
  arith (int2 "mul" (fun a b -> Ok (Value.VInt (a * b))));
  arith
    (int2 "div" (fun a b ->
         if b = 0 then Error (Runtime_err.Arithmetic "division by zero")
         else Ok (Value.VInt (a / b))));
  arith (int2 "eq" (fun a b -> Ok (vbool (a = b))));
  arith (int2 "lt" (fun a b -> Ok (vbool (a < b))));
  ignore
    (declare_builtin store ctx "note" (fun args ->
         match args with
         | [ v ] ->
             trace := v :: !trace;
             Ok Value.unit_v
         | _ -> Error (Runtime_err.Arity "note takes one argument")));
  (* pick records its argument and returns a 2-ary builtin, for evaluation-order tests *)
  ignore
    (declare_builtin store ctx "pick" (fun args ->
         match args with
         | [ v ] ->
             trace := v :: !trace;
             Ok
               (Value.VBuiltin
                  ( "picked",
                    fun args' ->
                      trace := Value.VText "applied" :: !trace;
                      Ok (Value.VTuple args') ))
         | _ -> Error (Runtime_err.Arity "pick takes one argument")));
  ignore
    (declare_builtin store ctx "bump" (fun args ->
         match args with
         | [] ->
             incr bumps;
             Ok (Value.VInt !bumps)
         | _ -> Error (Runtime_err.Arity "bump takes no arguments")));
  {
    store;
    ctx;
    names = Store.names_view store;
    true_con;
    false_con;
    some_con;
    none_con;
    trace;
    bumps;
  }

(** A context over the REAL prelude (plan W2.6): fresh store, prelude loaded from [../prelude],
    native builtins wired. *)
let make_prelude_ctx () : Store.t * Eval.ctx =
  let store =
    match Store.open_store (fresh_dir ()) with Ok s -> s | Error ds -> fail_diags "open_store" ds
  in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok _ -> ()
  | Error ds -> fail_diags "prelude load" ds);
  let ctx = Eval.make_ctx store in
  (match Prelude.wire_builtins ctx with Ok () -> () | Error ds -> fail_diags "wire_builtins" ds);
  (store, ctx)

let eval_with ctx store src : (Value.t, Runtime_err.t) result =
  match Reader.parse_one ~file:"p.jqd" src with
  | Error ds -> fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr (Store.names_view store) e with
          | Error ds -> fail_diags "resolve" ds
          | Ok e -> Eval.run_expr ctx e))

let parse_expr h src : Kernel.expr =
  match Reader.parse_one ~file:"e.jqd" src with
  | Error ds -> fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr h.names e with
          | Error ds -> fail_diags "resolve" ds
          | Ok e -> e))

(** Parse, validate, resolve, and evaluate one expression source. *)
let eval_src h src : (Value.t, Runtime_err.t) result = Eval.run_expr h.ctx (parse_expr h src)

let eval_ok h src =
  match eval_src h src with
  | Ok v -> v
  | Error e -> Alcotest.failf "expected %s to evaluate, got: %s" src (Runtime_err.to_string e)

let eval_err h src =
  match eval_src h src with
  | Ok v -> Alcotest.failf "expected %s to fail, got %s" src (Value.show v)
  | Error e -> e

let recorded h = List.rev !(h.trace)
