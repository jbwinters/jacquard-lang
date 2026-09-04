(* Test-only access to defensive runtime paths that ordinary checked programs cannot reach.
   Require the checker to reject the fixture first, then deliberately bypass that rejection.
   This preserves interpreter/native error and allocation coverage without a public CLI bypass. *)
open Jacquard

let fail message =
  prerr_endline message;
  exit 1

let checked = function
  | Ok value -> value
  | Error diagnostics -> fail (String.concat "\n" (List.map Diag.to_string diagnostics))

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path)
  else Sys.remove path

let () =
  if Array.length Sys.argv < 3 then
    fail "usage: effect_payload_runtime_probe (run|run-console|build) FILE [OUTPUT]";
  let mode, file = (Sys.argv.(1), Sys.argv.(2)) in
  if
    not
      (((mode = "run" || mode = "run-console") && Array.length Sys.argv = 3)
      || (mode = "build" && Array.length Sys.argv = 4))
  then fail "expected run FILE, run-console FILE, or build FILE OUTPUT";
  let prelude_dir = Sys.getenv "JACQUARD_PRELUDE" in
  let root = Filename.temp_file "effect-payload-runtime-" ".store" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  at_exit (fun () -> remove_tree root);
  let store = checked (Store.open_store root) in
  ignore (checked (Prelude.load ~dir:prelude_dir store));
  let source = In_channel.with_open_bin file In_channel.input_all in
  let expression =
    checked (Reader.parse_one ~file source)
    |> Kernel.expr_of_form |> checked
    |> Resolve.resolve_expr (Store.names_view store)
    |> checked
  in
  let checker = checked (Check.make_ctx store) in
  Check.register_builtin_signatures checker (checked (Prelude.builtin_signatures store));
  (match Check.check_top checker (Kernel.Expr expression) with
  | Error [ diagnostic ] when List.mem (Diag.code_or_uncoded diagnostic) [ "E0801"; "E0804" ] -> ()
  | Error diagnostics ->
      fail
        ("unexpected fixture diagnostic: "
        ^ String.concat "; " (List.map Diag.to_string diagnostics))
  | Ok _ -> fail "runtime probe requires a statically rejected payload fixture");
  if mode <> "build" then (
    let ctx = Eval.make_ctx store in
    ignore (checked (Prelude.wire_builtins ctx));
    if mode = "run-console" then ignore (checked (Prelude.install_console ctx ~out:print_string));
    match Eval.run_expr ctx expression with
    | Ok value -> print_endline (Value.show value)
    | Error error ->
        prerr_endline (Diag.to_string (Runtime_err.to_diag error));
        exit 2)
  else
    match
      Jacquard_native.Build.build ~store
        ~tops:[ (expression, [], []) ]
        ~prelude_dir ~out:Sys.argv.(3)
    with
    | Ok _ -> ()
    | Error (`Toolchain message) -> fail message
    | Error (`Refused _) -> fail "runtime probe fixture is outside the native subset"
