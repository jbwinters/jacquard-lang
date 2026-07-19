(** Process-level exception classification for the command-line entry point. *)

let internal_error = 125
let diagnostic_error = 1

let backtrace_lines exception_value backtrace =
  let rendered = Printexc.raw_backtrace_to_string backtrace in
  let rendered = String.trim rendered in
  if String.equal rendered "" then Printexc.to_string exception_value
  else Printexc.to_string exception_value ^ "\n" ^ rendered

(** [run ~program ~err ~render_diagnostic evaluate] evaluates the CLI with Cmdliner's exception
    capture disabled so a missed structural [Stack_overflow] is classified as E0003. The supplied
    renderer lets the process boundary honor the selected diagnostic format. Other uncaught
    exceptions retain the conventional Cmdliner-style report and internal-error exit status 125. *)
let run ~program ?(err = Format.err_formatter) ?(render_diagnostic = Diag.to_string) evaluate =
  match evaluate () with
  | status -> status
  | exception Stack_overflow ->
      let diagnostic =
        Diag.error ~domain:Process ~code:"E0003"
          ~summary:"Input exhausted the host stack before a structural nesting guard"
          ~cause:
            "An unbounded internal traversal reached the host stack limit before Jacquard could \
             report its local depth boundary."
          ~next_step:"Reduce the input nesting and report the missing structural guard."
          ~contrast:None ()
      in
      Format.fprintf err "%s@." (render_diagnostic diagnostic);
      diagnostic_error
  | exception exception_value ->
      let backtrace = Printexc.get_raw_backtrace () in
      Format.fprintf err "%s: internal error, uncaught exception:@\n%s@." program
        (backtrace_lines exception_value backtrace);
      internal_error
