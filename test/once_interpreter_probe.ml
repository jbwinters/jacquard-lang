open Jacquard

let fail_diags stage diagnostics =
  prerr_endline (stage ^ ": " ^ String.concat "; " (List.map Diag.to_string diagnostics));
  exit 1

let print_runtime_error error = prerr_endline (Diag.to_string (Runtime_err.to_diag error))

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path

let put_decl store source =
  match Reader.parse_one ~file:"once-probe.jqd" source with
  | Error diagnostics -> fail_diags "parse declaration" diagnostics
  | Ok form -> (
      match Kernel.decl_of_form form with
      | Error diagnostics -> fail_diags "validate declaration" diagnostics
      | Ok declaration -> (
          match Resolve.resolve_decl (Store.names_view store) declaration with
          | Error diagnostics -> fail_diags "resolve declaration" diagnostics
          | Ok declaration -> (
              match Store.put_decl store declaration with
              | Ok _ -> ()
              | Error diagnostics -> fail_diags "store declaration" diagnostics)))

let resolve_expr store source =
  match Reader.parse_one ~file:"once-probe.jqd" source with
  | Error diagnostics -> fail_diags "parse expression" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> fail_diags "validate expression" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics -> fail_diags "resolve expression" diagnostics))

let () =
  let root =
    Filename.concat (Sys.getcwd ()) (Printf.sprintf "once-probe-store-%d" (Unix.getpid ()))
  in
  at_exit (fun () -> remove_tree root);
  let store =
    match Store.open_store root with Ok store -> store | Error ds -> fail_diags "store" ds
  in
  put_decl store "(defeffect once-probe ((tvar a)) (op suspend () (tvar a)))";
  let ctx = Eval.make_ctx store in
  let expression = resolve_expr store "(tuple (app (var suspend)) (lit 7))" in
  let resume =
    match Eval.run_state_capturing_once ctx (Eval.expr_state expression) with
    | Ok (Eval.OCOp { name = "suspend"; resume; _ }) -> resume
    | Ok (Eval.OCOp { name; _ }) ->
        prerr_endline ("captured unexpected operation " ^ name);
        exit 1
    | Ok (Eval.OCValue value) ->
        prerr_endline ("capture unexpectedly returned " ^ Value.show value);
        exit 1
    | Error error ->
        print_runtime_error error;
        exit 1
  in
  (match Eval.call ctx resume [ Value.VInt 11 ] with
  | Ok (Value.VTuple [ Value.VInt 11; Value.VInt 7 ]) -> ()
  | Ok value ->
      prerr_endline ("first resume returned " ^ Value.show value);
      exit 1
  | Error error ->
      print_runtime_error error;
      exit 1);
  match Eval.call ctx resume [ Value.VInt 12 ] with
  | Error Runtime_err.Once_resumed_twice ->
      print_runtime_error Runtime_err.Once_resumed_twice;
      exit 2
  | Error error ->
      print_runtime_error error;
      exit 1
  | Ok value ->
      prerr_endline ("second resume returned " ^ Value.show value);
      exit 1
