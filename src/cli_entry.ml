(** Process-level exception classification for the command-line entry point. *)

let internal_error = 125
let diagnostic_error = 1

let backtrace_lines exception_value backtrace =
  let rendered = Printexc.raw_backtrace_to_string backtrace in
  let rendered = String.trim rendered in
  if String.equal rendered "" then Printexc.to_string exception_value
  else Printexc.to_string exception_value ^ "\n" ^ rendered

(** [run ~program ~err evaluate] evaluates the CLI with Cmdliner's exception capture disabled so a
    missed structural [Stack_overflow] is classified as E0003. Other uncaught exceptions retain the
    conventional Cmdliner-style report and internal-error exit status 125. *)
let run ~program ?(err = Format.err_formatter) evaluate =
  match evaluate () with
  | status -> status
  | exception Stack_overflow ->
      Format.fprintf err
        "error[E0003]: input exhausted the host stack before a structural nesting guard@.";
      diagnostic_error
  | exception exception_value ->
      let backtrace = Printexc.get_raw_backtrace () in
      Format.fprintf err "%s: internal error, uncaught exception:@\n%s@." program
        (backtrace_lines exception_value backtrace);
      internal_error
