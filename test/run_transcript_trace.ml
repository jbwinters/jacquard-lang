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

let record () =
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

let parsed bytes =
  match Run_transcript.parse bytes with
  | Ok transcript -> transcript
  | Error ds -> fail_diagnostics ds

let console_print_hash = "28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e"

let transcript ~value ~operation ~output ~observations =
  Printf.sprintf
    "jacquard-run-transcript format=1 observations=%d\n\
     observation index=0 value-bytes=2 trace-events=1\n\
     %s\n\
     trace index=0 operation=%s output-bytes=%d\n\
     %s%s"
    observations value operation (String.length output) output
    (if observations = 2 then "observation index=1 value-bytes=2 trace-events=0\n0\n" else "")

let render_one left right =
  match Run_transcript.compare (parsed left) (parsed right) with
  | Run_transcript.Equal -> failwith "render fixture unexpectedly compared equal"
  | Run_transcript.Divergence divergence ->
      print_endline (Run_transcript.divergence_kind_name divergence.kind);
      print_endline (Run_transcript.render divergence)

let render_divergences () =
  let left = transcript ~value:"0" ~operation:console_print_hash ~output:"left\n" ~observations:2 in
  render_one left
    (transcript ~value:"1" ~operation:console_print_hash ~output:"left\n" ~observations:2);
  render_one left
    (transcript ~value:"0" ~operation:console_print_hash ~output:"right\t" ~observations:2);
  render_one left
    (transcript ~value:"0" ~operation:console_print_hash ~output:"left\n" ~observations:1)

let () =
  match Array.to_list Sys.argv with
  | [ _ ] -> record ()
  | [ _; "render-divergences" ] -> render_divergences ()
  | _ -> failwith "usage: run_transcript_trace.exe [render-divergences]"
