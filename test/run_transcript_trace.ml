(** Internal cram fixture for the exact [run-transcript-v1] bytes. It intentionally has no CLI
    surface: RW.1 keeps recording as an interpreter-tooling API. *)

open Jacquard

let fail_diagnostics diagnostics =
  failwith (String.concat "; " (List.map Diag.to_string diagnostics))

let prelude_dir () = Option.value (Sys.getenv_opt "JACQUARD_PRELUDE") ~default:"../prelude"

let fresh_store_root () =
  let root =
    Filename.concat ".scratch" (Printf.sprintf "run-transcript-cram-%d.store" (Unix.getpid ()))
  in
  if not (Sys.file_exists ".scratch") then Sys.mkdir ".scratch" 0o700;
  if Sys.file_exists root then failwith "run-transcript cram store already exists";
  Sys.mkdir root 0o700;
  root

let expression store source =
  match Reader.parse_one ~file:"run-transcript-cram.jqd" source with
  | Error diagnostics -> fail_diagnostics diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> fail_diagnostics diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics -> fail_diagnostics diagnostics))

let () =
  let root = fresh_store_root () in
  let store =
    match Store.open_store root with
    | Ok store -> store
    | Error diagnostics -> fail_diagnostics diagnostics
  in
  (match Prelude.load ~dir:(prelude_dir ()) store with
  | Ok _ -> ()
  | Error diagnostics -> fail_diagnostics diagnostics);
  let ctx = Eval.make_ctx store in
  (match Prelude.wire_builtins ctx with
  | Ok () -> ()
  | Error diagnostics -> fail_diagnostics diagnostics);
  (match Prelude.install_console ctx ~out:ignore with
  | Ok () -> ()
  | Error diagnostics -> fail_diagnostics diagnostics);
  let recorder = Run_transcript.create () in
  let result =
    Run_transcript.record_expression recorder ctx (fun () ->
        Eval.run_expr ctx
          (expression store "(let nonrec (pwild) (app (var print) (lit \"hello\")) (lit 0))"))
  in
  match result with
  | Ok _ -> print_string (Run_transcript.serialize_recorder recorder)
  | Error error -> failwith (Runtime_err.to_string error)
